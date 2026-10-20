#!/usr/bin/env python3
"""Regenerate public loopback test credentials with OpenSSL 3.6+, never at runtime.

Leaf validity is bounded for platform TLS policy. Backdate by one day to avoid
CI clock skew. The temporary CA signing key is discarded. Review changed PEMs
before committing; these credentials must never be used outside test fixtures.
"""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import subprocess
import tempfile


def main():
    output = Path(__file__).resolve().parent.parent / 'test/fixtures/mtls'
    output.mkdir(parents=True, exist_ok=True)
    start = datetime.now(timezone.utc) - timedelta(days=1)
    fmt = lambda day: day.strftime('%Y%m%d%H%M%SZ')
    with tempfile.TemporaryDirectory(prefix='protodesk-mtls-fixtures-') as directory:
        work = Path(directory)

        def run(*args):
            subprocess.run(['openssl', *args], cwd=work, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        for name, eku in [('ca', ''), ('server', 'serverAuth'),
                          ('client', 'clientAuth'), ('client-ec', 'clientAuth'),
                          ('untrusted', 'clientAuth')]:
            algorithm = ['ec', '-pkeyopt', 'ec_paramgen_curve:P-256'] if name == 'client-ec' else ['rsa:2048']
            run('req', '-new', '-newkey', *algorithm, '-nodes', '-keyout', f'{name}-key.pem',
                '-out', f'{name}.csr', '-subj', f'/CN=ProtoDesk test-only {name}')
            ca = name == 'ca'
            (work / 'extensions').write_text(
                'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' if ca else
                f'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage={eku}\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n')
            signing = ['-signkey', f'{name}-key.pem'] if ca or name == 'untrusted' else ['-CA', 'ca.pem', '-CAkey', 'ca-key.pem', '-CAcreateserial']
            run('x509', '-req', '-in', f'{name}.csr', *signing,
                '-not_before', fmt(start), '-not_after', fmt(start + timedelta(days=3650 if ca else 365)),
                '-extfile', 'extensions', '-out', f'{name}.pem')
            (output / f'{name}.pem').write_bytes((work / f'{name}.pem').read_bytes())
            if not ca:
                (output / f'{name}-key.pem').write_bytes((work / f'{name}-key.pem').read_bytes())
        (output / 'client-chain.pem').write_bytes((work / 'client.pem').read_bytes() + (work / 'ca.pem').read_bytes())
    print('Generated test-only credentials. CA key was discarded; review fixture diff.')


if __name__ == '__main__':
    main()
