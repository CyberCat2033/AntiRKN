#!/usr/bin/env python3
"""Real Drive publication probes on generated synthetic files, never user YAML.

OAuth tokens stay in memory. Persist only IDs allocated by this probe for
recovery; cleanup never discovers files by name or lists the user's Drive.
"""
import argparse
import hashlib
import json
from pathlib import Path
import secrets
import urllib.error
import urllib.parse
import urllib.request
from google_drive_setup import authorize, SetupFailure

API = 'https://www.googleapis.com/drive/v3/'
UPLOAD = 'https://www.googleapis.com/upload/drive/v3/'
SCOPE = 'https://www.googleapis.com/auth/drive.file'
LIMIT = 1024 * 1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def call(method, url, token=None, body=None, headers=None):
    combined = {'Accept-Encoding': 'identity', **(headers or {})}
    if token is not None:
        combined['Authorization'] = 'Bearer ' + token
    if isinstance(body, dict):
        body = json.dumps(body).encode()
        combined['Content-Type'] = 'application/json; charset=UTF-8'
    req = urllib.request.Request(url, data=body, headers=combined, method=method)
    try:
        response = urllib.request.build_opener(NoRedirect).open(req, timeout=40)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        data = response.read(LIMIT + 1)
        if len(data) > LIMIT:
            raise SetupFailure('Oversized response')
        return response.status, dict(response.headers.items()), data


def document(reply):
    if not 200 <= reply[0] < 300:
        raise SetupFailure('Google operation failed HTTP ' + str(reply[0]))
    return json.loads(reply[2])


def multipart(metadata, content):
    boundary = 'antirkn-probe-' + secrets.token_hex(24)
    body = ('--' + boundary + '\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n' +
            json.dumps(metadata) + '\r\n--' + boundary + '\r\nContent-Type: application/yaml\r\n\r\n').encode()
    body += content + ('\r\n--' + boundary + '--\r\n').encode()
    return body, {'Content-Type': 'multipart/related; boundary=' + boundary}


def download_public(url):
    # Follow only known Google download hosts and never attach cookies/OAuth.
    for _ in range(6):
        uri = urllib.parse.urlsplit(url)
        if (uri.scheme != 'https' or uri.username or uri.password or
            not (uri.hostname in ('drive.google.com', 'drive.usercontent.google.com') or
                 uri.hostname.endswith('.googleusercontent.com'))):
            raise SetupFailure('Unexpected download destination')
        status, headers, data = call('GET', url)
        if status in (301, 302, 303, 307, 308):
            target = next((v for k, v in headers.items() if k.lower() == 'location'), None)
            if target is None: raise SetupFailure('Download redirect without target')
            url = urllib.parse.urljoin(url, target)
            continue
        return status, data
    raise SetupFailure('Too many redirects')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--coordinator', action='store_true', help='Exercise the actual Dart publisher and coordinator')
    args = parser.parse_args()
    config = Path.home()/'.config/antirkn/google/desktop-client.json'
    client = json.loads(config.read_text())['installed']
    try:
        credentials = authorize(client, SCOPE)
    except SetupFailure:
        result = {'status': 'NOT_RUN', 'issue': 'authorization_unavailable', 'createdFiles': 0}
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(result), flush=True)
        return
    token = credentials['accessToken']
    nonce = secrets.token_hex(16)
    receipt_dir = config.parent/'publication-probes'
    receipt_dir.mkdir(mode=0o700, exist_ok=True)
    receipt = receipt_dir/(nonce + '.json')
    if args.coordinator:
        import subprocess
        receipt.touch(mode=0o600)
        run = subprocess.run(['dart', 'run', 'tool/drive_publication_smoke.dart'],
            cwd=Path(__file__).resolve().parent.parent,
            input=json.dumps({**credentials, 'receipt': str(receipt)}), text=True,
            capture_output=True)
        # Only the structured smoke report is public. Never print stderr/input.
        try:
            result = json.loads(run.stdout)
        except Exception:
            result = {'status': 'FAIL', 'issue': 'dart-smoke', 'exitCode': run.returncode}
        if receipt.exists():
            clean = True
            for fid in json.loads(receipt.read_text() or '{}').get('allocatedIds', []):
                try:
                    clean &= call('DELETE', API+'files/'+fid, token)[0] in (204,404)
                except Exception:
                    clean = False
            result.setdefault('checks', {})['allocated_files_removed'] = clean
            if clean: receipt.unlink()
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(result), flush=True)
        if result.get('status') != 'PASS': raise SystemExit(1)
        return
    ids = []
    results = {'kind': 'real-drive-publication-synthetic-probe', 'checks': {}, 'observations': {}}
    checks, observations = results['checks'], results['observations']
    content = b'mixed-port: 17890\nmode: rule\nproxies: []\nrules: ["MATCH,DIRECT"]\n# synthetic revision one\n'
    replacement = content.replace(b'one', b'two')
    final = content.replace(b'one', b'three')
    try:
        ids.extend(document(call('GET', API+'files/generateIds?count=1&space=drive&type=files', token))['ids'])
        receipt.write_text(json.dumps({'probe': nonce, 'allocatedIds': ids, 'accountKey': credentials['accountKey']}))
        receipt.chmod(0o600)
        fid = ids[0]
        metadata = {'id': fid, 'name': 'AntiRKN synthetic publication probe.yml', 'mimeType': 'application/yaml',
                    'appProperties': {'antirknProbe': nonce}}
        body, headers = multipart(metadata, content)
        created = document(call('POST', UPLOAD+'files?uploadType=multipart&fields=id,webContentLink', token, body, headers))
        checks['generated_id_create'] = created['id'] == fid
        duplicate = call('POST', UPLOAD+'files?uploadType=multipart', token, body, headers)
        checks['duplicate_id_409'] = duplicate[0] == 409
        meta = call('GET', API+'files/'+fid+'?fields=id,version,headRevisionId,md5Checksum,webContentLink,resourceKey', token)
        first = document(meta)
        observations['metadata_etag_present'] = any(k.lower() == 'etag' for k in meta[1])
        media = call('GET', API+'files/'+fid+'?alt=media', token)
        checks['initial_authorized_readback'] = media[0] == 200 and media[2] == content
        observations['media_etag_present'] = any(k.lower() == 'etag' for k in media[1])
        # A fabricated validator must NEVER allow a conditional mutation.
        wrong = call('PATCH', UPLOAD+'files/'+fid+'?uploadType=media', token, replacement,
                     {'Content-Type': 'application/yaml', 'If-Match': '"antirkn-nonexistent-version"'})
        after_wrong = call('GET', API+'files/'+fid+'?alt=media', token)
        observations['media_wrong_if_match_http'] = wrong[0]
        observations['media_wrong_if_match_preserved_content'] = after_wrong[2] == content
        etag = next((v for k,v in meta[1].items() if k.lower()=='etag'), None)
        observations['media_conditional_write_proven'] = False
        if wrong[0] == 412 and after_wrong[2] == content and etag:
            good = call('PATCH', UPLOAD+'files/'+fid+'?uploadType=media', token, replacement,
                        {'Content-Type':'application/yaml','If-Match':etag})
            stale = call('PATCH', UPLOAD+'files/'+fid+'?uploadType=media', token, final,
                         {'Content-Type':'application/yaml','If-Match':etag})
            current = call('GET', API+'files/'+fid+'?alt=media', token)
            observations['media_matching_if_match_http'] = good[0]
            observations['media_stale_if_match_http'] = stale[0]
            observations['media_conditional_write_proven'] = good[0] == 200 and stale[0] == 412 and current[2] == replacement
        # v2 exposes a file ETag. Probe actual, then stale validators on a
        # regular YAML file; fabricated validators alone are insufficient.
        v2 = 'https://www.googleapis.com/drive/v2/files/' + fid
        v2upload = 'https://www.googleapis.com/upload/drive/v2/files/' + fid + '?uploadType=multipart'
        document(call('PATCH', UPLOAD+'files/'+fid+'?uploadType=media', token, content, {'Content-Type':'application/yaml'}))
        etag = document(call('GET', v2+'?fields=id,etag', token))['etag']
        body, headers = multipart({'properties':[{'key':'antirknHead','value':'synthetic-two','visibility':'PRIVATE'}]}, replacement)
        good = call('PUT', v2upload, token, body, {**headers,'If-Match':etag})
        stale = call('PUT', v2upload, token, body, {**headers,'If-Match':etag})
        checks['v2_matching_etag_updates'] = good[0] == 200
        checks['v2_stale_etag_rejected'] = stale[0] == 412
        props = document(call('GET', v2+'?fields=id,etag,properties', token))
        checks['v2_body_and_head_updated'] = call('GET',API+'files/'+fid+'?alt=media',token)[2] == replacement and any(p.get('key')=='antirknHead' and p.get('value')=='synthetic-two' for p in props.get('properties',[]))
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=2) as pool:
            attempts = [pool.submit(call,'PUT',v2upload,token,body,{**headers,'If-Match':props['etag']}) for _ in range(2)]
            statuses = sorted(f.result()[0] for f in attempts)
        checks['v2_two_writers_one_commit'] = statuses == [200,412]
        observations['v2_parallel_statuses'] = statuses
        # Restore the known first revision before testing the public URL.
        document(call('PATCH', UPLOAD+'files/'+fid+'?uploadType=media', token, content, {'Content-Type':'application/yaml'}))
        document(call('POST', API+'files/'+fid+'/permissions', token, {'type':'anyone','role':'reader','allowFileDiscovery':False}))
        meta = document(call('GET', API+'files/'+fid+'?fields=id,webContentLink,resourceKey', token))
        url = meta.get('webContentLink')
        if not url: raise SetupFailure('No download link returned')
        before_status, before_body = download_public(url)
        checks['public_yaml_without_auth'] = before_status == 200 and before_body == content
        document(call('PATCH', UPLOAD+'files/'+fid+'?uploadType=media', token, final, {'Content-Type':'application/yaml'}))
        after_status, after_body = download_public(url)
        checks['same_url_new_revision_without_auth'] = after_status == 200 and after_body == final
        readback = call('GET', API+'files/'+fid+'?alt=media', token)
        checks['final_authorized_readback'] = readback[0] == 200 and readback[2] == final
        checks['file_id_preserved'] = document(call('GET', API+'files/'+fid+'?fields=id',token))['id']==fid
    except Exception as error:
        results['issue'] = str(error) if isinstance(error, SetupFailure) else type(error).__name__
    finally:
        clean = True
        for fid in ids:
            try:
                clean &= call('DELETE', API+'files/'+fid, token)[0] in (204,404)
            except Exception:
                clean = False
        checks['allocated_files_removed'] = clean
        if clean and receipt.exists(): receipt.unlink()
        results['status'] = 'PASS' if checks and all(checks.values()) and 'issue' not in results else 'FAIL'
        args.evidence.parent.mkdir(parents=True,exist_ok=True)
        args.evidence.write_text(json.dumps(results,indent=2)+'\n')
        print(json.dumps(results),flush=True)


if __name__ == '__main__':
    main()
