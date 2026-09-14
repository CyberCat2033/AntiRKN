#!/usr/bin/env python3
"""Fetch public, verified test inputs. No server effects or credentials."""
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT=Path(__file__).resolve().parent.parent


def main():
    releases=json.loads((ROOT/'schemas/component-releases.json').read_text())
    previous=json.loads((ROOT/'schemas/component-test-releases.json').read_text())
    entries={
        'tt.tar.gz':releases['trusttunnel']['archives']['endpoint'],
        'awg-tools.zip':releases['amneziawg']['archives']['tools'],
        'awg-source.tar.gz':releases['amneziawg']['archives']['source'],
        'go.tar.gz':releases['amneziawg']['archives']['go'],
        'tt-old.tar.gz':previous['trusttunnelOld'],
        'awg-old-source.tar.gz':previous['amneziawgOld'],
    }
    for name,artifact in entries.items():
        path=Path('/tmp/antirkn-'+name)
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest()!=artifact['sha256']:
            with urllib.request.urlopen(artifact['url'],timeout=60) as source:
                data=source.read(artifact['bytes']+1)
            if len(data)!=artifact['bytes'] or hashlib.sha256(data).hexdigest()!=artifact['sha256']:
                raise ValueError('Fixture archive checksum mismatch: '+name)
            path.write_bytes(data)
        print('Verified',name)
    # Minimal public asset metadata expected by the update fixture.
    Path('/tmp/antirkn-tt-old.json').write_text(json.dumps({'assets':[{
        'name':'trusttunnel-v1.0.33-linux-x86_64.tar.gz',
        'digest':'sha256:'+previous['trusttunnelOld']['sha256']}]}))
    with urllib.request.urlopen('https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/v1.1.0/CONFIGURATION.md',timeout=30) as source:
        Path('/tmp/antirkn-tt-config.md').write_bytes(source.read(1024*1024))


if __name__=='__main__': main()
