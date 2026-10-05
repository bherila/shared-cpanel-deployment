#!/usr/bin/env python3
"""Real TLS chunked responses exercise both curl's cap and the older-curl file cap."""
import http.server
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading
import time

SCRIPT = Path(__file__).resolve().parent / 'origin-fetch.sh'
CURL = os.environ.get('ORIGIN_REAL_CURL') or shutil.which('curl')
assert CURL


class StreamingResponse(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        try:
            # No Content-Length: old curl must rely on the inherited file limit.
            for _ in range(2048):
                self.wfile.write(b'400\r\n' + b'x' * 1024 + b'\r\n')
                self.wfile.flush()
                time.sleep(0.001)
            self.wfile.write(b'0\r\n\r\n')
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass


with tempfile.TemporaryDirectory(prefix='origin-limits-') as directory:
    root = Path(directory)
    binaries = root / 'bin'
    binaries.mkdir()
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-keyout', str(root / 'key.pem'), '-out', str(root / 'cert.pem'),
                    '-days', '1', '-subj', '/CN=localhost'], check=True, capture_output=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), StreamingResponse)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(root / 'cert.pem', root / 'key.pem')
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    for name in ('hostname', 'uapi'):
        target = binaries / name
        target.write_text('#!/usr/bin/env bash\nexit 1\n')
        target.chmod(0o700)
    wrapper = binaries / 'curl'
    wrapper.write_text('''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
if os.environ.get('OLDER_CURL') == '1':
    index = args.index('--max-filesize')
    del args[index:index + 2]
os.execv(os.environ['ACTUAL_CURL'], [os.environ['ACTUAL_CURL'], *args])
''')
    wrapper.chmod(0o700)
    try:
        for older in (False, True):
            scratch = root / ('older' if older else 'native')
            scratch.mkdir()
            env = dict(os.environ, PATH=str(binaries) + ':' + os.environ['PATH'],
                       TMPDIR=str(scratch), ACTUAL_CURL=CURL, OLDER_CURL=str(int(older)))
            process = subprocess.Popen(['bash', str(SCRIPT), f'localhost:{server.server_port}', '/stream', '5'],
                                       env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            maximum = 0
            deadline = time.monotonic() + 10
            while process.poll() is None:
                if time.monotonic() > deadline:
                    process.kill()
                    raise AssertionError("origin response did not finish within fixture deadline")
                for path in scratch.iterdir():
                    try:
                        maximum = max(maximum, path.stat().st_size)
                    except FileNotFoundError:
                        pass
                time.sleep(0.005)
            output, error = process.communicate(timeout=10)
            assert process.returncode == 0 and output == b'\nORIGIN-META 000|\n', (output[-100:], error[-300:])
            assert 0 < maximum <= 262144, maximum
            assert not list(scratch.iterdir()), 'temporary response files survived'
            print('ok - unknown-length TLS response refused within 256KiB ' +
                  ('with older-curl file limit' if older else 'with curl size limit'))
    finally:
        server.shutdown()
        server.server_close()
