"""Local-only protocol regression; never touches Bangcle or real credentials."""
import http.server, threading, tempfile, pathlib, zipfile, io, json, urllib.parse, subprocess, sys, time
from email.parser import BytesParser
from email.policy import default
payload=io.BytesIO()
with zipfile.ZipFile(payload,'w') as z:
    z.writestr('AndroidManifest.xml','local-test')
    z.writestr('classes.dex',bytes(range(256))*4096)
class H(http.server.BaseHTTPRequestHandler):
    records=[];bad=False;authenticated=True;status=0;rotate=False;expire='';ack=False;queuedOnce=False
    transferMode='normal';getCount=0;ranges=[];codes=0
    def log_message(self,*args):pass
    def send(self,data,cookie=None):
        self.send_response(200)
        if cookie:self.send_header('Set-Cookie',cookie)
        self.end_headers();self.wfile.write(json.dumps(data).encode())
    def do_POST(self):
        expected='rotated' if H.rotate else 'test-only'
        assert 'testSession='+expected in self.headers.get('Cookie',''),self.headers.get('Cookie','')
        body=self.rfile.read(int(self.headers.get('Content-Length',0)))
        H.records.append(self.path)
        if H.expire and self.path.endswith(H.expire):
            H.expire=''
            if H.ack:H.status=10
            self.send(dict(code=401,msg='login required'));return
        if self.path.endswith('/getuserset'):
            self.send(dict(code=0,info={}) if H.authenticated else dict(code=401,msg='login required'))
        elif self.path.endswith('/upload'):
            msg=BytesParser(policy=default).parsebytes(('Content-Type: '+self.headers['Content-Type']+'\r\n\r\n').encode()+body)
            parts={p.get_param('name',header='content-disposition'):p for p in msg.iter_parts()}
            assert parts['file'].get_payload(decode=True)==b'test APK input'
            H.rotate=True
            self.send(dict(code=0,msg='123'),'testSession=rotated; Path=/')
        elif self.path.endswith('/completeApkInfo'):
            fields=urllib.parse.parse_qs(body.decode());assert fields['appId']==['123'] and fields['isReinforce']==['true']
            H.status=10;self.send(dict(code=0))
        elif self.path.endswith('/getApkInfo'):
            self.send(dict(code=0,info=dict(reinforceStatus=H.status,reinforceStatusLabel={0:'未加固',4:'加固中',10:'已加固'}.get(H.status,'未知状态'))))
            if H.queuedOnce:H.status=10;H.queuedOnce=False
        elif self.path.endswith('/downApkCode'):
            H.codes+=1
            self.send(dict(code=0,info=dict(model_id='123',sid='test-sid',user_id='test-user',code='secret-code')))
        else:self.send_error(404)
    def do_GET(self):
        assert self.path.startswith('/devwebsite/reinforces/downloadFile?')
        H.getCount+=1;H.ranges.append(self.headers.get('Range'))
        content=payload.getvalue();cut=len(content)//2
        if H.transferMode!='normal':
            if H.getCount==1 and H.transferMode!='range':
                self.send_response(200);self.send_header('Content-Length',str(len(content)));self.send_header('ETag','"v1"');self.end_headers()
                self.wfile.write(content[:cut]);self.wfile.flush();time.sleep(0.1);self.close_connection=True;return
            if H.transferMode=='auth' and H.getCount==2:
                self.send_response(401);self.end_headers();return
            ranged=self.headers.get('Range')
            if ranged and H.transferMode!='ignore':
                offset=int(ranged.split('=')[1].split('-')[0])
                assert self.headers.get('If-Range')=='"v1"'
                self.send_response(206);self.send_header('Content-Range',f'bytes {offset}-{len(content)-1}/{len(content)}')
                self.send_header('Content-Length',str(len(content)-offset));self.send_header('ETag','"v1"');self.end_headers();self.wfile.write(content[offset:]);return
            self.send_response(200);self.send_header('Content-Length',str(len(content)));self.send_header('ETag','"v1"');self.end_headers();self.wfile.write(content);return
        self.send_response(200);self.end_headers();self.wfile.write(b'not an APK' if H.bad else payload.getvalue())
server=http.server.HTTPServer(('127.0.0.1',0),H)
threading.Thread(target=server.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory() as tmp:
    root=pathlib.Path(tmp);apk=root/'input.apk';apk.write_bytes(b'test APK input')
    args=[sys.argv[1],'http://127.0.0.1:'+str(server.server_port),str(apk),str(root/'output.apk')]
    result=subprocess.run(args+['login'],capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stdout+result.stderr
    assert H.records==['/devwebsite/home/getuserset']
    H.authenticated=False;H.records=[]
    result=subprocess.run(args+['login'],capture_output=True,text=True,timeout=30)
    assert result.returncode!=0 and H.records==['/devwebsite/home/getuserset']
    H.authenticated=True;H.records=[]
    result=subprocess.run(args,capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stdout+result.stderr
    assert (root/'output.apk').read_bytes()==payload.getvalue()
    assert 'secret-code' not in result.stdout and 'test-only' not in result.stdout
    assert sum(p.endswith('/upload') for p in H.records)==1
    assert sum(p.endswith('/completeApkInfo') for p in H.records)==1
    # Authentication can expire after upload or after the server accepted submission.
    for index,(endpoint,ack) in enumerate([('/getApkInfo',False),('/completeApkInfo',True),('/downApkCode',False)]):
        H.records=[];H.rotate=False;H.status=0;H.expire=endpoint;H.ack=ack
        args[3]=str(root/('resume-'+str(index)+'.apk'))
        failed=subprocess.run(args,capture_output=True,text=True,timeout=30)
        assert failed.returncode!=0
        checkpoint=pathlib.Path(args[3]).with_suffix('.checkpoint.json')
        assert json.loads(checkpoint.read_text())['appID']=='123'
        before=list(H.records);H.rotate=False
        resumed=subprocess.run(args+['resume'],capture_output=True,text=True,timeout=30)
        assert resumed.returncode==0,resumed.stdout+resumed.stderr
        after=H.records[len(before):]
        assert after[0].endswith('/getApkInfo')
        assert not any(p.endswith('/upload') for p in after)
        assert sum(p.endswith('/completeApkInfo') for p in H.records)==1
        assert pathlib.Path(args[3]).read_bytes()==payload.getvalue()
    # Completed and unknown states must never trigger another submission.
    H.rotate=False;H.status=99;H.records=[]
    args[3]=str(root/'unknown.apk')
    pathlib.Path(args[3]).with_suffix('.checkpoint.json').write_text(json.dumps(dict(appID='123',outputPath=args[3],phase='submitting')))
    unknown=subprocess.run(args+['resume'],capture_output=True,text=True,timeout=30)
    assert unknown.returncode!=0 and H.records==['/devwebsite/reinforces/getApkInfo']
    H.status=10
    H.records=[];H.status=4;H.queuedOnce=True
    args[3]=str(root/'queued.apk')
    pathlib.Path(args[3]).with_suffix('.checkpoint.json').write_text(json.dumps(dict(appID='123',outputPath=args[3],phase='submitted')))
    start=time.monotonic()
    queued=subprocess.run(args+['resume'],capture_output=True,text=True,timeout=30)
    assert queued.returncode==0,queued.stdout+queued.stderr
    assert time.monotonic()-start>=0.05
    assert sum(p.endswith('/getApkInfo') for p in H.records)==2
    assert not any(p.endswith('/upload') or p.endswith('/completeApkInfo') for p in H.records)
    for mode in ['resume','ignore','auth']:
        H.records=[];H.transferMode=mode;H.getCount=0;H.ranges=[];H.codes=0
        args[3]=str(root/(mode+'-transfer.apk'))
        result=subprocess.run(args+['existing'],capture_output=True,text=True,timeout=30)
        if mode=='auth':
            assert result.returncode!=0
            assert pathlib.Path(args[3]+'.part').stat().st_size==len(payload.getvalue())//2
            H.transferMode='range'
            result=subprocess.run(args+['existing'],capture_output=True,text=True,timeout=30)
        assert result.returncode==0,result.stdout+result.stderr
        assert pathlib.Path(args[3]).read_bytes()==payload.getvalue()
        assert H.ranges[0] is None and H.ranges[1]==f'bytes={len(payload.getvalue())//2}-',(mode,H.ranges,result.stdout)
        assert H.codes>=2
        assert not pathlib.Path(args[3]+'.part').exists()
        assert not any(p.endswith('/upload') or p.endswith('/completeApkInfo') for p in H.records)
        assert 'secret-code' not in result.stdout
    H.transferMode='normal'
    H.records=[];H.bad=True
    args[3]=str(root/'bad.apk')
    result=subprocess.run(args+['existing'],capture_output=True,text=True,timeout=30)
    assert result.returncode!=0 and not (root/'bad.apk').exists()
    assert not any(p.endswith('/upload') or p.endswith('/completeApkInfo') for p in H.records)
    print('PASS: auto download retry, fresh download credentials, HTTP Range resume, safe fallback when Range ignored, partial survives login/restart, cookie rotation, no duplicate upload/submission, ZIP validation')
server.shutdown()
