"""Universal transactional component upgrader for native and adopted installations.

Provides dynamic upstream discovery, pre-flight safety checks, syntax validation,
atomic binary replacement, canary healthcheck, and self-healing auto-rollback.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import secrets
import shutil
import socket
import stat
import subprocess
import tarfile
import time
import zipfile
from dataclasses import dataclass
from typing import Literal

try:
    import tomllib
except ImportError:
    try:
        import tt_tomli_parser as tomllib
    except ImportError:
        tomllib = None

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from panel import atomic_file, digest, safe_file

@dataclass(frozen=True)
class SocketBinding:
    host: str
    port: int
    protocol: Literal["tcp", "udp"]

@dataclass(frozen=True)
class UnitHealthTarget:
    unit_name: str
    initial_state: str
    initial_restarts: int
    config_path: str | None
    expected_bindings: list[SocketBinding]

SEMVER_REGEX = re.compile(
    r"v?(?P<major>0|[1-9]\d*)\.(?P<minor>0|[1-9]\d*)\.(?P<patch>0|[1-9]\d*)"
    r"(?:-(?P<prerelease>(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)"
    r"(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?"
    r"(?:\+(?P<buildmetadata>[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?"
)

def extract_semver(text):
    if not text:
        return None
    match = SEMVER_REGEX.search(text)
    if not match:
        return None
    ver = f"{match.group('major')}.{match.group('minor')}.{match.group('patch')}"
    if match.group('prerelease'):
        ver += f"-{match.group('prerelease')}"
    if match.group('buildmetadata'):
        ver += f"+{match.group('buildmetadata')}"
    return ver

def check_elf_architecture(binary_path, expected_arch=None):
    """Verify that if binary_path is an ELF binary, it matches expected_arch."""
    p = Path(binary_path)
    if not p.exists() or not p.is_file():
        raise ComponentUpgradeError('upgrade_binary_not_found')
    try:
        data = p.read_bytes()[:20]
    except OSError as e:
        raise ComponentUpgradeError('upgrade_syntax_failed') from e
    if len(data) >= 20 and data[:4] == b'\x7fELF':
        e_machine = int.from_bytes(data[18:20], byteorder='little')
        norm = normalize_arch(expected_arch)
        # 0x3e (62) = x86_64, 0xb7 (183) = aarch64
        if norm == 'x86_64' and e_machine != 0x3e:
            raise ComponentUpgradeError('upgrade_architecture_mismatch')
        elif norm == 'aarch64' and e_machine != 0xb7:
            raise ComponentUpgradeError('upgrade_architecture_mismatch')

def _parse_toml_bindings(config_file):
    bindings = []
    if not config_file or not Path(config_file).exists():
        return bindings
    try:
        content = Path(config_file).read_bytes()
        data = None
        if tomllib:
            data = tomllib.loads(content.decode('utf-8', errors='replace'))
        else:
            try:
                from tt_common import toml_loads
                data = toml_loads(content.decode('utf-8', errors='replace'))
            except Exception:
                pass
        if not data or not isinstance(data, dict):
            return bindings
        addr = data.get('listen_address') or data.get('listen')
        if addr:
            addr_str = str(addr).strip()
            host, port = '0.0.0.0', 0
            if ':' in addr_str:
                last_colon = addr_str.rfind(':')
                h = addr_str[:last_colon].strip('[]')
                p = addr_str[last_colon+1:]
                host = h if h else '0.0.0.0'
                port = int(p) if p.isdigit() else 0
            elif addr_str.isdigit():
                port = int(addr_str)
            if port > 0:
                protocols = ['tcp']
                proto_cfg = data.get('listen_protocols')
                if isinstance(proto_cfg, dict) and 'quic' in proto_cfg:
                    protocols.append('udp')
                elif isinstance(proto_cfg, list) and 'quic' in proto_cfg:
                    protocols.append('udp')
                for proto in protocols:
                    bindings.append(SocketBinding(host=host, port=port, protocol=proto))
    except Exception:
        pass
    return bindings

def discover_trusttunnel_targets() -> list[UnitHealthTarget]:
    """Discover active/activating/failed instances of trusttunnel services and parsed vpn.toml bindings."""
    targets = []
    patterns = ['antirkn-tt@*.service', 'trusttunnel*.service', 'antirkn-trusttunnel.service']
    try:
        out = subprocess.run(
            ['/usr/bin/systemctl', 'list-units', '--all', '--plain', '--no-legend', *patterns],
            capture_output=True, text=True, timeout=10
        )
        if out.returncode == 0:
            found_names = set()
            for line in out.stdout.splitlines():
                parts = line.strip().split()
                if not parts:
                    continue
                unit = parts[0]
                if unit in found_names:
                    continue
                found_names.add(unit)

                show_out = subprocess.run(
                    ['/usr/bin/systemctl', 'show', unit,
                     '-p', 'ActiveState', '-p', 'NRestarts', '-p', 'WorkingDirectory'],
                    capture_output=True, text=True, timeout=5
                )
                props = {}
                if show_out.returncode == 0:
                    for s_line in show_out.stdout.splitlines():
                        if '=' in s_line:
                            k, v = s_line.split('=', 1)
                            props[k.strip()] = v.strip()

                active_state = props.get('ActiveState', 'unknown')
                if active_state not in ('active', 'activating', 'reloading', 'failed'):
                    continue

                restarts = int(props.get('NRestarts', 0)) if props.get('NRestarts', '').isdigit() else 0
                work_dir = props.get('WorkingDirectory', '')

                config_path = None
                match_id = re.search(r'antirkn-tt@([a-f0-9]{32})\.service', unit)
                if match_id:
                    p = Path(f'/etc/antirkn-components/trusttunnel/{match_id.group(1)}/vpn.toml')
                    if p.exists():
                        config_path = str(p)
                if not config_path and work_dir:
                    p = Path(work_dir) / 'vpn.toml'
                    if p.exists():
                        config_path = str(p)
                if not config_path:
                    for candidate_cfg in (
                        Path('/etc/antirkn-components/trusttunnel/vpn.toml'),
                        Path('/etc/trusttunnel/vpn.toml'),
                    ):
                        if candidate_cfg.exists():
                            config_path = str(candidate_cfg)
                            break

                bindings = _parse_toml_bindings(config_path) if config_path else []
                targets.append(UnitHealthTarget(
                    unit_name=unit,
                    initial_state=active_state,
                    initial_restarts=restarts,
                    config_path=config_path,
                    expected_bindings=bindings,
                ))
    except Exception:
        pass
    return targets

def verify_socket_bindings(
    bindings: list[SocketBinding],
    expected_comm: str = "trusttunnel_endpoint",
    timeout_sec: float = 15.0,
) -> tuple[bool, str]:
    if not bindings:
        return True, "No bindings required"
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        ss_out = None
        try:
            res = subprocess.run(['/usr/bin/ss', '-tulnp'], capture_output=True, text=True, timeout=3)
            if res.returncode == 0:
                ss_out = res.stdout
        except Exception:
            pass

        all_ok = True
        missing = []
        for b in bindings:
            bound = False
            if ss_out:
                for line in ss_out.splitlines():
                    lower_line = line.lower()
                    if b.protocol not in lower_line:
                        continue
                    if f":{b.port} " in line or f":{b.port}\t" in line:
                        if expected_comm in line or not ('users:(' in line):
                            bound = True
                            break
            if not bound:
                if b.protocol == 'tcp':
                    probe_host = b.host if b.host not in ('0.0.0.0', '::', '') else '127.0.0.1'
                    try:
                        with socket.create_connection((probe_host, b.port), timeout=1):
                            bound = True
                    except (OSError, ValueError):
                        pass
                elif b.protocol == 'udp':
                    if ss_out and f":{b.port} " in ss_out:
                        bound = True
            if not bound:
                all_ok = False
                missing.append(f"{b.protocol}:{b.port}")
                break
        if all_ok:
            return True, "All bindings verified"
        time.sleep(0.5)
    return False, f"Missing socket bindings: {', '.join(missing)}"

def atomic_binary_replace(staged_path: Path, target_path: Path) -> Path:
    """Atomic replacement within target directory to guarantee single filesystem / mount point."""
    target_dir = target_path.parent
    target_dir.mkdir(parents=True, exist_ok=True)
    bak_path = target_path.with_name(target_path.name + '.antirkn_backup')

    if target_path.exists() and not target_path.is_symlink():
        st = target_path.stat()
        atomic_file(bak_path, target_path.read_bytes(), st.st_mode & 0o777)
        try:
            os.chown(str(bak_path), st.st_uid, st.st_gid)
        except OSError:
            pass

    temp_target = target_dir / ('.' + target_path.name + '.new.' + secrets.token_hex(8))
    mode = target_path.stat().st_mode & 0o777 if target_path.exists() else 0o755
    atomic_file(temp_target, staged_path.read_bytes(), mode)
    if target_path.exists():
        try:
            st = target_path.stat()
            os.chown(str(temp_target), st.st_uid, st.st_gid)
        except OSError:
            pass
    os.replace(temp_target, target_path)
    return bak_path

def safe_directory(path):
    st = path.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
        raise ComponentUpgradeError('upgrade_unsafe_path')

VALID_COMPONENTS = {'panel', 'xray', 'amneziawg', 'trusttunnel', 'mihomo'}
SUPPORTED_ARCHS = {'x86_64', 'aarch64', 'arm64', 'amd64'}


class UpgradeEventCode(str):
    PREPARING = "upgrade_preparing"
    DOWNLOADING = "upgrade_downloading"
    BACKING_UP = "upgrade_backing_up"
    SYNTAX_CHECKING = "upgrade_syntax_checking"
    SWITCHING = "upgrade_switching"
    VERIFYING = "upgrade_verifying"
    ROLLING_BACK = "upgrade_rolling_back"
    ROLLED_BACK = "upgrade_rolled_back"
    COMPLETED = "upgrade_completed"
    # Terminal failures
    SYNTAX_FAILED = "upgrade_syntax_failed"
    HEALTHCHECK_FAILED = "upgrade_healthcheck_failed"
    DOWNLOAD_MISSING = "upgrade_download_missing"
    DOWNLOAD_FAILED = "upgrade_download_failed"
    CHECKSUM_FAILED = "upgrade_checksum_failed"
    CONFLICT = "upgrade_conflict"


SAFE_PROBE_ENV: dict[str, str] = {
    "LC_ALL": "C",
    "LANG": "C",
    "PATH": "/usr/bin:/bin",
}


def canonical_plan_fingerprint(plan_data: dict) -> str:
    """Computes deterministic SHA-256 fingerprint for upgrade plan."""
    normalized = dict(plan_data)
    raw_units = normalized.get("units", [])
    normalized["units"] = sorted(
        raw_units,
        key=lambda u: u.get("name", "") if isinstance(u, dict) else str(u),
    )
    payload = json.dumps(normalized, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


class ComponentUpgradeError(Exception):
    def __init__(self, code='upgrade_failed', detail=''):
        super().__init__(str(code))
        self.code = str(code)
        self.detail = str(detail)

    def __str__(self):
        return f"{self.code}: {self.detail}" if self.detail else self.code


HEX_64_CHARS = frozenset("0123456789abcdef")


def normalize_sha256(raw: str | None) -> str:
    """
    Приводит дайджест к каноническому 64-символьному hex в нижнем регистре.
    Поддерживает формат GitHub API ('sha256:<hex>').
    Возвращает '' для пустого ввода.
    Выбрасывает ComponentUpgradeError(CHECKSUM_FAILED) для невалидных строк.
    """
    if not raw or not raw.strip():
        return ""
    cleaned = raw.strip().lower()
    if cleaned.startswith("sha256:"):
        cleaned = cleaned[7:].strip()
    if len(cleaned) != 64 or any(c not in HEX_64_CHARS for c in cleaned):
        raise ComponentUpgradeError(
            UpgradeEventCode.CHECKSUM_FAILED,
            detail=f"Invalid expected SHA-256 format: {raw!r}",
        )
    return cleaned


def verify_sha256(file_path: Path, expected_digest: str | None) -> None:
    """
    Проверяет SHA-256 файла. Поддерживает форматы 'hex' и 'sha256:hex'.
    Бросает ComponentUpgradeError(CHECKSUM_FAILED) при отсутствии хэша или несовпадении.
    """
    if not expected_digest or not str(expected_digest).strip():
        raise ComponentUpgradeError(
            UpgradeEventCode.CHECKSUM_FAILED,
            detail="missing_expected_digest",
        )
    expected = normalize_sha256(str(expected_digest))
    if not expected:
        raise ComponentUpgradeError(
            UpgradeEventCode.CHECKSUM_FAILED,
            detail="invalid_expected_digest",
        )
    actual = digest(Path(file_path)).lower()
    if actual != expected:
        raise ComponentUpgradeError(
            UpgradeEventCode.CHECKSUM_FAILED,
            detail=f"SHA-256 mismatch: expected {expected}, got {actual}",
        )


def normalize_arch(arch=None):
    raw = arch or platform.machine().lower()
    if raw in ('x86_64', 'amd64', 'x64'):
        return 'x86_64'
    if raw in ('aarch64', 'arm64'):
        return 'aarch64'
    return raw


def probe_staged_binary(
    binary_path: Path,
    probe_args: list[str],
    *,
    timeout_sec: float = 5.0,
) -> str:
    """
    Validates staged binary: symlink rejection, +x mode, ELF architecture check,
    and isolated probe run. Returns stdout on success.
    """
    p = Path(binary_path)
    if p.is_symlink() or not p.is_file():
        raise ComponentUpgradeError(
            UpgradeEventCode.SYNTAX_FAILED,
            detail=f"Invalid or symlink binary target: {p.name}",
        )

    try:
        p.chmod(0o755)
    except OSError as exc:
        raise ComponentUpgradeError(
            UpgradeEventCode.SYNTAX_FAILED,
            detail=f"chmod failed for {p.name}: {exc}",
        ) from exc

    check_elf_architecture(p)

    try:
        res = subprocess.run(
            [str(p), *probe_args],
            capture_output=True,
            text=True,
            timeout=timeout_sec,
            env=SAFE_PROBE_ENV,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise ComponentUpgradeError(
            UpgradeEventCode.SYNTAX_FAILED,
            detail=f"{p.name} {' '.join(probe_args)} timed out after {timeout_sec}s",
        ) from exc
    except OSError as exc:
        raise ComponentUpgradeError(
            UpgradeEventCode.SYNTAX_FAILED,
            detail=f"{p.name} exec error: {exc}",
        ) from exc

    out = (res.stdout or "").strip() or (res.stderr or "").strip()
    if res.returncode != 0 or not out:
        stderr_snippet = (res.stderr or "").strip()[:512]
        stdout_snippet = (res.stdout or "").strip()[:512]
        raise ComponentUpgradeError(
            UpgradeEventCode.SYNTAX_FAILED,
            detail=(
                f"{p.name} {' '.join(probe_args)} exited with {res.returncode}; "
                f"stderr={stderr_snippet!r}; stdout={stdout_snippet!r}"
            ),
        )

    return out


def download_verified_artifact(
    url: str,
    dest_path: Path,
    expected_sha256: str = "",
    *,
    socket_timeout_sec: float = 20.0,
    total_deadline_sec: float = 180.0,
    max_attempts: int = 3,
) -> str:
    """
    Streaming download with wall-clock deadline, retries, and SHA-256 verification
    before atomic replace. Returns actual SHA-256.
    """
    import urllib.error
    import urllib.request

    dest_path = Path(dest_path)
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    part_path = dest_path.with_name(dest_path.name + ".part." + secrets.token_hex(4))
    deadline = time.monotonic() + total_deadline_sec
    last_exc = None

    for attempt in range(1, max_attempts + 1):
        if part_path.exists():
            try:
                part_path.unlink()
            except OSError:
                pass
        hasher = hashlib.sha256()
        try:
            req = urllib.request.Request(
                url,
                headers={"User-Agent": "AntiRKN-Runner/1.0"}
            )
            with urllib.request.urlopen(req, timeout=socket_timeout_sec) as resp, part_path.open("wb") as out:
                while True:
                    if time.monotonic() > deadline:
                        raise TimeoutError(f"Total download deadline ({total_deadline_sec}s) exceeded")
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    hasher.update(chunk)
                    out.write(chunk)
            last_exc = None
            break
        except urllib.error.HTTPError as exc:
            if part_path.exists():
                try:
                    part_path.unlink()
                except OSError:
                    pass
            if exc.code == 404:
                raise ComponentUpgradeError(
                    UpgradeEventCode.DOWNLOAD_MISSING,
                    detail=f"HTTP 404 for {url}",
                ) from exc
            last_exc = exc
            if attempt == max_attempts:
                raise ComponentUpgradeError(
                    UpgradeEventCode.DOWNLOAD_FAILED,
                    detail=f"HTTP {exc.code} after {attempt} attempts: {exc}",
                ) from exc
        except Exception as exc:
            if part_path.exists():
                try:
                    part_path.unlink()
                except OSError:
                    pass
            last_exc = exc
            if attempt == max_attempts or time.monotonic() > deadline:
                raise ComponentUpgradeError(
                    UpgradeEventCode.DOWNLOAD_FAILED,
                    detail=f"Download failed after {attempt} attempts: {exc}",
                ) from exc
        time.sleep(2 ** attempt - 1)

    if last_exc is not None:
        raise ComponentUpgradeError(
            UpgradeEventCode.DOWNLOAD_FAILED,
            detail=f"Download failed: {last_exc}",
        )

    actual_sha256 = hasher.hexdigest().lower()
    expected = normalize_sha256(expected_sha256)
    if expected and actual_sha256 != expected:
        if part_path.exists():
            try:
                part_path.unlink()
            except OSError:
                pass
        raise ComponentUpgradeError(
            UpgradeEventCode.CHECKSUM_FAILED,
            detail=f"SHA-256 mismatch: expected {expected}, got {actual_sha256}",
        )

    os.replace(part_path, dest_path)
    return actual_sha256


def check_system_resources(target_path='/usr/local', min_disk_bytes=200 * 1024 * 1024, min_ram_kib=40 * 1024):
    target = Path(target_path)
    check_dir = target if target.exists() else Path('/')
    try:
        free_disk = shutil.disk_usage(str(check_dir)).free
        if free_disk < min_disk_bytes:
            raise ComponentUpgradeError('upgrade_disk_full')
    except OSError:
        pass

    meminfo = Path('/proc/meminfo')
    if meminfo.exists():
        try:
            for line in meminfo.read_text().splitlines():
                if line.startswith('MemAvailable:'):
                    parts = line.split()
                    if len(parts) >= 2 and parts[1].isdigit():
                        if int(parts[1]) < min_ram_kib:
                            raise ComponentUpgradeError('upgrade_memory_low')
                    break
        except OSError:
            pass


def is_unit_active(unit_name: str) -> bool:
    try:
        res = subprocess.run(['/usr/bin/systemctl', 'is-active', '--quiet', unit_name], capture_output=True, timeout=5)
        return res.returncode == 0
    except Exception:
        return False


def detect_component(component):
    """Detect binary, config paths, unit names, and whether installation is native or adopted."""
    if component not in VALID_COMPONENTS:
        raise ComponentUpgradeError('upgrade_invalid_component')

    arch = normalize_arch()
    result = {
        'component': component,
        'arch': arch,
        'installed': False,
        'source': 'missing',  # 'native', 'adopted_systemd', 'adopted_binary', 'adopted_docker'
        'binaryPath': None,
        'version': None,
        'configPath': None,
        'units': [],
        'ports': [],
        'dbPath': None,
    }

    if component == 'panel':
        # 3X-UI panel
        panel_bin = Path('/usr/local/x-ui/x-ui')
        if not panel_bin.exists():
            panel_bin = Path('/usr/bin/x-ui')
        if panel_bin.exists():
            result['installed'] = True
            result['binaryPath'] = str(panel_bin)
            result['source'] = 'native' if str(panel_bin).startswith('/usr/local/x-ui') else 'adopted_binary'
            result['units'] = ['x-ui.service'] if is_unit_active('x-ui.service') else []
            db = Path('/etc/x-ui/x-ui.db')
            if not db.exists():
                db = Path('/usr/local/x-ui/x-ui.db')
            if db.exists():
                result['dbPath'] = str(db)
            config = Path('/usr/local/x-ui/bin/config.json')
            if config.exists():
                result['configPath'] = str(config)
            try:
                out = subprocess.run([str(panel_bin), '-v'], capture_output=True, text=True, timeout=5)
                v = out.stdout.strip() or out.stderr.strip()
                result['version'] = extract_semver(v)
            except Exception:
                pass

    elif component == 'xray':
        candidates = [
            Path('/usr/local/x-ui/bin/xray-linux-amd64'),
            Path('/usr/local/x-ui/bin/xray-linux-arm64'),
            Path('/usr/local/bin/xray'),
            Path('/usr/bin/xray'),
            Path('/opt/xray/xray'),
        ]
        for c in candidates:
            if c.exists():
                result['installed'] = True
                result['binaryPath'] = str(c)
                result['source'] = 'native' if '/usr/local/x-ui' in str(c) else 'adopted_binary'
                config = c.parent / 'config.json'
                if config.exists():
                    result['configPath'] = str(config)
                if '/usr/local/x-ui' in str(c):
                    result['units'] = ['x-ui.service'] if is_unit_active('x-ui.service') else []
                else:
                    result['units'] = ['xray.service'] if is_unit_active('xray.service') else []
                try:
                    out = subprocess.run([str(c), 'version'], capture_output=True, text=True, timeout=5)
                    result['version'] = extract_semver(out.stdout)
                except Exception:
                    pass
                break

    elif component == 'amneziawg':
        candidates = [
            (Path('/usr/local/bin/amneziawg-go'), 'native'),
            (Path('/usr/bin/amneziawg-go'), 'adopted_binary'),
            (Path('/usr/local/bin/awg'), 'native'),
            (Path('/usr/bin/awg'), 'adopted_binary'),
        ]
        for c, src in candidates:
            if c.exists():
                result['installed'] = True
                result['binaryPath'] = str(c)
                result['source'] = src
                try:
                    out = subprocess.run([str(c), '--version'], capture_output=True, text=True, timeout=5)
                    result['version'] = extract_semver(out.stdout or out.stderr)
                except Exception:
                    pass
                break
        # Find active awg units
        try:
            out = subprocess.run(['/usr/bin/systemctl', 'list-units', '--state=active', '--type=service', '--no-legend',
                                  'antirkn-awg@*.service', 'awg-quick@*.service'], capture_output=True, text=True, timeout=10)
            if out.returncode == 0:
                result['units'] = [line.split()[0] for line in out.stdout.splitlines() if line.strip()]
        except Exception:
            pass

    elif component == 'trusttunnel':
        candidates = [
            (Path('/usr/local/bin/trusttunnel_endpoint'), 'native'),
            (Path('/usr/bin/trusttunnel_endpoint'), 'adopted_binary'),
            (Path('/opt/trusttunnel/trusttunnel_endpoint'), 'adopted_binary'),
        ]
        for c, src in candidates:
            if c.exists():
                result['installed'] = True
                result['binaryPath'] = str(c)
                result['source'] = src
                cfg = Path('/etc/antirkn-components/trusttunnel/vpn.toml')
                if not cfg.exists():
                    cfg = Path('/etc/trusttunnel/vpn.toml')
                if cfg.exists():
                    result['configPath'] = str(cfg)
                
                targets = discover_trusttunnel_targets()
                result['healthTargets'] = [
                    {
                        'unit_name': t.unit_name,
                        'initial_state': t.initial_state,
                        'initial_restarts': t.initial_restarts,
                        'config_path': t.config_path,
                        'expected_bindings': [
                            {'host': b.host, 'port': b.port, 'protocol': b.protocol}
                            for b in t.expected_bindings
                        ],
                    }
                    for t in targets
                ]
                result['units'] = [t.unit_name for t in targets]
                result['ports'] = [b.port for t in targets for b in t.expected_bindings if b.protocol == 'tcp']
                try:
                    out = subprocess.run([str(c), '--version'], capture_output=True, text=True, timeout=5)
                    result['version'] = extract_semver(out.stdout or out.stderr)
                except Exception:
                    pass
                break

    elif component == 'mihomo':
        candidates = [
            (Path('/usr/local/bin/mihomo'), 'native'),
            (Path('/usr/bin/mihomo'), 'adopted_binary'),
            (Path('/opt/mihomo/mihomo'), 'adopted_binary'),
        ]
        for c, src in candidates:
            if c.exists():
                result['installed'] = True
                result['binaryPath'] = str(c)
                result['source'] = src
                cfg = Path('/etc/mihomo/config.yaml')
                if cfg.exists():
                    result['configPath'] = str(cfg)
                result['units'] = ['mihomo.service']
                try:
                    out = subprocess.run([str(c), '-v'], capture_output=True, text=True, timeout=5)
                    result['version'] = extract_semver(out.stdout or out.stderr)
                except Exception:
                    pass
                break

    return result


def extract_archive_safe(archive_path, extract_dir, binary_name=None, max_size=500 * 1024 * 1024):
    """Safe extraction preventing path traversal, symlink hijacking, and zip-bombs."""
    dest = Path(extract_dir)
    dest.mkdir(parents=True, exist_ok=True)
    seen, total_size = set(), 0
    archive_path = Path(archive_path)

    if zipfile.is_zipfile(archive_path):
        with zipfile.ZipFile(archive_path) as z:
            for item in z.infolist():
                name = item.filename
                path = PurePosixPath(name)
                total_size += item.file_size
                if path.is_absolute() or '..' in path.parts or '\\' in name:
                    raise ComponentUpgradeError(UpgradeEventCode.SYNTAX_FAILED, detail='archive_unsafe_path')
                if total_size > max_size:
                    raise ComponentUpgradeError(UpgradeEventCode.SYNTAX_FAILED, detail='archive_size_exceeded')
                norm_name = str(path).strip('/')
                if norm_name in ('', '.'):
                    continue
                is_dir = item.is_dir() if hasattr(item, 'is_dir') else name.endswith('/')
                if is_dir:
                    seen.add(norm_name)
                    continue
                if norm_name in seen:
                    raise ComponentUpgradeError(UpgradeEventCode.SYNTAX_FAILED, detail=f'archive_duplicate_entry: {norm_name}')
                seen.add(norm_name)
            z.extractall(str(dest))
        return dest

    if tarfile.is_tarfile(archive_path):
        with tarfile.open(archive_path, 'r:*') as t:
            for member in t.getmembers():
                name = member.name
                path = PurePosixPath(name)
                total_size += member.size
                if path.is_absolute() or '..' in path.parts or '\\' in name:
                    raise ComponentUpgradeError(UpgradeEventCode.SYNTAX_FAILED, detail='archive_unsafe_path')
                if total_size > max_size:
                    raise ComponentUpgradeError(UpgradeEventCode.SYNTAX_FAILED, detail='archive_size_exceeded')
                norm_name = str(path).strip('/')
                if norm_name in ('', '.'):
                    continue
                if member.isdir():
                    seen.add(norm_name)
                    continue
                if norm_name in seen:
                    raise ComponentUpgradeError(UpgradeEventCode.SYNTAX_FAILED, detail=f'archive_duplicate_entry: {norm_name}')
                seen.add(norm_name)
            try:
                t.extractall(str(dest), filter='data')
            except TypeError:
                t.extractall(str(dest))
        return dest

    # Direct raw binary
    target = dest / (binary_name or archive_path.name)
    target.write_bytes(archive_path.read_bytes())
    target.chmod(0o755)
    return dest


def probe_component(component):
    """{target: ok} real connectivity of what this component serves."""
    import upgrade_probe
    if component in ('panel', 'xray'):
        return upgrade_probe.probe_vless()
    if component == 'trusttunnel':
        return upgrade_probe.probe_tls_listeners(discover_trusttunnel_targets())
    if component == 'amneziawg':
        return upgrade_probe.probe_awg()
    return {}


def compare_probes(before, after):
    import upgrade_probe
    return upgrade_probe.compare(before, after)


class ComponentUpgrader:
    """Universal transactional upgrader with syntax pre-flight, atomic switch, and self-healing rollback."""

    def __init__(self, store, request, candidate_manifest):
        self.store = store
        self.request = request
        self.manifest = candidate_manifest
        self.component = candidate_manifest['component']
        self.job_id = request['id']
        self.work_dir = store.directory / ('upgrade-' + self.job_id)
        self.backup_dir = self.work_dir / 'backup'
        self.staging_dir = self.work_dir / 'staging'
        self.detection = None
        self.backup_metadata = {}

    def _ensure_detection_and_metadata(self):
        if not self.backup_metadata:
            meta_path = self.backup_dir / 'meta.json'
            if meta_path.exists():
                try:
                    self.backup_metadata = json.loads(meta_path.read_text())
                except Exception:
                    self.backup_metadata = {}
        if not self.detection:
            if self.backup_metadata and self.backup_metadata.get('binaryPath'):
                self.detection = {
                    'installed': True,
                    'binaryPath': self.backup_metadata['binaryPath'],
                    'units': self.backup_metadata.get('units', []),
                    'configPath': self.backup_metadata.get('configPath'),
                    'dbPath': self.backup_metadata.get('dbPath'),
                    'ports': self.backup_metadata.get('ports', []),
                }
            else:
                self.detection = detect_component(self.component)

    def pre_check(self):
        """Validate architecture, prerequisites, disk space, and memory."""
        check_system_resources()
        self._ensure_detection_and_metadata()
        if not self.detection.get('installed') or not self.detection.get('binaryPath'):
            raise ComponentUpgradeError('upgrade_not_installed')
        # TrustTunnel/AmneziaWG installed by AntiRKN live in immutable version
        # folders behind links; writing a file over the link would make them
        # look foreign. Their updates go through the component installer.
        binary = Path(self.detection['binaryPath'])
        if binary.is_symlink() and str(binary.resolve()).startswith('/usr/local/lib/antirkn-components/'):
            raise ComponentUpgradeError('upgrade_conflict', detail='managed by the component installer')

        manifest_arch = normalize_arch(self.manifest.get('architecture'))
        host_arch = normalize_arch()
        if manifest_arch != host_arch:
            raise ComponentUpgradeError('upgrade_architecture_mismatch')

        self.work_dir.mkdir(parents=True, exist_ok=True)
        self.backup_dir.mkdir(parents=True, exist_ok=True)
        self.staging_dir.mkdir(parents=True, exist_ok=True)

    def backup(self):
        """Take consistent atomic snapshots of binary, config, and database."""
        self.work_dir.mkdir(parents=True, exist_ok=True)
        self.backup_dir.mkdir(parents=True, exist_ok=True)
        self.staging_dir.mkdir(parents=True, exist_ok=True)
        self._ensure_detection_and_metadata()

        binary_path = Path(self.detection['binaryPath'])
        if not binary_path.exists():
            raise ComponentUpgradeError('upgrade_not_installed')

        # 1. Binary backup
        st = binary_path.stat()
        mode = st.st_mode & 0o777
        self.backup_metadata = {
            'binaryPath': str(binary_path),
            'mode': mode,
            'uid': st.st_uid,
            'gid': st.st_gid,
            'size': st.st_size,
            'sha256': digest(binary_path),
            'units': self.detection.get('units', []),
            'configPath': self.detection.get('configPath'),
            'dbPath': self.detection.get('dbPath'),
            'ports': self.detection.get('ports', []),
            'healthTargets': self.detection.get('healthTargets', []),
        }

        # The version this backup brings back (kept as a snapshot after confirmation).
        self.backup_metadata['version'] = self.detection.get('version')
        if self.component == 'panel':
            self.backup_metadata['xrayVersion'] = detect_component('xray').get('version')

        # Local backup in work_dir
        backup_bin = self.backup_dir / binary_path.name
        atomic_file(backup_bin, binary_path.read_bytes(), mode)

        # Alongside backup for fast in-place restoration
        inplace_backup = binary_path.with_suffix(binary_path.suffix + '.antirkn_backup')
        atomic_file(inplace_backup, binary_path.read_bytes(), mode)

        # Backup setup_wizard alongside trusttunnel_endpoint if present
        if self.component == 'trusttunnel':
            wizard = binary_path.parent / 'setup_wizard'
            if wizard.exists() and not wizard.is_symlink():
                atomic_file(self.backup_dir / 'setup_wizard', wizard.read_bytes(), 0o755)
                atomic_file(wizard.with_name('setup_wizard.antirkn_backup'), wizard.read_bytes(), 0o755)

        # 2. Config backup
        if self.detection.get('configPath'):
            cfg_path = Path(self.detection['configPath'])
            if cfg_path.exists():
                cfg_backup = self.backup_dir / 'config_backup'
                atomic_file(cfg_backup, cfg_path.read_bytes(), 0o600)
                self.backup_metadata['configSha256'] = digest(cfg_path)

        # 3. Database backup (for 3X-UI SQLite DB)
        if self.detection.get('dbPath'):
            db_path = Path(self.detection['dbPath'])
            if db_path.exists():
                import sqlite3
                db_backup = self.backup_dir / 'db_backup.sqlite'
                src_db = sqlite3.connect(db_path.as_uri() + '?mode=ro', uri=True)
                dest_db = sqlite3.connect(str(db_backup))
                try:
                    src_db.backup(dest_db)
                finally:
                    dest_db.close()
                    src_db.close()
                self.backup_metadata['dbSha256'] = digest(db_backup)

        # 4. Companion files the switch replaces too. A 3x-ui archive carries
        # its own Xray; rolling back only x-ui would leave the new core behind.
        extras = []
        for extra in self._companion_files(binary_path):
            if extra.is_file() and not extra.is_symlink():
                saved = self.backup_dir / 'extra' / extra.name
                saved.parent.mkdir(parents=True, exist_ok=True)
                atomic_file(saved, extra.read_bytes(), extra.stat().st_mode & 0o777)
                extras.append(dict(path=str(extra), mode=extra.stat().st_mode & 0o777))
        self.backup_metadata['extraFiles'] = extras

        # 5. Real connectivity before the switch, compared after it.
        try:
            self.backup_metadata['probeBefore'] = probe_component(self.component)
        except Exception:
            self.backup_metadata['probeBefore'] = {}

        atomic_file(self.backup_dir / 'meta.json', json.dumps(self.backup_metadata).encode())

    def _companion_files(self, binary_path):
        if self.component == 'panel':
            base = Path('/usr/local/x-ui')
            return [base / 'bin/xray-linux-amd64', base / 'bin/xray-linux-arm64', base / 'x-ui.sh']
        if self.component == 'xray':
            return [binary_path.parent / 'geoip.dat', binary_path.parent / 'geosite.dat']
        return []

    def _previous_core(self):
        """The Xray that ran before the switch (from this upgrade's backup)."""
        meta = self.backup_metadata or {}
        if self.component == 'xray' and meta.get('binaryPath'):
            core = self.backup_dir / Path(meta['binaryPath']).name
        elif self.component == 'panel':
            core = self.backup_dir / 'extra' / 'xray-linux-amd64'
        else:
            return None
        return core if core.is_file() and os.access(core, os.X_OK) else None

    def _probe_after(self):
        """New core as the client, plus the previous core: double hop entry
        servers and older clients keep running it, and a new server can stop
        accepting them (measured: Xray 25.1 clients vs a 26.11 server)."""
        results = dict(probe_component(self.component))
        core = self._previous_core()
        if core is not None:
            import upgrade_probe
            results.update({'previous:' + k: ok for k, ok in upgrade_probe.probe_vless(binary=core).items()})
        return results

    def verify_connectivity(self):
        """Roll back when an inbound/endpoint that worked before the switch fails after it."""
        self._ensure_detection_and_metadata()
        before = dict(self.backup_metadata.get('probeBefore') or {})
        if not any(before.values()):
            return []
        if self._previous_core() is not None:
            # Before the switch the previous core was the installed one.
            before.update({'previous:' + k: ok for k, ok in list(before.items())})
        deadline = time.monotonic() + 30
        failed = []
        while time.monotonic() < deadline:
            failed = compare_probes(before, self._probe_after())
            if not failed:
                return []
            time.sleep(3)
        self.rollback()
        raise ComponentUpgradeError('upgrade_connectivity_failed', detail=','.join(failed))

    def validate_and_stage(self, downloaded_archive_path):
        """Validate archive SHA-256 and extract binary into staging directory."""
        self._ensure_detection_and_metadata()
        archive = Path(downloaded_archive_path)
        if not archive.exists():
            raise ComponentUpgradeError(UpgradeEventCode.DOWNLOAD_MISSING)

        expected_sha = self.manifest.get('sha256')
        if expected_sha and str(expected_sha).strip():
            verify_sha256(archive, expected_sha)
        actual_sha = digest(archive).lower()
        self.manifest['sha256'] = actual_sha

        binary_name = self.manifest.get('binaryName') or (Path(self.detection['binaryPath']).name if (self.detection and self.detection.get('binaryPath')) else None)
        extract_archive_safe(archive, self.staging_dir, binary_name=binary_name)

        if self.component == 'panel':
            # Support composite 3x-ui distributions (x-ui-linux-amd64.tar.gz containing x-ui, x-ui.sh, bin/xray-linux-amd64)
            staged_candidates = [p for p in self.staging_dir.rglob('x-ui') if p.is_file() and not p.name.endswith('.antirkn-tmp')]
            if not staged_candidates:
                files = [p for p in self.staging_dir.rglob('*') if p.is_file() and not p.name.endswith('.antirkn-tmp') and not p.name.endswith('.sh')]
                staged_candidates = files
            if not staged_candidates:
                raise ComponentUpgradeError('upgrade_binary_not_found')
            staged_binary = staged_candidates[0]
            staged_binary.chmod(0o755)

            # Stage composite files
            for sh_file in self.staging_dir.rglob('x-ui.sh'):
                if sh_file.is_file() and not sh_file.name.endswith('.antirkn-tmp'):
                    sh_file.chmod(0o755)

            for xray_file in self.staging_dir.rglob('*'):
                if xray_file.is_file() and ('xray-linux' in xray_file.name or xray_file.name == 'xray') and not xray_file.name.endswith('.antirkn-tmp'):
                    xray_file.chmod(0o755)

            if self.manifest.get('binarySha256'):
                if digest(staged_binary) != self.manifest['binarySha256']:
                    raise ComponentUpgradeError('upgrade_checksum_failed')

            return staged_binary

        # Find the target binary in staging for non-panel components
        staged_candidates = []
        if self.component == 'xray':
            xray_names = {'xray', 'xray-linux-amd64', 'xray-linux-arm64'}
            if binary_name:
                xray_names.add(binary_name)
            staged_candidates = [p for p in self.staging_dir.rglob('*') if p.is_file() and not p.is_symlink() and p.name in xray_names and not p.name.endswith('.antirkn-tmp')]
        elif binary_name:
            staged_candidates = [p for p in self.staging_dir.rglob(binary_name) if p.is_file() and not p.is_symlink() and not p.name.endswith('.antirkn-tmp')]
        if not staged_candidates:
            files = [p for p in self.staging_dir.rglob('*') if p.is_file() and not p.is_symlink() and not p.name.endswith('.antirkn-tmp')]
            if len(files) == 1:
                staged_candidates = files
            elif binary_name:
                staged_candidates = [p for p in files if p.name == binary_name]
        if not staged_candidates:
            raise ComponentUpgradeError('upgrade_binary_not_found')

        staged_binary = staged_candidates[0]
        staged_binary.chmod(0o755)

        # Verify expected binary SHA-256 if specified
        if self.manifest.get('binarySha256'):
            if digest(staged_binary) != self.manifest['binarySha256']:
                raise ComponentUpgradeError('upgrade_checksum_failed')

        return staged_binary

    def syntax_pre_check(self, staged_binary):
        """Validate configuration syntax and binary ELF architecture before touching live service."""
        self._ensure_detection_and_metadata()
        if staged_binary.is_symlink() or not staged_binary.is_file():
            raise ComponentUpgradeError(
                UpgradeEventCode.SYNTAX_FAILED,
                detail=f"Invalid or symlink binary target: {staged_binary.name}",
            )
        check_elf_architecture(staged_binary)

        if self.component == 'xray':
            config_path = self.detection.get('configPath')
            if config_path and Path(config_path).exists():
                cmd = [str(staged_binary), 'run', '-test', '-config', str(config_path)]
                env = dict(SAFE_PROBE_ENV)
                parent_dir = Path(config_path).parent
                staged_asset = next((p.parent for p in self.staging_dir.rglob('geoip.dat') if p.is_file()), None)
                if (parent_dir / 'geoip.dat').exists():
                    env['XRAY_LOCATION_ASSET'] = str(parent_dir)
                elif staged_asset:
                    env['XRAY_LOCATION_ASSET'] = str(staged_asset)
                elif (self.staging_dir / 'geoip.dat').exists():
                    env['XRAY_LOCATION_ASSET'] = str(self.staging_dir)
                try:
                    res = subprocess.run(cmd, env=env, cwd=str(parent_dir), capture_output=True, timeout=15)
                    if res.returncode != 0:
                        stderr_snippet = (res.stderr or "").strip()[:512]
                        raise ComponentUpgradeError(
                            UpgradeEventCode.SYNTAX_FAILED,
                            detail=f"xray run -test failed: {res.returncode}; {stderr_snippet}",
                        )
                except subprocess.SubprocessError as e:
                    raise ComponentUpgradeError(UpgradeEventCode.SYNTAX_FAILED, detail=str(e))
            else:
                probe_staged_binary(staged_binary, ['version'])

        elif self.component == 'trusttunnel':
            probe_staged_binary(staged_binary, ['--version'])

            wizards = [
                p for p in self.staging_dir.rglob('setup_wizard')
                if p.is_file() and not p.is_symlink() and not p.name.endswith('.antirkn-tmp')
            ]
            if not wizards:
                raise ComponentUpgradeError(
                    UpgradeEventCode.SYNTAX_FAILED,
                    detail='setup_wizard binary missing from archive',
                )

            for w in wizards:
                probe_staged_binary(w, ['--help'])

        elif self.component == 'amneziawg':
            probe_staged_binary(staged_binary, ['--version'])

        elif self.component in ('panel', 'mihomo'):
            probe_staged_binary(staged_binary, ['-v'])

        elif self.component == 'mihomo':
            config_path = self.detection.get('configPath')
            if config_path and Path(config_path).exists():
                cmd = [str(staged_binary), '-t', '-f', str(config_path)]
                try:
                    res = subprocess.run(cmd, capture_output=True, timeout=15)
                    if res.returncode != 0:
                        raise ComponentUpgradeError('upgrade_syntax_failed')
                except subprocess.SubprocessError:
                    raise ComponentUpgradeError('upgrade_syntax_failed')

    def apply_switch(self, staged_binary):
        """Atomic Blue-Green/In-Place binary replacement preserving custom permissions and ownership."""
        self._ensure_detection_and_metadata()
        binary_path = Path(self.detection['binaryPath'])
        meta = self.backup_metadata

        # Stop units if required
        units = meta.get('units', [])
        for unit in units:
            subprocess.run(['/usr/bin/systemctl', 'stop', unit], capture_output=True, timeout=30)

        if self.component == 'panel':
            # Staged composite files in staging directory
            staged_sh = None
            sh_candidates = [p for p in self.staging_dir.rglob('x-ui.sh') if p.is_file() and not p.name.endswith('.antirkn-tmp')]
            if sh_candidates:
                staged_sh = sh_candidates[0]

            staged_xray = None
            xray_candidates = [p for p in self.staging_dir.rglob('*') if p.is_file() and ('xray-linux' in p.name or p.name == 'xray') and not p.name.endswith('.antirkn-tmp')]
            if xray_candidates:
                staged_xray = xray_candidates[0]

            # Primary panel binary update
            atomic_binary_replace(staged_binary, binary_path)

            panel_base = Path('/usr/local/x-ui')
            target_dirs = []
            try:
                panel_base.mkdir(parents=True, exist_ok=True)
                target_dirs.append(panel_base)
            except OSError:
                pass

            if binary_path.parent not in target_dirs and binary_path.parent.exists():
                target_dirs.append(binary_path.parent)

            for p_dir in target_dirs:
                xui_target = p_dir / 'x-ui'
                if xui_target != binary_path:
                    try:
                        atomic_binary_replace(staged_binary, xui_target)
                    except OSError:
                        pass

                if staged_sh:
                    try:
                        atomic_binary_replace(staged_sh, p_dir / 'x-ui.sh')
                    except OSError:
                        pass

                if staged_xray:
                    try:
                        bin_dir = p_dir / 'bin'
                        bin_dir.mkdir(parents=True, exist_ok=True)
                        xray_target_name = 'xray-linux-amd64' if ('xray-linux-amd64' in staged_xray.name or staged_xray.name == 'xray') else staged_xray.name
                        atomic_binary_replace(staged_xray, bin_dir / xray_target_name)
                    except OSError:
                        pass

            # NEVER overwrite or delete /etc/x-ui/x-ui.db
            etc_db = Path('/etc/x-ui/x-ui.db')
            if etc_db.exists() and not etc_db.is_file():
                raise ComponentUpgradeError('upgrade_failed')

        else:
            # Atomic binary replacement in target directory (same mount point)
            atomic_binary_replace(staged_binary, binary_path)

            if self.component == 'trusttunnel':
                for w in self.staging_dir.rglob('setup_wizard'):
                    if w.is_file() and not w.name.endswith('.antirkn-tmp'):
                        target_w = binary_path.parent / 'setup_wizard'
                        atomic_binary_replace(w, target_w)
                        break

            if self.component == 'xray':
                for data_name in ('geoip.dat', 'geosite.dat'):
                    for data_file in self.staging_dir.rglob(data_name):
                        if data_file.is_file() and not data_file.name.endswith('.antirkn-tmp'):
                            try:
                                target_data = binary_path.parent / data_name
                                atomic_binary_replace(data_file, target_data)
                            except OSError:
                                pass

        # Restart units
        for unit in units:
            subprocess.run(['/usr/bin/systemctl', 'start', unit], capture_output=True, timeout=30)

    def verify_health(self, timeout=15):
        """Canary Watchdog: verify systemd ActiveState, restart count, and socket listening."""
        self._ensure_detection_and_metadata()
        units = self.backup_metadata.get('units', []) or (self.detection.get('units', []) if self.detection else [])
        targets = self.backup_metadata.get('healthTargets', [])

        # If no units were active, verify that binary executes properly
        if not units and not targets:
            binary_path = Path(self.detection.get('binaryPath', ''))
            if binary_path.exists():
                try:
                    flag = '--version' if self.component in ('trusttunnel', 'amneziawg') else ('-v' if self.component in ('panel', 'mihomo') else 'version')
                    res = subprocess.run([str(binary_path), flag], capture_output=True, timeout=5)
                    if res.returncode != 0:
                        self.rollback()
                        raise ComponentUpgradeError('upgrade_healthcheck_failed')
                except Exception:
                    self.rollback()
                    raise ComponentUpgradeError('upgrade_healthcheck_failed')
            return

        deadline = time.monotonic() + timeout
        all_healthy = False
        while time.monotonic() < deadline:
            all_healthy = True
            for unit in units:
                res = subprocess.run(['/usr/bin/systemctl', 'is-active', '--quiet', unit], capture_output=True)
                if res.returncode != 0:
                    all_healthy = False
                    break

            if all_healthy and targets:
                for t in targets:
                    show_out = subprocess.run(
                        ['/usr/bin/systemctl', 'show', t['unit_name'], '-p', 'NRestarts', '-p', 'ActiveState'],
                        capture_output=True, text=True, timeout=3
                    )
                    if show_out.returncode == 0:
                        props = dict(line.split('=', 1) for line in show_out.stdout.splitlines() if '=' in line)
                        if props.get('ActiveState') != 'active':
                            all_healthy = False
                            break
                        restarts = int(props.get('NRestarts', 0)) if props.get('NRestarts', '').isdigit() else 0
                        if restarts > t.get('initial_restarts', 0):
                            all_healthy = False
                            break

            if all_healthy:
                bindings = []
                for t in targets:
                    for b in t.get('expected_bindings', []):
                        bindings.append(SocketBinding(host=b['host'], port=b['port'], protocol=b['protocol']))
                if bindings:
                    ok, _ = verify_socket_bindings(
                        bindings,
                        expected_comm='trusttunnel_endpoint' if self.component == 'trusttunnel' else '',
                        timeout_sec=2
                    )
                    if not ok:
                        all_healthy = False

            if all_healthy:
                break
            time.sleep(0.5)

        if not all_healthy:
            self.rollback()
            raise ComponentUpgradeError('upgrade_healthcheck_failed')

    def rollback(self, restore_data=True):
        """Unconditional Self-Healing Rollback: restores binary, configs, and DB, then revives service.

        restore_data=False keeps the live database and config: a late rollback
        (the confirmation window expired) must not erase inbounds that were
        changed after the switch.
        """
        self._ensure_detection_and_metadata()
        meta = self.backup_metadata
        if not meta or not meta.get('binaryPath'):
            meta_path = self.backup_dir / 'meta.json'
            if meta_path.exists():
                try:
                    meta = json.loads(meta_path.read_text())
                    self.backup_metadata = meta
                except Exception:
                    meta = {}
        if not meta or not meta.get('binaryPath'):
            return False

        binary_path = Path(meta.get('binaryPath', ''))
        inplace_backup = binary_path.with_name(binary_path.name + '.antirkn_backup')
        backup_bin = self.backup_dir / binary_path.name

        units = meta.get('units', [])
        for unit in units:
            subprocess.run(['/usr/bin/systemctl', 'stop', unit], capture_output=True, timeout=15)

        # 1. Restore primary binary
        restored = False
        if inplace_backup.exists():
            atomic_file(binary_path, inplace_backup.read_bytes(), meta.get('mode', 0o755))
            restored = True
        elif backup_bin.exists():
            atomic_file(binary_path, backup_bin.read_bytes(), meta.get('mode', 0o755))
            restored = True

        if restored and meta.get('uid') is not None:
            try:
                os.chown(str(binary_path), meta['uid'], meta['gid'])
            except OSError:
                pass

        # Also restore setup_wizard if it was backed up
        for extra in ('setup_wizard',):
            extra_path = binary_path.parent / extra
            extra_bak = binary_path.parent / (extra + '.antirkn_backup')
            if extra_bak.exists():
                atomic_file(extra_path, extra_bak.read_bytes(), 0o755)

        for extra in meta.get('extraFiles', []):
            saved = self.backup_dir / 'extra' / Path(extra['path']).name
            if saved.exists():
                atomic_file(Path(extra['path']), saved.read_bytes(), extra.get('mode', 0o755))

        # 2. Restore DB if panel
        if restore_data and meta.get('dbPath'):
            db_path = Path(meta['dbPath'])
            db_backup = self.backup_dir / 'db_backup.sqlite'
            if db_backup.exists():
                atomic_file(db_path, db_backup.read_bytes(), 0o600)

        # 3. Restore config if present
        if restore_data and meta.get('configPath'):
            cfg_path = Path(meta['configPath'])
            cfg_backup = self.backup_dir / 'config_backup'
            if cfg_backup.exists():
                atomic_file(cfg_path, cfg_backup.read_bytes(), 0o600)

        # 4. Restart units
        for unit in units:
            subprocess.run(['/usr/bin/systemctl', 'restart', unit], capture_output=True, timeout=30)

        return True

    def _probe_socket(self, port, host='127.0.0.1', timeout=2):
        try:
            with socket.create_connection((host, int(port)), timeout=timeout):
                return True
        except (OSError, ValueError):
            return False


def plan(store, component, candidate_payload=None):
    """Generate upgrade plan for runner RPC `component_upgrade_check`."""
    check_system_resources()
    detection = detect_component(component)
    candidate = {}
    if candidate_payload:
        try:
            candidate = json.loads(candidate_payload) if isinstance(candidate_payload, str) else candidate_payload
        except Exception:
            pass

    current_version = detection.get('version')
    target_version = candidate.get('version')
    upgradable = bool(detection['installed'] and target_version and current_version != target_version)

    plan_data = {
        'component': component,
        'installed': detection.get('installed', False),
        'source': detection.get('source', 'unknown'),
        'currentVersion': current_version,
        'candidateVersion': target_version,
        'binaryPath': detection.get('binaryPath'),
        'configPath': detection.get('configPath'),
        'units': detection.get('units', []),
        'upgradable': upgradable,
        'arch': detection.get('arch', normalize_arch()),
        'ready': detection.get('installed', False),
        'snapshot': snapshot_info(store.directory, component) if store is not None else None,
    }
    plan_data['fingerprint'] = canonical_plan_fingerprint(plan_data)
    return plan_data


def installed_panel_versions():
    """Versions read from the installed 3x-ui and Xray binaries (None when unknown)."""
    panel_version = detect_component('panel').get('version')
    xray_version = detect_component('xray').get('version')
    return {k: v for k, v in (('panelVersion', panel_version), ('xrayVersion', xray_version)) if v}


def sync_installed_versions():
    """Make AntiRKN's version observations match the installed binaries.

    Only version fields change; credentials, ids and panel settings are kept.
    Returns the recorded versions, or {} when nothing could be detected.
    """
    from panel_discovery import EXTERNAL_ACCESS, external_access
    from panel import DATABASE
    actual = installed_panel_versions()
    if not actual:
        return {}
    external = external_access()
    if external:
        external.update(actual)
        atomic_file(EXTERNAL_ACCESS, json.dumps(external, sort_keys=True).encode())
    marker = DATABASE / '.antirkn-owner'
    if marker.exists():
        safe_file(marker, 64)
        owner = marker.read_text().strip()
        version_file = DATABASE / '.antirkn-versions'
        recorded = {}
        if version_file.exists():
            safe_file(version_file, 1024)
            recorded = json.loads(version_file.read_text())
        if recorded.get('id', owner) == owner:
            atomic_file(version_file, json.dumps({**recorded, 'id': owner, **actual}, sort_keys=True).encode())
    return actual


class ComponentUpgradeJob:
    """Runner RPC Task implementing `component_upgrade_apply` with 6 checkpoints."""

    def __init__(self, store, request):
        self.store = store
        self.request = request
        self.payload = json.loads(request['payload']) if isinstance(request.get('payload'), str) else request.get('payload', {})
        self.upgrader = ComponentUpgrader(store, request, self.payload)
        self.archive_path = self.upgrader.work_dir / 'release_archive'

    def step(self, checkpoint):
        codes = [
            UpgradeEventCode.PREPARING,
            UpgradeEventCode.DOWNLOADING,
            UpgradeEventCode.BACKING_UP,
            UpgradeEventCode.SYNTAX_CHECKING,
            UpgradeEventCode.SWITCHING,
            UpgradeEventCode.VERIFYING,
        ]
        with self.store.db:
            self.store.event(self.request['id'], codes[checkpoint], checkpoint, 6)

        if checkpoint == 0:
            # Starting another upgrade proves this device controls the server:
            # it closes any confirmation window that is still open.
            for other in Path(self.store.directory).glob('upgrade-*/deadman.json'):
                other_id = other.parent.name[len('upgrade-'):]
                if other_id != self.request['id'] and window_open(self.store.directory, other_id):
                    confirm_upgrade(self.store, other_id)
            # Pre-flight checks
            self.upgrader.pre_check()
            current_plan = plan(self.store, self.payload['component'], self.payload)
            if current_plan['fingerprint'] != self.request['fingerprint']:
                raise ComponentUpgradeError(UpgradeEventCode.CONFLICT, detail='Fingerprint mismatch')
        elif checkpoint == 1:
            # Download or use staged archive
            self.archive_path.parent.mkdir(parents=True, exist_ok=True)
            if not self.archive_path.exists():
                archive_url = self.payload.get('url')
                if self.payload.get('source') == 'snapshot':
                    snapshot_archive(self.store.directory, self.upgrader.component, self.payload.get('version'), self.archive_path)
                elif archive_url and archive_url.startswith('file://'):
                    local_file = Path(archive_url[len('file://'):] if archive_url.startswith('file://') else archive_url)
                    if local_file.exists():
                        atomic_file(self.archive_path, local_file.read_bytes())
                elif archive_url and (archive_url.startswith('https://') or archive_url.startswith('http://')):
                    expected_sha = normalize_sha256(self.payload.get('sha256'))
                    actual_sha = download_verified_artifact(
                        archive_url,
                        self.archive_path,
                        expected_sha,
                    )
                    self.payload['sha256'] = actual_sha
                    self.upgrader.manifest['sha256'] = actual_sha
                elif 'archiveData' in self.payload:
                    import base64
                    atomic_file(self.archive_path, base64.b64decode(self.payload['archiveData']))
            if not self.archive_path.exists():
                raise ComponentUpgradeError(UpgradeEventCode.DOWNLOAD_MISSING, detail='Archive file missing after download')

            expected_sha = self.payload.get('sha256')
            if expected_sha and str(expected_sha).strip():
                verify_sha256(self.archive_path, expected_sha)
            actual_sha = digest(self.archive_path).lower()
            self.payload['sha256'] = actual_sha
            self.upgrader.manifest['sha256'] = actual_sha
        elif checkpoint == 2:
            # Atomic backup of binary, configs, and DB
            self.upgrader.backup()
        elif checkpoint == 3:
            # Extract and syntax pre-check
            staged = self.upgrader.validate_and_stage(self.archive_path)
            self.upgrader.syntax_pre_check(staged)
        elif checkpoint == 4:
            # Atomic switch
            self.upgrader._ensure_detection_and_metadata()
            binary_name = self.payload.get('binaryName') or (Path(self.upgrader.detection['binaryPath']).name if (self.upgrader.detection and self.upgrader.detection.get('binaryPath')) else None)
            staged_candidates = []
            if self.upgrader.component == 'xray':
                xray_names = {'xray', 'xray-linux-amd64', 'xray-linux-arm64'}
                if binary_name:
                    xray_names.add(binary_name)
                staged_candidates = [p for p in self.upgrader.staging_dir.rglob('*') if p.is_file() and p.name in xray_names and not p.name.endswith('.antirkn-tmp')]
            elif binary_name:
                staged_candidates = [p for p in self.upgrader.staging_dir.rglob(binary_name) if p.is_file() and not p.name.endswith('.antirkn-tmp')]
            if not staged_candidates:
                files = [p for p in self.upgrader.staging_dir.rglob('*') if p.is_file() and not p.name.endswith('.antirkn-tmp')]
                if len(files) == 1:
                    staged_candidates = files
                elif binary_name:
                    staged_candidates = [p for p in files if p.name == binary_name]
            staged_binary = staged_candidates[0] if staged_candidates else None
            if not staged_binary:
                raise ComponentUpgradeError('upgrade_binary_not_found')
            self.upgrader.apply_switch(staged_binary)
        elif checkpoint == 5:
            # Canary healthcheck, real connections, then a confirmation window:
            # the server rolls back on its own unless the app confirms in time.
            self.upgrader._ensure_detection_and_metadata()
            self.upgrader.verify_health(timeout=15)
            self.upgrader.verify_connectivity()
            self._sync_panel_access_versions()
            arm_deadman(self.store, self.request)

        done_codes = [
            'upgrade_prepared',
            'upgrade_downloaded',
            'upgrade_backed_up',
            'upgrade_syntax_checked',
            'upgrade_switched',
            'upgrade_checked',
        ]
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, self.request['id']))
            self.store.event(self.request['id'], done_codes[checkpoint], checkpoint + 1, 6)
            if checkpoint == 5:
                self.store.event(self.request['id'], 'upgrade_awaiting_confirmation', 6, 6)

    def _sync_panel_access_versions(self):
        """Record the versions that are actually installed after a panel/Xray switch.

        A 3x-ui archive replaces its bundled Xray too, so both versions are read
        from the binaries rather than taken from the candidate manifest. The app
        verifies the panel against these records; stale records made every later
        VLESS change look like an offline server.
        """
        if self.upgrader.component not in ('xray', 'panel'):
            return
        sync_installed_versions()

    def rollback(self):
        """Invoke auto-rollback on failure or cancellation."""
        try:
            self.upgrader.rollback()
        except Exception:
            pass

    def failure_status(self):
        return 'failed'


# --- Confirmation window ("commit confirmed") -------------------------------
DEADMAN_SECONDS = 300


def _deadman_unit(job_id):
    if not re.fullmatch('[a-f0-9]{32}', job_id or ''):
        raise ComponentUpgradeError('upgrade_conflict')
    return 'antirkn-upgrade-deadman-' + job_id


def _deadman_path(directory, job_id):
    return Path(directory) / ('upgrade-' + job_id) / 'deadman.json'


def _start_deadman_timer(job_id, seconds):
    subprocess.run(['/usr/bin/systemctl', 'stop', _deadman_unit(job_id) + '.timer'], capture_output=True, timeout=30)
    subprocess.run(['/usr/bin/systemctl', 'reset-failed', _deadman_unit(job_id) + '.service'], capture_output=True, timeout=30)
    subprocess.run(['/usr/bin/systemd-run', '--unit=' + _deadman_unit(job_id), '--on-active=%d' % max(1, int(seconds)),
                    '--timer-property=AccuracySec=1s', '--collect', '/usr/bin/python3', '-I', str(Path(__file__).resolve()),
                    'deadman', job_id], capture_output=True, timeout=30, check=True)


def arm_deadman(store, request):
    """Persist the window first, then start an independent systemd timer."""
    path = _deadman_path(store.directory, request['id'])
    path.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.time() + DEADMAN_SECONDS
    atomic_file(path, json.dumps(dict(id=request['id'], deadline=deadline, confirmed=False, rolledBack=False)).encode())
    _start_deadman_timer(request['id'], DEADMAN_SECONDS)


def window_open(directory, job_id):
    """True while an applied upgrade still waits for the app's confirmation."""
    path = _deadman_path(directory, job_id)
    try:
        info = json.loads(path.read_text())
    except (OSError, ValueError):
        return False
    return not info.get('confirmed') and not info.get('rolledBack')


def retire_work_dir(directory, job_id):
    """Drop everything of a finished upgrade but the window record.

    The backup must outlive the job while the confirmation window is open;
    deleting it with the job's transients made the expiry a silent no-op.
    """
    work = Path(directory) / ('upgrade-' + job_id)
    if not work.is_dir():
        return
    for child in work.iterdir():
        if child.name == 'deadman.json':
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(str(child), ignore_errors=True)
        else:
            child.unlink(missing_ok=True)


# --- Snapshot of the previous version ---------------------------------------
# After a confirmed upgrade the programs that ran before it stay on disk, so the
# app can go back to exactly that version (never to one that was not installed).
# Data (3x-ui database, configs) is not part of it: it stays live.
SNAPSHOT_COMPONENTS = ('panel', 'xray', 'trusttunnel')


def _snapshot_dir(directory, component):
    return Path(directory) / 'snapshots' / component


def _drop_inplace_backup(directory, job_id):
    meta_path = Path(directory) / ('upgrade-' + job_id) / 'backup' / 'meta.json'
    try:
        meta = json.loads(meta_path.read_text())
    except (OSError, ValueError):
        return
    # atomic_binary_replace leaves a copy next to every file it replaced;
    # once the window is closed nothing reads them.
    paths = [Path(extra['path']) for extra in meta.get('extraFiles', []) if extra.get('path')]
    if meta.get('binaryPath'):
        binary = Path(meta['binaryPath'])
        paths += [binary, binary.parent / 'setup_wizard']
    for path in paths:
        path.with_name(path.name + '.antirkn_backup').unlink(missing_ok=True)


def keep_snapshot(directory, job_id, component):
    if component not in SNAPSHOT_COMPONENTS:
        return False
    backup = Path(directory) / ('upgrade-' + job_id) / 'backup'
    try:
        meta = json.loads((backup / 'meta.json').read_text())
    except (OSError, ValueError):
        return False
    if not meta.get('version') or not meta.get('binaryPath') or not (backup / Path(meta['binaryPath']).name).is_file():
        return False
    root = Path(directory) / 'snapshots'
    root.mkdir(mode=0o700, exist_ok=True)
    staging, old = root / ('.new-' + component), root / ('.old-' + component)
    for leftover in (staging, old):
        shutil.rmtree(str(leftover), ignore_errors=True)
    os.replace(str(backup), str(staging))
    for name in ('db_backup.sqlite', 'config_backup'):
        (staging / name).unlink(missing_ok=True)
    target = _snapshot_dir(directory, component)
    if target.exists():
        os.replace(str(target), str(old))
    os.replace(str(staging), str(target))
    shutil.rmtree(str(old), ignore_errors=True)
    return True


def snapshot_info(directory, component):
    """{version[, xrayVersion]} of the restorable previous version, or None."""
    try:
        meta = json.loads((_snapshot_dir(directory, component) / 'meta.json').read_text())
    except (OSError, ValueError):
        return None
    if not meta.get('version'):
        return None
    info = dict(version=meta['version'])
    if meta.get('xrayVersion'):
        info['xrayVersion'] = meta['xrayVersion']
    return info


def snapshot_archive(directory, component, version, target):
    """Pack the snapshot like a release archive, so it goes through the normal pipeline."""
    snap = _snapshot_dir(directory, component)
    try:
        meta = json.loads((snap / 'meta.json').read_text())
    except (OSError, ValueError):
        raise ComponentUpgradeError('upgrade_conflict', detail='no snapshot')
    if not version or meta.get('version') != version:
        raise ComponentUpgradeError('upgrade_conflict', detail='snapshot version')
    binary = snap / Path(meta['binaryPath']).name
    if not binary.is_file():
        raise ComponentUpgradeError('upgrade_conflict', detail='snapshot binary')
    Path(target).parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(str(target), 'w:gz') as tar:
        tar.add(str(binary), arcname=binary.name)
        if (snap / 'setup_wizard').is_file():
            tar.add(str(snap / 'setup_wizard'), arcname='setup_wizard')
        for extra in meta.get('extraFiles', []):
            saved = snap / 'extra' / Path(extra['path']).name
            if saved.is_file():
                tar.add(str(saved), arcname=('bin/' + saved.name) if saved.name.startswith('xray-linux') else saved.name)


def confirm_upgrade(store, job_id):
    """The app confirms that it still controls the server after the upgrade."""
    path = _deadman_path(store.directory, job_id)
    if not path.exists():
        raise ComponentUpgradeError('upgrade_conflict')
    safe_file(path, 4096)
    info = json.loads(path.read_text())
    if info.get('rolledBack'):
        raise ComponentUpgradeError('upgrade_rolled_back')
    if not info.get('confirmed'):
        info['confirmed'] = True
        atomic_file(path, json.dumps(info).encode())
        subprocess.run(['/usr/bin/systemctl', 'stop', _deadman_unit(job_id) + '.timer'], capture_output=True, timeout=30)
        with store.db:
            store.event(job_id, 'upgrade_confirmed', 6, 6)
        _drop_inplace_backup(store.directory, job_id)
        row = store.db.execute('SELECT request FROM jobs WHERE id=?', (job_id,)).fetchone()
        try:
            request = json.loads(row[0]) if row else {}
            payload = json.loads(request.get('payload') or '{}') if isinstance(request.get('payload'), str) else request.get('payload', {})
            keep_snapshot(store.directory, job_id, payload.get('component'))
        except (OSError, ValueError) as error:
            sys.stderr.write(f'[runner] snapshot not kept: {type(error).__name__}\n')
        retire_work_dir(store.directory, job_id)
    return info


def _units_settled(units, settle=8):
    time.sleep(settle)
    return all(subprocess.run(['/usr/bin/systemctl', 'is-active', '--quiet', unit], capture_output=True, timeout=10).returncode == 0
               for unit in units)


def _late_rollback(upgrader):
    """Old binaries over the live data first; the pre-switch data only if that does not come up."""
    upgrader.rollback(restore_data=False)
    meta = upgrader.backup_metadata or {}
    units = meta.get('units', [])
    before = meta.get('probeBefore') or {}
    healthy = _units_settled(units) if units else True
    if healthy and before:
        try:
            healthy = not compare_probes(before, probe_component(upgrader.component))
        except Exception:
            healthy = False
    if not healthy and (meta.get('dbPath') or meta.get('configPath')):
        upgrader.rollback(restore_data=True)


def _wait_for_idle(store, job_id, limit=120):
    """Do not restart services under a job the daemon is running right now."""
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        busy = store.db.execute("SELECT 1 FROM jobs WHERE status='running' AND id<>? LIMIT 1", (job_id,)).fetchone()
        if not busy:
            return
        time.sleep(5)


def fire_deadman(store, job_id, wait=True):
    """Roll back an unconfirmed upgrade (timer expiry or recovery after a reboot)."""
    path = _deadman_path(store.directory, job_id)
    if not path.exists():
        return False
    safe_file(path, 4096)
    info = json.loads(path.read_text())
    if info.get('confirmed') or info.get('rolledBack'):
        return False
    row = store.db.execute('SELECT request FROM jobs WHERE id=?', (job_id,)).fetchone()
    if row is None:
        return False
    if wait:
        _wait_for_idle(store, job_id)
        info = json.loads(path.read_text())
        if info.get('confirmed') or info.get('rolledBack'):
            return False
    request = json.loads(row[0])
    payload = json.loads(request['payload']) if isinstance(request.get('payload'), str) else request.get('payload', {})
    upgrader = ComponentUpgrader(store, request, payload)
    _late_rollback(upgrader)
    if upgrader.component in ('panel', 'xray'):
        try:
            sync_installed_versions()
        except Exception as error:
            sys.stderr.write(f'[runner] version sync after rollback failed: {type(error).__name__}\n')
    info['rolledBack'] = True
    atomic_file(path, json.dumps(info).encode())
    with store.db:
        store.db.execute("UPDATE jobs SET status='failed' WHERE id=?", (job_id,))
        store.event(job_id, 'upgrade_rolled_back', 6, 6)
    _drop_inplace_backup(store.directory, job_id)
    retire_work_dir(store.directory, job_id)
    return True


def _backup_version(binary, component):
    flag = '-v' if component == 'panel' else 'version' if component == 'xray' else '--version'
    try:
        out = subprocess.run([str(binary), flag], capture_output=True, text=True, timeout=10)
        return extract_semver(out.stdout or out.stderr)
    except (OSError, subprocess.SubprocessError):
        return None


def _adopt_legacy_backup(directory, job_id, component):
    """A backup left by an older runner (no version recorded) becomes the
    restorable previous version: on a server broken by such an update it is
    the only way back."""
    backup = Path(directory) / ('upgrade-' + job_id) / 'backup'
    try:
        meta = json.loads((backup / 'meta.json').read_text())
    except (OSError, ValueError):
        return False
    if not meta.get('binaryPath'):
        return False
    if not meta.get('version'):
        meta['version'] = _backup_version(backup / Path(meta['binaryPath']).name, component)
        if component == 'panel' and (backup / 'extra' / 'xray-linux-amd64').is_file():
            meta['xrayVersion'] = _backup_version(backup / 'extra' / 'xray-linux-amd64', 'xray')
        if not meta['version']:
            return False
        atomic_file(backup / 'meta.json', json.dumps(meta).encode())
    return keep_snapshot(directory, job_id, component)


def sweep_finished_upgrades(store):
    """Leftovers of finished upgrades (also from older runners, which never
    removed them): archive, staging, backup and the copies next to binaries.
    The newest successful backup of a component without a snapshot is kept
    as its previous version. Jobs that need attention keep everything."""
    works = []
    for work in Path(store.directory).glob('upgrade-*'):
        job_id = work.name[len('upgrade-'):]
        if not work.is_dir() or not re.fullmatch('[a-f0-9]{32}', job_id) or window_open(store.directory, job_id):
            continue
        row = store.db.execute('SELECT status, created, request FROM jobs WHERE id=?', (job_id,)).fetchone()
        if row is None or row[0] not in ('succeeded', 'failed', 'cancelled'):
            continue
        works.append((row[1], job_id, row[0], row[2], work))
    for _created, job_id, status, raw, work in sorted(works, reverse=True):
        if not any(child.name != 'deadman.json' for child in work.iterdir()):
            continue
        _drop_inplace_backup(store.directory, job_id)
        if status == 'succeeded':
            try:
                request = json.loads(raw)
                payload = json.loads(request.get('payload') or '{}') if isinstance(request.get('payload'), str) else request.get('payload') or {}
                component = payload.get('component')
                if component in SNAPSHOT_COMPONENTS and snapshot_info(store.directory, component) is None:
                    _adopt_legacy_backup(store.directory, job_id, component)
            except (OSError, ValueError, ComponentUpgradeError) as error:
                sys.stderr.write(f'[runner] legacy backup not kept: {type(error).__name__}\n')
        retire_work_dir(store.directory, job_id)


def recover_deadmen(store):
    """After a runner restart or reboot: expire due windows, re-arm the others."""
    for path in Path(store.directory).glob('upgrade-*/deadman.json'):
        try:
            info = json.loads(path.read_text())
            if info.get('confirmed') or info.get('rolledBack'):
                continue
            remaining = info.get('deadline', 0) - time.time()
            if remaining <= 0:
                fire_deadman(store, info['id'], wait=False)
            else:
                _start_deadman_timer(info['id'], remaining)
        except Exception as error:
            sys.stderr.write(f'[runner] deadman recovery failed: {type(error).__name__}\n')
    try:
        sweep_finished_upgrades(store)
    except Exception as error:
        sys.stderr.write(f'[runner] upgrade sweep failed: {type(error).__name__}\n')


if __name__ == '__main__' and len(sys.argv) == 3 and sys.argv[1] == 'deadman':
    from runner import Store, STATE
    _store = Store(STATE)
    try:
        fire_deadman(_store, sys.argv[2])
    finally:
        _store.close()
