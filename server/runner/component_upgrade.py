"""Universal transactional component upgrader for native and adopted installations.

Provides dynamic upstream discovery, pre-flight safety checks, syntax validation,
atomic binary replacement, canary healthcheck, and self-healing auto-rollback.
"""
from __future__ import annotations

from contextlib import contextmanager
import fcntl
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
from sysutil import run as sysutil_run
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

# The official 3x-ui layout; a module constant so tests can point it elsewhere.
PANEL_BASE = Path('/usr/local/x-ui')

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
        out = sysutil_run(['/usr/bin/systemctl', 'list-units', '--all', '--plain', '--no-legend', *patterns], text=True, timeout=10)
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

                show_out = sysutil_run(['/usr/bin/systemctl', 'show', unit,
                     '-p', 'ActiveState', '-p', 'NRestarts', '-p', 'WorkingDirectory'], text=True, timeout=5)
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
            res = sysutil_run(['/usr/bin/ss', '-tulnp'], text=True, timeout=3)
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

def real_target(path):
    """The file a write must replace: an adopted binary behind a symlink keeps
    its link, the file it points to gets the new content."""
    path = Path(path)
    return Path(os.path.realpath(str(path))) if path.is_symlink() else path


def install_bytes(target, data, mode, uid=None, gid=None):
    """Write next to `target` with the given mode/owner, then rename over it."""
    target = Path(target)
    temp = target.with_name('.' + target.name + '.' + secrets.token_hex(8) + '.antirkn-tmp')
    fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            if uid is not None and gid is not None:
                try:
                    os.fchown(stream.fileno(), uid, gid)
                except OSError:
                    pass
            os.fchmod(stream.fileno(), mode)
            os.fsync(stream.fileno())
        os.replace(str(temp), str(target))
    except BaseException:
        try:
            os.unlink(str(temp))
        except OSError:
            pass
        raise
    fd = os.open(str(target.parent), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def extra_saved_name(extra):
    """Name of a companion's copy in backup/extra: keyed by its full path, so
    x-ui.sh in two panel directories never share a copy (older backups used
    the bare file name)."""
    return extra.get('saved') or Path(extra['path']).name


def companion_key(path):
    return hashlib.sha256(str(path).encode()).hexdigest()[:12] + '-' + Path(path).name


def atomic_binary_replace(staged_path: Path, target_path: Path) -> Path:
    """Atomic replacement within the target directory, keeping its mode and owner.

    No copy is left next to the target: the step-2 backup is the only source a
    rollback restores from (a repeated switch would have overwritten such a
    copy with the new binary)."""
    target_path = real_target(target_path)
    target_path.parent.mkdir(parents=True, exist_ok=True)
    if target_path.exists():
        st = target_path.stat()
        mode, uid, gid = stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid
    else:
        mode, uid, gid = 0o755, None, None
    install_bytes(target_path, Path(staged_path).read_bytes(), mode, uid, gid)
    return target_path


@contextmanager
def upgrade_lock(directory, timeout=10):
    """Serializes confirmation, expiry and job rollbacks of component upgrades."""
    fd = os.open(str(Path(directory) / 'upgrade.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        deadline = None
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                now = time.monotonic()
                if deadline is None:
                    deadline = now + timeout
                elif now >= deadline:
                    raise ComponentUpgradeError('upgrade_conflict') from None
                time.sleep(0.1)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)

def _ownership(path):
    st = Path(path).stat()
    return dict(mode=stat.S_IMODE(st.st_mode), uid=st.st_uid, gid=st.st_gid)


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
        res = sysutil_run([str(p), *probe_args], text=True, timeout=timeout_sec, env=SAFE_PROBE_ENV, check=False)
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
    require_https: bool = False,
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
                if require_https and not str(resp.geturl()).startswith('https://'):
                    # Nothing but TLS vouches for an archive without a digest.
                    raise ComponentUpgradeError(UpgradeEventCode.DOWNLOAD_FAILED, detail='redirected off https')
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
        except ComponentUpgradeError:
            part_path.unlink(missing_ok=True)
            raise
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


# The upstream repository of each component's releases (as the app discovers them).
RELEASE_REPOSITORIES = {
    'panel': 'MHSanaei/3x-ui',
    'xray': 'XTLS/Xray-core',
    'trusttunnel': 'TrustTunnel/TrustTunnel',
    'mihomo': 'MetaCubeX/mihomo',
}


def pinned_release_url(component, url):
    """An HTTPS release asset of the component's own upstream repository."""
    repo = RELEASE_REPOSITORIES.get(component)
    if not repo or not isinstance(url, str):
        return False
    prefix = 'https://github.com/' + repo + '/releases/download/'
    if not url.startswith(prefix):
        return False
    rest = url[len(prefix):]
    return re.fullmatch(r'[A-Za-z0-9._+-]+/[A-Za-z0-9._+-]+', rest) is not None and '..' not in rest.split('/')


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
        res = sysutil_run(['/usr/bin/systemctl', 'is-active', '--quiet', unit_name], timeout=5)
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
                out = sysutil_run([str(panel_bin), '-v'], text=True, timeout=5)
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
                    out = sysutil_run([str(c), 'version'], text=True, timeout=5)
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
                    out = sysutil_run([str(c), '--version'], text=True, timeout=5)
                    result['version'] = extract_semver(out.stdout or out.stderr)
                except Exception:
                    pass
                break
        # Find active awg units
        try:
            out = sysutil_run(['/usr/bin/systemctl', 'list-units', '--state=active', '--type=service', '--no-legend',
                                  'antirkn-awg@*.service', 'awg-quick@*.service'], text=True, timeout=10)
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
                    out = sysutil_run([str(c), '--version'], text=True, timeout=5)
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
                    out = sysutil_run([str(c), '-v'], text=True, timeout=5)
                    result['version'] = extract_semver(out.stdout or out.stderr)
                except Exception:
                    pass
                break

    return result


def extract_archive_safe(archive_path, extract_dir, binary_name=None, max_size=500 * 1024 * 1024):
    """Safe extraction preventing path traversal, symlink hijacking, and zip-bombs."""
    # binaryName comes from the request payload and names the raw-binary file:
    # a plain file name only, checked before anything is written.
    if binary_name is not None and (not isinstance(binary_name, str) or binary_name in ('.', '..')
                                    or not re.fullmatch(r'[A-Za-z0-9._+-]{1,64}', binary_name)):
        raise ComponentUpgradeError(UpgradeEventCode.SYNTAX_FAILED, detail='archive_unsafe_path')
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
                # Only plain files and directories: Pythons without
                # extraction filters would follow a link member (or a later
                # member written through it) out of the staging directory.
                if not (member.isfile() or member.isdir()):
                    raise ComponentUpgradeError(UpgradeEventCode.SYNTAX_FAILED, detail='archive_unsafe_member')
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


def probe_component(component, deadline=None):
    """{target: ok} real connectivity of what this component serves.

    `deadline` (time.monotonic) bounds the whole probe; targets it leaves no
    time for count as failed."""
    import upgrade_probe
    if component in ('panel', 'xray'):
        return upgrade_probe.probe_vless(deadline=deadline)
    if component == 'trusttunnel':
        return upgrade_probe.probe_tls_listeners(discover_trusttunnel_targets(), deadline=deadline)
    if component == 'amneziawg':
        return upgrade_probe.probe_awg(deadline=deadline)
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

        # 1. Binary backup. The step-2 copy is the only rollback source; the
        # file behind a symlinked (adopted) path is what the switch replaces.
        real = real_target(binary_path)
        st = real.stat()
        mode = stat.S_IMODE(st.st_mode)
        data = real.read_bytes()
        self.backup_metadata = {
            'binaryPath': str(binary_path),
            'realPath': str(real),
            'mode': mode,
            'uid': st.st_uid,
            'gid': st.st_gid,
            'size': st.st_size,
            'sha256': hashlib.sha256(data).hexdigest(),
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

        atomic_file(self.backup_dir / binary_path.name, data, mode)

        # Backup setup_wizard alongside trusttunnel_endpoint if present
        if self.component == 'trusttunnel':
            wizard = real.parent / 'setup_wizard'
            if wizard.is_file() and not wizard.is_symlink():
                atomic_file(self.backup_dir / 'setup_wizard', wizard.read_bytes(), 0o755)
                self.backup_metadata['wizard'] = _ownership(wizard)

        # 2. Config backup
        if self.detection.get('configPath'):
            cfg_path = Path(self.detection['configPath'])
            if cfg_path.exists():
                cfg_backup = self.backup_dir / 'config_backup'
                atomic_file(cfg_backup, cfg_path.read_bytes(), 0o600)
                self.backup_metadata['configSha256'] = digest(cfg_path)
                self.backup_metadata['configOwner'] = _ownership(cfg_path)

        # 3. Database backup (for 3X-UI SQLite DB)
        if self.detection.get('dbPath'):
            db_path = Path(self.detection['dbPath'])
            if db_path.exists():
                self.backup_metadata['dbOwner'] = _ownership(db_path)
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
        # A file the switch adds where there was none is recorded too, so a
        # rollback removes it instead of leaving the new version behind.
        extras, created = [], []
        for extra in self._companion_files(binary_path):
            target = real_target(extra)
            if target.is_file():
                name = companion_key(target)
                saved = self.backup_dir / 'extra' / name
                saved.parent.mkdir(parents=True, exist_ok=True)
                owner = _ownership(target)
                atomic_file(saved, target.read_bytes(), owner['mode'])
                extras.append(dict(path=str(extra), realPath=str(target), saved=name, **owner))
            elif not os.path.lexists(str(target)) and target.parent.is_dir():
                created.append(str(target))
        self.backup_metadata['extraFiles'] = extras
        self.backup_metadata['createdFiles'] = created

        # 5. Real connectivity before the switch, compared after it.
        try:
            self.backup_metadata['probeBefore'] = probe_component(self.component)
        except Exception:
            self.backup_metadata['probeBefore'] = {}

        atomic_file(self.backup_dir / 'meta.json', json.dumps(self.backup_metadata).encode())

    def _companion_files(self, binary_path):
        """Every file the switch may write besides the main binary.

        Only an existing panel layout is touched: no directory is created
        (an adopted /usr/bin/x-ui used to get /usr/local/x-ui/* and even
        /usr/bin/bin/xray-* written next to it, with no backup). A new file
        is allowed only inside an existing bin/ directory."""
        binary_path = Path(binary_path)
        if self.component == 'panel':
            files = []
            dirs = []
            for directory in (PANEL_BASE, binary_path.parent):
                if directory.is_dir() and not directory.is_symlink() and directory not in dirs:
                    dirs.append(directory)
            for directory in dirs:
                if directory / 'x-ui' != binary_path and (directory / 'x-ui').is_file():
                    files.append(directory / 'x-ui')
                if (directory / 'x-ui.sh').is_file():
                    files.append(directory / 'x-ui.sh')
                if (directory / 'bin').is_dir() and not (directory / 'bin').is_symlink():
                    files += [directory / 'bin/xray-linux-amd64', directory / 'bin/xray-linux-arm64']
            return files
        if self.component == 'xray':
            # Xray reads geo data next to the core; a file added there is
            # recorded by backup() and removed by a rollback.
            return [binary_path.parent / name for name in ('geoip.dat', 'geosite.dat')]
        return []

    def _write_companion(self, staged, target):
        """Replace a companion recorded by backup(); anything else is skipped."""
        meta = self.backup_metadata or {}
        live = real_target(target)
        allowed = {extra.get('realPath') or str(real_target(extra['path'])) for extra in meta.get('extraFiles', [])}
        allowed.update(meta.get('createdFiles', []))
        if str(live) not in allowed:
            return False
        atomic_binary_replace(staged, live)
        return True

    def _previous_core(self):
        """The Xray that ran before the switch (from this upgrade's backup)."""
        meta = self.backup_metadata or {}
        if self.component == 'xray' and meta.get('binaryPath'):
            core = self.backup_dir / Path(meta['binaryPath']).name
        elif self.component == 'panel':
            core = next((self.backup_dir / 'extra' / extra_saved_name(extra) for extra in meta.get('extraFiles', [])
                         if Path(extra['path']).name == 'xray-linux-' + ('arm64' if normalize_arch() == 'aarch64' else 'amd64')), None)
            if core is None:
                return None
        else:
            return None
        return core if core.is_file() and os.access(core, os.X_OK) else None

    def _probe_after(self, deadline=None):
        """New core as the client, plus the previous core: double hop entry
        servers and older clients keep running it, and a new server can stop
        accepting them (measured: Xray 25.1 clients vs a 26.11 server)."""
        results = dict(probe_component(self.component, deadline=deadline))
        core = self._previous_core()
        if core is not None:
            import upgrade_probe
            results.update({'previous:' + k: ok for k, ok in upgrade_probe.probe_vless(binary=core, deadline=deadline).items()})
        return results

    def verify_connectivity(self, budget=None):
        """Fail when an inbound/endpoint that worked before the switch fails after it.

        The whole check, probes included, ends by one deadline; the job rolls
        back on the error (once, not here)."""
        self._ensure_detection_and_metadata()
        before = dict(self.backup_metadata.get('probeBefore') or {})
        if not any(before.values()):
            return []
        if self._previous_core() is not None:
            # Before the switch the previous core was the installed one.
            before.update({'previous:' + k: ok for k, ok in list(before.items())})
        if budget is None:
            budget = min(300, 30 + 12 * len(before))
        deadline = time.monotonic() + budget
        while True:
            failed = compare_probes(before, self._probe_after(deadline))
            if not failed:
                return []
            if time.monotonic() + 3 >= deadline:
                break
            time.sleep(3)
        raise ComponentUpgradeError('upgrade_connectivity_failed', detail=','.join(failed))

    def validate_and_stage(self, downloaded_archive_path):
        """Validate archive SHA-256 and extract binary into staging directory."""
        self._ensure_detection_and_metadata()
        archive = Path(downloaded_archive_path)
        if not archive.exists():
            raise ComponentUpgradeError(UpgradeEventCode.DOWNLOAD_MISSING)

        expected_sha = normalize_sha256(str(self.manifest.get('sha256') or ''))
        actual_sha = digest(archive).lower()
        if expected_sha and actual_sha != expected_sha:
            raise ComponentUpgradeError(UpgradeEventCode.CHECKSUM_FAILED, detail='archive digest mismatch')
        self.manifest['sha256'] = actual_sha

        binary_name = self.manifest.get('binaryName') or (Path(self.detection['binaryPath']).name if (self.detection and self.detection.get('binaryPath')) else None)
        # A repeated step starts from an empty staging tree, never from leftovers.
        if self.staging_dir.is_dir() and not self.staging_dir.is_symlink():
            shutil.rmtree(str(self.staging_dir))
        self.staging_dir.mkdir(parents=True, exist_ok=True)
        extract_archive_safe(archive, self.staging_dir, binary_name=binary_name)
        staged_binary = self._select_staged(binary_name)
        if self.manifest.get('binarySha256'):
            if digest(staged_binary) != self.manifest['binarySha256']:
                raise ComponentUpgradeError('upgrade_checksum_failed')
        # Step 4 switches exactly the file chosen here.
        atomic_file(self.work_dir / 'staged.json', json.dumps(dict(binary=str(staged_binary.relative_to(self.staging_dir)))).encode())
        return staged_binary

    def staged_binary(self):
        """The binary step 3 validated (recorded in staged.json)."""
        try:
            relative = PurePosixPath(json.loads((self.work_dir / 'staged.json').read_text())['binary'])
        except (OSError, ValueError, KeyError, TypeError):
            raise ComponentUpgradeError('upgrade_binary_not_found') from None
        if relative.is_absolute() or '..' in relative.parts:
            raise ComponentUpgradeError('upgrade_binary_not_found')
        staged = self.staging_dir / str(relative)
        if staged.is_symlink() or not staged.is_file():
            raise ComponentUpgradeError('upgrade_binary_not_found')
        return staged

    def _select_staged(self, binary_name):
        def files(pattern='*'):
            return sorted(p for p in self.staging_dir.rglob(pattern)
                          if p.is_file() and not p.is_symlink() and not p.name.endswith('.antirkn-tmp'))

        if self.component == 'panel':
            # Composite 3x-ui distributions: x-ui, x-ui.sh, bin/xray-linux-amd64.
            staged_candidates = files('x-ui') or [p for p in files() if not p.name.endswith('.sh')]
            if not staged_candidates:
                raise ComponentUpgradeError('upgrade_binary_not_found')
            for extra in files():
                if extra.name == 'x-ui.sh' or 'xray-linux' in extra.name or extra.name == 'xray':
                    extra.chmod(0o755)
        else:
            staged_candidates = []
            if self.component == 'xray':
                xray_names = {'xray', 'xray-linux-amd64', 'xray-linux-arm64'}
                if binary_name:
                    xray_names.add(binary_name)
                staged_candidates = [p for p in files() if p.name in xray_names]
            elif binary_name:
                staged_candidates = files(binary_name)
            if not staged_candidates:
                every = files()
                if len(every) == 1:
                    staged_candidates = every
                elif binary_name:
                    staged_candidates = [p for p in every if p.name == binary_name]
            if not staged_candidates:
                raise ComponentUpgradeError('upgrade_binary_not_found')
        staged_binary = staged_candidates[0]
        staged_binary.chmod(0o755)
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
                    res = sysutil_run(cmd, env=env, cwd=str(parent_dir), timeout=15)
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
            # TrustTunnel 1.3+ ships no setup_wizard: the endpoint carries it
            # (`trusttunnel_endpoint --setup-wizard`). The old one, if any, stays.
            # A linked one is never followed.
            if any(p.is_symlink() for p in self.staging_dir.rglob('setup_wizard')):
                raise ComponentUpgradeError(
                    UpgradeEventCode.SYNTAX_FAILED,
                    detail='setup_wizard is a link',
                )
            for w in wizards:
                probe_staged_binary(w, ['--help'])

        elif self.component == 'amneziawg':
            probe_staged_binary(staged_binary, ['--version'])

        elif self.component == 'panel':
            probe_staged_binary(staged_binary, ['-v'])

        elif self.component == 'mihomo':
            probe_staged_binary(staged_binary, ['-v'])
            config_path = self.detection.get('configPath')
            if config_path and Path(config_path).exists():
                # `-t` parses the whole config and exits non-zero on an error;
                # `-d` keeps it on the live home directory (geodata, providers).
                home = str(Path(config_path).parent)
                cmd = [str(staged_binary), '-t', '-d', home, '-f', str(config_path)]
                try:
                    res = sysutil_run(cmd, env=SAFE_PROBE_ENV, cwd=home, timeout=15)
                except (OSError, subprocess.SubprocessError):
                    raise ComponentUpgradeError(UpgradeEventCode.SYNTAX_FAILED, detail='mihomo -t did not run') from None
                if res.returncode != 0:
                    raise ComponentUpgradeError(UpgradeEventCode.SYNTAX_FAILED, detail='mihomo -t rejected the config')

    def apply_switch(self, staged_binary):
        """Atomic Blue-Green/In-Place binary replacement preserving custom permissions and ownership."""
        self._ensure_detection_and_metadata()
        binary_path = Path(self.detection['binaryPath'])
        meta = self.backup_metadata

        # Stop units if required
        units = meta.get('units', [])
        for unit in units:
            sysutil_run(['/usr/bin/systemctl', 'stop', unit], timeout=30)

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

            # Companions only where backup() recorded them (existing layout).
            for extra in self._companion_files(binary_path):
                name = extra.name
                if name == 'x-ui':
                    self._write_companion(staged_binary, extra)
                elif name == 'x-ui.sh':
                    if staged_sh:
                        self._write_companion(staged_sh, extra)
                elif staged_xray and name == ('xray-linux-amd64' if ('xray-linux-amd64' in staged_xray.name or staged_xray.name == 'xray') else staged_xray.name):
                    self._write_companion(staged_xray, extra)

            # NEVER overwrite or delete /etc/x-ui/x-ui.db
            etc_db = Path('/etc/x-ui/x-ui.db')
            if etc_db.exists() and not etc_db.is_file():
                raise ComponentUpgradeError('upgrade_failed')

        else:
            # Atomic binary replacement in target directory (same mount point)
            atomic_binary_replace(staged_binary, binary_path)

            if self.component == 'trusttunnel':
                for w in sorted(self.staging_dir.rglob('setup_wizard')):
                    if w.is_file() and not w.is_symlink():
                        atomic_binary_replace(w, real_target(binary_path).parent / 'setup_wizard')
                        break

            if self.component == 'xray':
                for data_name in ('geoip.dat', 'geosite.dat'):
                    for data_file in self.staging_dir.rglob(data_name):
                        if data_file.is_file() and not data_file.name.endswith('.antirkn-tmp'):
                            self._write_companion(data_file, binary_path.parent / data_name)
                            break

        # Restart units
        for unit in units:
            sysutil_run(['/usr/bin/systemctl', 'start', unit], timeout=30)

    def verify_health(self, timeout=15):
        """Canary Watchdog: verify systemd ActiveState, restart count, and socket listening."""
        self._ensure_detection_and_metadata()
        units = self.backup_metadata.get('units', []) or (self.detection.get('units', []) if self.detection else [])
        targets = self.backup_metadata.get('healthTargets', [])

        # If no units were active, verify that binary executes properly
        if not units and not targets:
            binary_path = Path(self.detection.get('binaryPath', ''))
            if binary_path.exists():
                flag = '--version' if self.component in ('trusttunnel', 'amneziawg') else ('-v' if self.component in ('panel', 'mihomo') else 'version')
                try:
                    res = sysutil_run([str(binary_path), flag], timeout=5)
                except (OSError, subprocess.SubprocessError):
                    res = None
                if res is None or res.returncode != 0:
                    raise ComponentUpgradeError('upgrade_healthcheck_failed')
            return

        deadline = time.monotonic() + timeout
        all_healthy = False
        while time.monotonic() < deadline:
            all_healthy = True
            for unit in units:
                try:
                    res = sysutil_run(['/usr/bin/systemctl', 'is-active', '--quiet', unit], timeout=5)
                except subprocess.SubprocessError:
                    res = None
                if res is None or res.returncode != 0:
                    all_healthy = False
                    break

            if all_healthy and targets:
                for t in targets:
                    try:
                        show_out = sysutil_run(['/usr/bin/systemctl', 'show', t['unit_name'], '-p', 'NRestarts', '-p', 'ActiveState'], text=True, timeout=3)
                    except subprocess.SubprocessError:
                        all_healthy = False
                        break
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
            # The job rolls back on this error, exactly once.
            raise ComponentUpgradeError('upgrade_healthcheck_failed')

    def _load_backup_meta(self):
        meta = self.backup_metadata if (self.backup_metadata or {}).get('binaryPath') else None
        if meta is None:
            try:
                meta = json.loads((self.backup_dir / 'meta.json').read_text())
            except (OSError, ValueError):
                meta = None
        if not isinstance(meta, dict) or not meta.get('binaryPath'):
            # Without the step-2 backup nothing can be restored: never report success.
            raise ComponentUpgradeError('upgrade_rollback_failed', detail='no backup')
        self.backup_metadata = meta
        return meta

    def _restore_plan(self, meta):
        """[(saved copy, live file, owner)] in the order a rollback writes them back."""
        binary = Path(meta['binaryPath'])
        target = Path(meta['realPath']) if meta.get('realPath') else real_target(binary)
        items = [(self.backup_dir / binary.name, target,
                  dict(mode=meta.get('mode', 0o755), uid=meta.get('uid'), gid=meta.get('gid')))]
        wizard = self.backup_dir / 'setup_wizard'
        if wizard.is_file():
            items.append((wizard, real_target(target.parent / 'setup_wizard'), meta.get('wizard') or dict(mode=0o755)))
        for extra in meta.get('extraFiles', []):
            live = Path(extra['realPath']) if extra.get('realPath') else real_target(extra['path'])
            items.append((self.backup_dir / 'extra' / extra_saved_name(extra), live,
                          dict(mode=extra.get('mode', 0o755), uid=extra.get('uid'), gid=extra.get('gid'))))
        for saved, _live, _owner in items:
            if saved.is_symlink() or not saved.is_file():
                raise ComponentUpgradeError('upgrade_rollback_failed', detail='backup copy missing')
        return items

    def _switched(self, meta, items):
        """Whether any file of the new version is in place (or a live file is gone)."""
        if any(os.path.lexists(path) for path in meta.get('createdFiles', [])):
            return True
        for index, (saved, live, _owner) in enumerate(items):
            if not live.is_file():
                return True
            expected = meta.get('sha256') if index == 0 and meta.get('sha256') else digest(saved)
            if digest(live) != expected:
                return True
        return False

    def rollback(self, restore_data=True, force=False):
        """Restore the step-2 backup (binary, companions and, with restore_data,
        database and config with their original owner/mode), then restart.

        restore_data=False keeps the live database and config: a late rollback
        (the confirmation window expired) must not erase inbounds that were
        changed after the switch. Idempotent: a finished rollback is not
        repeated (force=True repeats it, for the late data restore), and when
        no file of the new version is in place only the units are started.
        Raises ComponentUpgradeError('upgrade_rollback_failed') when nothing
        can be restored, a unit does not stop (nothing is replaced under a
        running service; the backup stays), the restored binary does not
        match the backup or a restarted unit does not become active.
        """
        meta = self._load_backup_meta()
        items = self._restore_plan(meta)
        marker = self.work_dir / 'rollback.json'
        try:
            state = json.loads(marker.read_text())
        except (OSError, ValueError):
            state = {}
        if state.get('done') and not force:
            return True
        units = meta.get('units', [])
        if not state and not force and not self._switched(meta, items):
            # The switch never ran (or stopped before replacing anything):
            # data was not touched, only the units may have been stopped.
            for unit in units:
                _systemctl('start', unit)
            atomic_file(marker, json.dumps(dict(done=True, restoreData=False)).encode())
            return True
        restore_data = bool(restore_data or state.get('restoreData'))
        atomic_file(marker, json.dumps(dict(done=False, restoreData=restore_data)).encode())

        if not all([_systemctl('stop', unit) for unit in units]):
            raise ComponentUpgradeError('upgrade_rollback_failed', detail='unit did not stop')

        for saved, live, owner in items:
            install_bytes(live, saved.read_bytes(), owner.get('mode', 0o755), owner.get('uid'), owner.get('gid'))
        for path in meta.get('createdFiles', []):
            # Added by the switch where nothing was before.
            try:
                if not os.path.isdir(path) or os.path.islink(path):
                    os.unlink(path)
            except FileNotFoundError:
                pass

        if restore_data and meta.get('dbPath'):
            db_backup = self.backup_dir / 'db_backup.sqlite'
            if db_backup.is_file():
                db_path = real_target(meta['dbPath'])
                owner = meta.get('dbOwner') or _owner_or_default(db_path)
                # A journal of the new version must not be replayed onto the old database.
                for suffix in ('-wal', '-shm'):
                    Path(str(db_path) + suffix).unlink(missing_ok=True)
                install_bytes(db_path, db_backup.read_bytes(), owner['mode'], owner.get('uid'), owner.get('gid'))

        if restore_data and meta.get('configPath'):
            cfg_backup = self.backup_dir / 'config_backup'
            if cfg_backup.is_file():
                cfg_path = real_target(meta['configPath'])
                owner = meta.get('configOwner') or _owner_or_default(cfg_path)
                install_bytes(cfg_path, cfg_backup.read_bytes(), owner['mode'], owner.get('uid'), owner.get('gid'))

        restarted = all([_systemctl('restart', unit) for unit in units])

        if meta.get('sha256') and digest(items[0][1]) != meta['sha256']:
            raise ComponentUpgradeError('upgrade_rollback_failed', detail='restored binary differs')
        if not restarted or not _units_active(units):
            raise ComponentUpgradeError('upgrade_rollback_failed', detail='unit not active')
        atomic_file(marker, json.dumps(dict(done=True, restoreData=restore_data)).encode())
        return True


def _owner_or_default(path):
    try:
        return _ownership(path)
    except OSError:
        return dict(mode=0o600, uid=None, gid=None)


def _units_active(units, timeout=15):
    """All units report active within ``timeout`` seconds (bounded polling)."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            if all(sysutil_run(['/usr/bin/systemctl', 'is-active', '--quiet', unit], timeout=5).returncode == 0
                   for unit in units):
                return True
        except (OSError, subprocess.SubprocessError):
            pass
        if time.monotonic() >= deadline:
            return False
        time.sleep(1)


def _systemctl(action, unit, timeout=30):
    """Whether the action succeeded in time; callers decide what a failure means."""
    try:
        return sysutil_run(['/usr/bin/systemctl', action, unit], timeout=timeout).returncode == 0
    except (OSError, subprocess.SubprocessError):
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


def upgrade_checks():
    """The device-check module (it imports this one)."""
    import upgrade_checks as module
    return module


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
            # Pre-flight checks
            self.upgrader.pre_check()
            self.upgrader.work_dir.mkdir(parents=True, exist_ok=True)
            checked = self.upgrader.work_dir / 'preflight.json'
            if not checked.exists():
                current_plan = plan(self.store, self.payload['component'], self.payload)
                if current_plan['fingerprint'] != self.request['fingerprint']:
                    raise ComponentUpgradeError(UpgradeEventCode.CONFLICT, detail='Fingerprint mismatch')
                atomic_file(checked, b'{}')
            if upgrade_checks().checked(self.payload):
                upgrade_checks().before_upgrade(self.store, self.request, self.payload)
            # Starting another upgrade proves this device controls the server:
            # it closes any confirmation window that is still open. Only after
            # the plan check (also on a repeated step): a confirmation keeps a
            # new snapshot, which is part of the plan's fingerprint.
            for other in sorted(Path(self.store.directory).glob('upgrade-*/deadman.json')):
                other_id = other.parent.name[len('upgrade-'):]
                if other_id != self.request['id'] and window_open(self.store.directory, other_id):
                    if _read_window(other).get('checked'):
                        # Only the device's checks may keep that upgrade.
                        raise ComponentUpgradeError(UpgradeEventCode.CONFLICT)
                    confirm_upgrade(self.store, other_id)
        elif checkpoint == 1:
            # Download or use staged archive
            self.archive_path.parent.mkdir(parents=True, exist_ok=True)
            expected_sha = normalize_sha256(str(self.payload.get('sha256') or ''))
            actual_sha = None
            if not self.archive_path.exists():
                archive_url = self.payload.get('url')
                if self.payload.get('source') == 'snapshot':
                    snapshot_archive(self.store.directory, self.upgrader.component, self.payload.get('version'), self.archive_path)
                elif archive_url and archive_url.startswith('file://'):
                    local_file = Path(archive_url[len('file://'):])
                    if local_file.exists():
                        atomic_file(self.archive_path, local_file.read_bytes())
                elif archive_url and (archive_url.startswith('https://') or archive_url.startswith('http://')):
                    # Without a digest only an HTTPS release of the component's
                    # own upstream repository is accepted (never plain HTTP).
                    if not expected_sha and not pinned_release_url(self.upgrader.component, archive_url):
                        raise ComponentUpgradeError(UpgradeEventCode.CHECKSUM_FAILED, detail='missing_expected_digest')
                    actual_sha = download_verified_artifact(archive_url, self.archive_path, expected_sha,
                                                            require_https=not expected_sha)
                elif 'archiveData' in self.payload:
                    import base64
                    atomic_file(self.archive_path, base64.b64decode(self.payload['archiveData']))
            if not self.archive_path.exists():
                raise ComponentUpgradeError(UpgradeEventCode.DOWNLOAD_MISSING, detail='Archive file missing after download')
            if actual_sha is None:
                actual_sha = digest(self.archive_path).lower()
            if expected_sha and actual_sha != expected_sha:
                raise ComponentUpgradeError(UpgradeEventCode.CHECKSUM_FAILED, detail='archive digest mismatch')
            self.payload['sha256'] = actual_sha
            self.upgrader.manifest['sha256'] = actual_sha
        elif checkpoint == 2:
            # Atomic backup of binary, configs, and DB
            self.upgrader.backup()
        elif checkpoint == 3:
            # Extract and syntax pre-check; the chosen binary is recorded for step 4.
            staged = self.upgrader.validate_and_stage(self.archive_path)
            self.upgrader.syntax_pre_check(staged)
            if upgrade_checks().checked(self.payload):
                upgrade_checks().before_switch(self.store, self.payload)
        elif checkpoint == 4:
            # Atomic switch of exactly the binary step 3 validated.
            self.upgrader._ensure_detection_and_metadata()
            self.upgrader.apply_switch(self.upgrader.staged_binary())
        elif checkpoint == 5:
            # Canary healthcheck, real connections, then a confirmation window:
            # the server rolls back on its own unless the app confirms in time.
            self.upgrader._ensure_detection_and_metadata()
            self.upgrader.verify_health(timeout=15)
            self.upgrader.verify_connectivity()
            self._sync_panel_access_versions()
            if upgrade_checks().checked(self.payload):
                seconds = upgrade_checks().window(self.store, self.request, self.payload)
                arm_deadman(self.store, self.request, seconds, checked=True)
            else:
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
                waiting = 'upgrade_awaiting_checks' if upgrade_checks().checked(self.payload) else 'upgrade_awaiting_confirmation'
                self.store.event(self.request['id'], waiting, 6, 6)

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

    def rollback(self, checkpoint=None):
        """Undo this job after a failure or cancellation at `checkpoint`.

        Before the switch (checkpoints 0-3) nothing live was changed: only the
        staging tree goes; no unit is stopped and no data is restored. From the
        switch on the step-2 backup is restored (once, see
        ComponentUpgrader.rollback). Returns whether live files were restored.
        Errors propagate: the job then needs attention and keeps its backup.
        """
        if checkpoint is not None and checkpoint < 4:
            shutil.rmtree(str(self.upgrader.staging_dir), ignore_errors=True)
            return False
        with upgrade_lock(self.store.directory, timeout=600):
            self.upgrader.rollback()
            path = _deadman_path(self.store.directory, self.request['id'])
            if path.exists():
                # A window armed before a crash must not roll back a second time.
                info = json.loads(path.read_text())
                if not info.get('rolledBack'):
                    info['rolledBack'] = True
                    atomic_file(path, json.dumps(info).encode())
                _stop_deadman_timer(self.request['id'])
        return True

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
    sysutil_run(['/usr/bin/systemctl', 'stop', _deadman_unit(job_id) + '.timer'], timeout=30)
    sysutil_run(['/usr/bin/systemctl', 'reset-failed', _deadman_unit(job_id) + '.service'], timeout=30)
    sysutil_run(['/usr/bin/systemd-run', '--unit=' + _deadman_unit(job_id), '--on-active=%d' % max(1, int(seconds)),
                    '--timer-property=AccuracySec=1s', '--collect', '/usr/bin/python3', '-I', str(Path(__file__).resolve()),
                    'deadman', job_id], timeout=30, check=True)


def _stop_deadman_timer(job_id):
    try:
        sysutil_run(['/usr/bin/systemctl', 'stop', _deadman_unit(job_id) + '.timer'], timeout=30)
    except (OSError, subprocess.SubprocessError):
        pass


def arm_deadman(store, request, seconds=DEADMAN_SECONDS, checked=False):
    """Persist the window first, then start an independent systemd timer.

    A checked window (upgrade_checks) is confirmed only by the device's
    connection checks, never by a plain confirmation."""
    path = _deadman_path(store.directory, request['id'])
    path.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.time() + seconds
    info = dict(id=request['id'], deadline=deadline, confirmed=False, rolledBack=False)
    if checked:
        info['checked'] = True
    atomic_file(path, json.dumps(info).encode())
    _start_deadman_timer(request['id'], seconds)


def window_open(directory, job_id):
    """True while an applied upgrade still waits for the app's confirmation."""
    path = _deadman_path(directory, job_id)
    try:
        info = json.loads(path.read_text())
    except (OSError, ValueError):
        return False
    return not info.get('confirmed') and not info.get('rolledBack') and not info.get('rollbackFailed')


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
        names = set()
        for extra in meta.get('extraFiles', []):
            saved = snap / 'extra' / extra_saved_name(extra)
            name = Path(extra['path']).name
            if saved.is_file() and name not in names and name != Path(meta['binaryPath']).name:
                names.add(name)
                tar.add(str(saved), arcname=('bin/' + name) if name.startswith('xray-linux') else name)


def confirm_upgrade(store, job_id, timeout=10, verify=None):
    """The app confirms that it still controls the server after the upgrade.

    Serialized with the expiry and job rollbacks: a window whose rollback is
    running (or failed) is never confirmed (upgrade_conflict). A checked
    window needs `verify` (upgrade_checks.commit), called under the lock."""
    path = _deadman_path(store.directory, job_id)
    if not path.exists():
        raise ComponentUpgradeError('upgrade_conflict')
    with upgrade_lock(store.directory, timeout):
        safe_file(path, 4096)
        info = json.loads(path.read_text())
        if info.get('rolledBack'):
            raise ComponentUpgradeError('upgrade_rolled_back')
        if info.get('rollingBack') or info.get('rollbackFailed'):
            raise ComponentUpgradeError('upgrade_conflict')
        if info.get('checked') and not info.get('confirmed'):
            if verify is None:
                raise ComponentUpgradeError('upgrade_checks_required')
            verify(info)
        if not info.get('confirmed'):
            info['confirmed'] = True
            atomic_file(path, json.dumps(info).encode())
            _stop_deadman_timer(job_id)
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
    def active(unit):
        try:
            return sysutil_run(['/usr/bin/systemctl', 'is-active', '--quiet', unit], timeout=10).returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False
    return all(active(unit) for unit in units)


def _late_rollback(upgrader):
    """Old binaries over the live data first; the pre-switch data only if that does not come up."""
    upgrader.rollback(restore_data=False)
    meta = upgrader.backup_metadata or {}
    units = meta.get('units', [])
    before = meta.get('probeBefore') or {}
    healthy = _units_settled(units) if units else True
    if healthy and before:
        try:
            deadline = time.monotonic() + min(300, 30 + 12 * len(before))
            healthy = not compare_probes(before, probe_component(upgrader.component, deadline=deadline))
        except Exception:
            healthy = False
    if not healthy and (meta.get('dbPath') or meta.get('configPath')):
        upgrader.rollback(restore_data=True, force=True)


WORKER_ALIVE_WITHIN = 30
DEFER_LIMIT = 6 * 3600


def _wait_for_idle(store, job_id, limit=120):
    """True once no other job runs under a live worker; False after `limit` seconds.

    Services are never restarted under a job the daemon is running right now.
    A 'running' row without a fresh worker heartbeat runs nowhere."""
    deadline = time.monotonic() + limit
    while True:
        busy = store.db.execute("SELECT 1 FROM jobs WHERE status='running' AND id<>? LIMIT 1", (job_id,)).fetchone()
        beat = store.db.execute('SELECT heartbeat FROM health WHERE id=1').fetchone()
        if not busy or beat is None or not 0 <= time.time() - beat[0] < WORKER_ALIVE_WITHIN:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(5)


def _read_window(path):
    safe_file(path, 4096)
    return json.loads(path.read_text())


def _settle_window_job(store, job_id, info, only_succeeded=False):
    """The job status after the window's rollback, recorded in deadman.json
    first. One transaction with its event; with only_succeeded (recovery
    after a crash between the two writes) a job already moved on is kept."""
    failed = bool(info.get('rollbackFailed'))
    with store.db:
        row = store.db.execute('SELECT status FROM jobs WHERE id=?', (job_id,)).fetchone()
        if row is None or only_succeeded and row[0] != 'succeeded':
            return False
        store.db.execute('UPDATE jobs SET status=? WHERE id=?', ('needs_attention' if failed else 'failed', job_id))
        store.event(job_id, 'upgrade_rollback_failed' if failed else 'upgrade_rolled_back', 6, 6)
    if not failed:
        _drop_inplace_backup(store.directory, job_id)
        retire_work_dir(store.directory, job_id)
    return True


def fire_deadman(store, job_id, wait=True):
    """Roll back an unconfirmed upgrade (timer expiry or recovery after a reboot)."""
    path = _deadman_path(store.directory, job_id)
    if not path.exists():
        return False
    info = _read_window(path)
    if info.get('confirmed') or info.get('rolledBack') or info.get('rollbackFailed'):
        return False
    row = store.db.execute('SELECT request FROM jobs WHERE id=?', (job_id,)).fetchone()
    if row is None:
        return False
    if wait:
        # Defer while another job runs, however long; the app may still
        # confirm meanwhile. After DEFER_LIMIT the next runner start expires it.
        started = time.monotonic()
        while not _wait_for_idle(store, job_id):
            info = _read_window(path)
            if info.get('confirmed') or info.get('rolledBack') or info.get('rollbackFailed'):
                return False
            if time.monotonic() - started >= DEFER_LIMIT:
                sys.stderr.write('[runner] upgrade expiry deferred: another job keeps running\n')
                return False
    request = json.loads(row[0])
    payload = json.loads(request['payload']) if isinstance(request.get('payload'), str) else request.get('payload', {})
    with upgrade_lock(store.directory, timeout=600):
        # Re-read under the lock: a confirmation may have won the race.
        info = _read_window(path)
        if info.get('confirmed') or info.get('rolledBack') or info.get('rollbackFailed'):
            return False
        info['rollingBack'] = True
        atomic_file(path, json.dumps(info).encode())
        upgrader = ComponentUpgrader(store, request, payload)
        try:
            _late_rollback(upgrader)
        except Exception as error:
            # Keep the backup and stop retrying: this needs a person.
            sys.stderr.write(f'[runner] late rollback failed: {type(error).__name__}\n')
            info['rollbackFailed'] = True
            atomic_file(path, json.dumps(info).encode())
            _settle_window_job(store, job_id, info)
            raise
        if upgrader.component in ('panel', 'xray'):
            try:
                sync_installed_versions()
            except Exception as error:
                sys.stderr.write(f'[runner] version sync after rollback failed: {type(error).__name__}\n')
        # The window first: a crash before the job update below leaves
        # rolledBack with a succeeded job, which recover_deadmen settles
        # without rolling back a second time.
        info['rolledBack'] = True
        info.pop('rollingBack', None)
        atomic_file(path, json.dumps(info).encode())
        _settle_window_job(store, job_id, info)
    return True


def _backup_version(binary, component):
    flag = '-v' if component == 'panel' else 'version' if component == 'xray' else '--version'
    try:
        out = sysutil_run([str(binary), flag], text=True, timeout=10)
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
        core = next((backup / 'extra' / extra_saved_name(extra) for extra in meta.get('extraFiles', [])
                     if Path(extra['path']).name.startswith('xray-linux-')), backup / 'extra' / 'xray-linux-amd64')
        if component == 'panel' and core is not None and core.is_file():
            meta['xrayVersion'] = _backup_version(core, 'xray')
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
            if info.get('rolledBack') or info.get('rollbackFailed'):
                # The window's rollback ended but the job update was lost.
                job_id = path.parent.name[len('upgrade-'):]
                if info.get('id') == job_id:
                    _settle_window_job(store, job_id, info, only_succeeded=True)
                continue
            if info.get('confirmed'):
                continue
            remaining = info.get('deadline', 0) - time.time()
            if info.get('rollingBack'):
                remaining = 0  # Interrupted mid-rollback: finish it now.
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
