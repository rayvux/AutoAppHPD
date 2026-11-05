"""Local-only integration test: upload signing, task polling, download and checksum."""
import hashlib
import hmac
import http.server
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import urllib.parse

PAYLOAD = b'PK\x03\x04native-client-test-output'

class Handler(http.server.BaseHTTPRequestHandler):
    polls = 0
    uploaded = None
    errors = []
    fields = {}
    bad_checksum = False
    def log_message(self, *args):
        pass
    def reply(self, data):
        content = json.dumps({'success': True, 'data': data}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(content)
    def do_GET(self):
        path = urllib.parse.urlparse(self.path)
        if path.path == '/api/v5/apk/sts':
            self.reply(dict(ak='TEST_AK', sk='TEST_SK', token='TEST_TOKEN', bucket='test', key='upload/test/'))
        elif path.path == '/api/v5/apk/status':
            query = urllib.parse.parse_qs(path.query)
            if query != {'task_id': ['test-task'], 'akey': ['TEST_AKEY']}:
                Handler.errors.append('incorrect polling query')
            Handler.polls += 1
            self.reply(dict(status=0, message='created') if Handler.polls == 1 else dict(
                status=100, url='/download.apk', md5=('0' * 32 if Handler.bad_checksum else hashlib.md5(PAYLOAD).hexdigest())))
        elif path.path == '/download.apk':
            self.send_response(200); self.send_header('Content-Length', str(len(PAYLOAD)))
            self.end_headers(); self.wfile.write(PAYLOAD)
        else:
            self.send_error(404)
    def do_PUT(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        Handler.uploaded = body
        auth = self.headers['Authorization'].split('/')
        info = '/'.join(auth[:4])
        names = auth[4].split(';')
        quote = lambda value: urllib.parse.quote(value, safe='-_.~')
        headers = '\n'.join(name + ':' + quote(self.headers[name].strip()) for name in sorted(names))
        signing_key = hmac.new(b'TEST_SK', info.encode(), hashlib.sha256).hexdigest()
        expected = hmac.new(signing_key.encode(), ('PUT\n' + self.path + '\n\n' + headers).encode(), hashlib.sha256).hexdigest()
        if auth[5] != expected:
            Handler.errors.append('incorrect BOS authorization')
        self.send_response(200); self.end_headers()
    def do_POST(self):
        from email.parser import BytesParser
        from email.policy import default
        body = self.rfile.read(int(self.headers['Content-Length']))
        message = BytesParser(policy=default).parsebytes(
            ('Content-Type: ' + self.headers['Content-Type'] + '\r\nMIME-Version: 1.0\r\n\r\n').encode() + body)
        Handler.fields = {part.get_param('name', header='content-disposition'): part.get_payload(decode=True).decode()
                          for part in message.iter_parts()}
        expected = hashlib.md5(('TEST_AKEY' + hashlib.md5(Handler.uploaded).hexdigest() + 'TEST_SKEY').encode()).hexdigest()
        if Handler.fields['sign'] != expected:
            Handler.errors.append('incorrect task signature')
        self.reply(dict(taskId='test-task'))

def main():
    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='native-baidu-test-') as directory:
        root = Path(directory); input_file = root / 'input.apk'; output = root / 'output.apk'
        input_file.write_bytes(b'PK\x03\x04native-client-test-input')
        base = [sys.argv[1], '-url=http://127.0.0.1:' + str(server.server_port), '-akey=TEST_AKEY',
                '-skey=TEST_SKEY', '-o=' + str(output), '-t=15']
        result = subprocess.run(base + ['-i=' + str(input_file), '-type=free'], capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stdout + result.stderr
        assert output.read_bytes() == PAYLOAD
        assert Handler.uploaded == input_file.read_bytes()
        assert Handler.fields['bos_path'] == 'upload/test/' + hashlib.md5(b'input').hexdigest() + '.apk'
        assert Handler.fields['type'] == 'free'
        assert not Handler.errors, Handler.errors
        assert 'TEST_SKEY' not in result.stdout and 'TEST_TOKEN' not in result.stdout
        Handler.bad_checksum = True
        failed_output = root / 'must-not-exist.apk'
        bad = subprocess.run(base + ['-g=test-task', '-o=' + str(failed_output)], capture_output=True, text=True, timeout=30)
        assert bad.returncode != 0 and not failed_output.exists()
        assert 'MD5' in bad.stdout
        print('PASS: upload, BOS authorization, task signature, polling, resume, download and bad-checksum rejection')
    server.shutdown()

if __name__ == '__main__':
    main()
