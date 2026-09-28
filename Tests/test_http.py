#!/usr/bin/env python3
"""Integration tests: local HTTP only; does not touch network settings or user data."""
import http.server
import json
from pathlib import Path
import subprocess
import threading
import time

root = Path(__file__).resolve().parent.parent
binary = root / 'dist/NetworkLens.app/Contents/MacOS/NetworkLens'
class Fixture(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        if self.path == '/slow':
            time.sleep(4)
        status = {'/ok': 200, '/error': 503, '/head-unsupported': 405, '/redirect': 302, '/slow': 200}.get(self.path, 404)
        self.send_response(status)
        if status == 302:
            self.send_header('Location', '/ok')
        self.send_header('Content-Length', '0')
        self.end_headers()
    def log_message(self, *_):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    for path, ok, code in [('/ok', True, 200), ('/error', False, 503), ('/head-unsupported', True, 405), ('/redirect', False, 302), ('/slow', False, None)]:
        started = time.monotonic()
        output = subprocess.check_output([str(binary), '--probe-url', f'http://127.0.0.1:{server.server_port}{path}'], timeout=7, text=True)
        value = json.loads(output)
        elapsed = time.monotonic() - started
        assert value['ok'] == ok, (path, value)
        assert value.get('statusCode') == code, (path, value)
        assert value['target'] == '127.0.0.1', value
        assert elapsed < 3.5, (path, elapsed)
        print(f'PASS {path}: ok={ok}, HTTP={code}, wall={elapsed:.2f}s')
finally:
    server.shutdown()
print('5 local HTTP integration tests passed')
