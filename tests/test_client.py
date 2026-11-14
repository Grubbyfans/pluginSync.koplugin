"""Run actual client modules under LuaJIT with filesystem/UI adapters.

Requires Python + lupa (pip install lupa). No KOReader UI or hardware emulation.
"""
import json
import os
from pathlib import Path
import shutil
import unittest
import uuid
import zipfile
import socket as pysocket
import select as pyselect
import time
import errno
import threading
import http.client
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.base = Path('.research') / ('test-' + uuid.uuid4().hex)
        self.base.mkdir(parents=True)
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        lua = self.lua

        def attributes(name, key=None):
            p = Path(name)
            if not p.exists() and not p.is_symlink():
                return None
            mode = 'link' if p.is_symlink() else 'directory' if p.is_dir() else 'file'
            attr={'mode':mode,'size':p.stat().st_size if mode == 'file' else 0}
            return attr.get(key) if key else lua.table_from(attr)

        def mkdir(name):
            try:
                Path(name).mkdir()
                return True
            except OSError as error:
                return None, str(error)

        def rmdir(name):
            Path(name).rmdir()
            return True

        g = lua.globals()
        g.py_attr, g.py_mkdir, g.py_rmdir = attributes, mkdir, rmdir
        g.py_dir = lambda name: lua.table_from(['.', '..'] + sorted(os.listdir(name)))
        g.py_realpath = lambda name: str(Path(name).resolve()).replace('\\', '/') if Path(name).exists() else None
        lua.execute('''
            local lfs = {attributes=py_attr,symlinkattributes=py_attr,mkdir=py_mkdir,rmdir=py_rmdir,realpath=py_realpath}
            function lfs.dir(path)
                local names,i=py_dir(path),0
                return function() i=i+1; return names[i] end
            end
            package.preload['libs/libkoreader-lfs']=function() return lfs end
            package.preload['ffi/util']=function() return {df=function() return 1000000000,900000000,800000000 end} end
        ''')
        self.fs = lua.execute('return dofile("fsutil.lua")')
        self.archive = lua.execute('return dofile("archive.lua")')
        self.installer = lua.execute('return dofile("installer.lua")')

    def tearDown(self):
        shutil.rmtree(self.base)

    def make_zip(self, entries=None, compression=zipfile.ZIP_STORED):
        filename = self.base / 'package.zip'
        with zipfile.ZipFile(filename, 'w', compression=compression) as z:
            for name, data in (entries or {
                'demo.koplugin/main.lua': b'return {new=true}',
                'demo.koplugin/_meta.lua': b'return {version="1.1.0"}',
                'demo.koplugin/sub/new.txt': b'new',
            }).items():
                z.writestr(name, data)
        return filename.as_posix()

    def extract(self, filename):
        stage = (self.base / 'stage').as_posix()
        self.fs.mkdir(stage)
        return self.archive.extract(filename, 'demo.koplugin', stage, self.fs)

    def test_syntax_all_lua(self):
        for filename in ROOT.glob('*.lua'):
            self.lua.execute('assert(loadfile(...))', filename.as_posix())

    def test_versions(self):
        version = self.lua.execute('return dofile("version.lua")')
        for a, b, expected in [
            ('1.10.0','1.9.0',1), ('1.0.0','2.0.0',-1),
            ('1.0.0-alpha.2','1.0.0-alpha.10',-1), ('1.0.0-rc.1','1.0.0',-1),
            ('1.0.0+a','1.0.0+b',0), ('v2','v2',0), ('v2','v3',None),
            ('01.0.0','1.0.0',None), ('1.0.0-01','1.0.0',None),
            ('2026.11','2026.12',None), (None,'1.0.0',None),
        ]:
            self.assertEqual(version.compare(a,b),expected,(a,b))
        self.assertEqual(version.status('1.0.0','2.0.0',True),'PC 版本较旧')
        self.assertEqual(version.status(None,None,False),'未安装')

    def test_catalog_filters_and_sorting(self):
        self.lua.execute('''
            local catalog,version=dofile('catalog.lua'),dofile('version.lua')
            local plugins={
                {id='update.koplugin',name='Zebra',version='2.0.0'},
                {id='same.koplugin',name='Alpha',version='1.0.0'},
                {id='missing.koplugin',name='Beta',version='1.0.0'},
                {id='old.koplugin',name='Gamma',version='0.9.0'},
                {id='unknown.koplugin',name='Unknown'},
                {id='conflict.koplugin',name='Conflict',version='9.0.0'},
            }
            local function lookup(plugin)
                if plugin.id == 'conflict.koplugin' then error('duplicate paths') end
                return '/plugins/' .. plugin.id,plugin.id ~= 'missing.koplugin','1.0.0'
            end
            local rows=catalog.rows(plugins,lookup,version,'updates','priority')
            assert(#rows == 1 and rows[1].plugin.id == 'update.koplugin')
            rows=catalog.rows(plugins,lookup,version,'missing','priority')
            assert(#rows == 1 and rows[1].plugin.id == 'missing.koplugin')
            rows=catalog.rows(plugins,lookup,version,'all','priority')
            assert(#rows == 6 and rows[1].plugin.id == 'update.koplugin')
            assert(rows[2].plugin.id == 'missing.koplugin' and rows[3].status == '本机目录冲突')
            rows=catalog.rows(plugins,lookup,version,'all','name')
            assert(rows[1].plugin.name == 'Alpha' and rows[6].plugin.name == 'Zebra')
            rows=catalog.rows(plugins,lookup,version,'all','name_desc')
            assert(rows[1].plugin.name == 'Zebra')
        ''')

    def test_list_position_clamps_and_preserves_focus(self):
        self.lua.execute('''
            local catalog=dofile('catalog.lua')
            local items={}
            for i=1,10 do items[i]={plugin_id='plugin-' .. i} end
            local page,index=catalog.restorePosition(items,4,2,'plugin-6',6)
            assert(page == 2 and index == 6)
            page,index=catalog.restorePosition(items,4,2,'plugin-9',6)
            assert(page == 2 and index == 6) -- don't follow sorted item to another page
            page,index=catalog.restorePosition(items,4,2,'plugin-7',6)
            assert(page == 2 and index == 7)
            page,index=catalog.restorePosition({items[1],items[2]},4,3,'plugin-9',9)
            assert(page == 1 and index == 2)
            page,index=catalog.restorePosition(items,4,1,nil,1)
            assert(page == 1 and index == 1)
        ''')

    def test_version_files_priority_blank_values_and_no_execution(self):
        directory=(self.base/'versioned').as_posix()
        self.fs.mkdir(directory)
        self.discovery_runtime()
        version=self.lua.execute('return dofile("version.lua")')
        decoder=self.lua.eval('require("json")')
        self.fs.write(directory+'/_meta.lua','error("must not execute"); return {version="1.0.0"}')
        self.fs.write(directory+'/pluginsync.json','{"version":" 2.0.0 "}')
        self.assertEqual(version.read(directory,decoder),'2.0.0')
        self.fs.write(directory+'/pluginsync.json','{"version":"  "}')
        self.assertEqual(version.read(directory,decoder),'1.0.0')
        self.fs.write(directory+'/pluginsync.json','invalid JSON')
        self.assertEqual(version.read(directory,decoder),'1.0.0')

    def test_space_check_blocks_before_writes_and_handles_old_api(self):
        files=self.extract(self.make_zip())
        target=self.base/'target'
        target.mkdir()
        (target/'main.lua').write_text('old code')
        self.lua.globals().pending=self.lua.table_from({'files':files,'stage':(self.base/'stage').as_posix(),'target':target.as_posix()})
        self.lua.globals().test_fs=self.fs
        self.lua.execute('''
            local installer=dofile('installer.lua')
            local availableSpace=test_fs.availableSpace
            local info=installer.spaceInfo(pending,test_fs)
            assert(info.bytes > 0 and info.required > info.bytes and info.available == 800000000)
            test_fs.availableSpace=function() return 0 end
            local ok,err=pcall(installer.install,pending,test_fs)
            assert(not ok and err:find('空间不足',1,true))
            local f=assert(io.open(pending.target .. '/main.lua','rb'))
            assert(f:read('*a') == 'old code'); f:close()
            test_fs.availableSpace=function() return nil,'statvfs unavailable' end
            ok,err=pcall(installer.install,pending,test_fs)
            assert(not ok and err:find('尚未覆盖文件',1,true))
            test_fs.availableSpace=function() return info.required end
            installer.install(pending,test_fs) -- exact estimate is enough
            test_fs.availableSpace=availableSpace
            local util=require('ffi/util')
            util.df=function() return 100,70,50 end
            assert(test_fs.availableSpace('.') == 50) -- available, not root-reserved free
            util.df=function() return 100,70 end
            assert(test_fs.availableSpace('.') == 70) -- old KOReader two-value API
            util.df=function() return 100,70,0 end
            assert(test_fs.availableSpace('.') == 0)
            util.df=function() return nil,'failed' end
            assert(test_fs.availableSpace('.') == nil)
            util.df=function() error('unsupported') end
            assert(test_fs.availableSpace('.') == nil)
        ''')
        self.assertEqual((target/'main.lua').read_text(),'return {new=true}')

    def test_history_persistence_limit_and_write_failure(self):
        self.lua.globals().history_file=(self.base/'history.lua').as_posix()
        self.lua.execute('''
            local history=dofile('history.lua')
            local function serialize(value)
                if type(value) == 'table' then
                    local parts={}
                    for key,item in pairs(value) do parts[#parts+1]='[' .. serialize(key) .. ']=' .. serialize(item) end
                    return '{' .. table.concat(parts,',') .. '}'
                elseif type(value) == 'number' then return tostring(value)
                else return string.format('%q',value) end
            end
            local settings={data={}}
            function settings:readSetting(key,default) return self.data[key] or default end
            function settings:saveSetting(key,value) self.data[key]=value end
            function settings:flush()
                local f=assert(io.open(history_file,'wb'))
                assert(f:write('return ' .. serialize(self.data)))
                assert(f:close())
            end
            for i=1,55 do history.append(settings,{id='demo.koplugin',version=tostring(i),time=i,result='成功',operation='安装'}) end
            local reopened=dofile(history_file)
            assert(#reopened.history == 50 and reopened.history[1].version == '55' and reopened.history[50].version == '6')
            settings.flush=function() error('permission denied') end
            assert(not pcall(history.append,settings,{id='bad.koplugin',result='失败'}))
            assert(#settings.data.history == 50 and settings.data.history[1].version == '55')
            assert(dofile(history_file).history[1].version == '55')
        ''')

    def test_actionable_errors(self):
        diagnostics=self.lua.execute('return dofile("diagnostics.lua")')
        for raw,expected in [('请求失败: 401','Token'), ('timeout','超时'),
                             ('connection refused','启动 PC'), ('No space left on device','存储空间不足'),
                             ('Permission denied','写入权限'), ('ZIP 截断','重新下载'),
                             ('目标冲突: main.lua','冲突')]:
            self.assertIn(expected,diagnostics.explain(raw))

    def discovery_runtime(self):
        lua=self.lua
        lua.globals().py_decode=lambda text: lua.table_from(json.loads(text)) if isinstance(json.loads(text),dict) else json.loads(text)
        lua.globals().py_encode=lambda value: json.dumps(dict(value.items()),ensure_ascii=False)
        lua.execute('''
            package.preload.json=function() return {decode=py_decode,encode=py_encode} end
        ''')

    def test_discovery_reply_validation(self):
        self.discovery_runtime()
        self.lua.execute('''
            package.preload.socket=function() return {} end
            local discovery=dofile('discovery.lua')
            local json=require('json')
            local reply={type='pluginsync-server',service='koreader-plugin-sync',apiVersion=1,
                nonce='request-123',port=3456,name='My PC',authRequired=true,address='http://evil/path'}
            local result=discovery.parse(json.encode(reply),'192.168.1.8','request-123')
            assert(result.address == 'http://192.168.1.8:3456' and result.authRequired)
            assert(not discovery.parse(json.encode(reply),'999.1.2.3','request-123'))
            assert(not discovery.parse(json.encode(reply),'224.1.2.3','request-123'))
            assert(not discovery.parse(json.encode(reply),'192.168.1.8','wrong-nonce'))
            reply.port=0
            assert(not discovery.parse(json.encode(reply),'192.168.1.8','request-123'))
            reply.port=3456; reply.service='other'
            assert(not discovery.parse(json.encode(reply),'192.168.1.8','request-123'))
            assert(not discovery.parse('bad JSON','192.168.1.8','request-123'))
            assert(not discovery.parse(string.rep('x',1025),'192.168.1.8','request-123'))
        ''')

    def test_discovery_subnet_targets_and_optional_interface_api(self):
        self.discovery_runtime()
        self.lua.execute('''
            package.preload.socket=function() return {} end
            local discovery=dofile('discovery.lua')
            assert(discovery.broadcast('192.168.0.20','255.255.255.0') == '192.168.0.255')
            assert(discovery.broadcast('10.24.3.4','255.255.240.0') == '10.24.15.255')
            assert(discovery.broadcast('10.24.3.4','255.255.0.0') == '10.24.255.255')
            assert(not discovery.broadcast('10.24.3.4','255.255.255.254'))
            assert(not discovery.broadcast('10.24.3.4','255.0.255.0'))
            local targets=discovery.targets{knownAddress='http://192.168.0.111:3000',
                broadcasts={'192.168.0.255','192.168.0.255'}}
            assert(#targets == 3 and targets[1] == '192.168.0.111' and targets[2] == '192.168.0.255' and targets[3] == '255.255.255.255')
            targets=discovery.targets{knownAddress='http://192.168.0.111.evil:3000',broadcasts={}}
            assert(#targets == 1 and targets[1] == '255.255.255.255')
            local freed=0
            local wlan={ifa_name='wlan0',ifa_flags=3,ifa_addr={sa_family=2,host='192.168.5.10'},ifa_netmask={host='255.255.255.0'}}
            local virtual={ifa_name='tun0',ifa_flags=3,ifa_addr={sa_family=2,host='10.10.0.1'},ifa_netmask={host='255.255.255.0'}}
            wlan.ifa_next=virtual
            local ffi={os='Linux',C={AF_INET=2,NI_MAXHOST=1025,NI_NUMERICHOST=1}}
            function ffi.new() return {} end
            function ffi.string(value) return type(value) == 'table' and value.text or value end
            function ffi.sizeof() return 16 end
            function ffi.C.getifaddrs(holder) holder[0]=wlan; return 0 end
            function ffi.C.getnameinfo(addr,_,out) out.text=addr.host; return 0 end
            function ffi.C.freeifaddrs() freed=freed+1 end
            package.loaded.ffi=ffi
            package.preload['ffi/posix_h']=function() return true end
            targets=discovery.interfaceBroadcasts('wlan0')
            assert(#targets == 1 and targets[1] == '192.168.5.255' and freed == 1)
            ffi.C.getnameinfo=function() error('unsupported') end
            targets=discovery.interfaceBroadcasts('wlan0')
            assert(#targets == 0 and freed == 2)
        ''')

    def test_discovery_one_failed_route_does_not_abort_other_targets(self):
        self.discovery_runtime()
        self.lua.execute('''
            local json=require('json')
            local now,closed,packet=0,false,nil
            local udp={}
            function udp:setsockname() return 1 end
            function udp:setoption() return 1 end
            function udp:settimeout() return 1 end
            function udp:sendto(data,ip)
                if ip == '255.255.255.255' then return nil,'network unreachable' end
                local request=json.decode(data)
                packet=json.encode{type='pluginsync-server',service='koreader-plugin-sync',apiVersion=1,
                    nonce=request.nonce,port=3000,name='PC'}
                return 1
            end
            function udp:receivefrom()
                now=now+0.2
                if packet then local data=packet; packet=nil; return data,'192.168.0.111' end
                return nil,'timeout'
            end
            function udp:close() closed=true end
            package.preload.socket=function() return {udp4=function() return udp end,gettime=function() return now end} end
            local discovery=dofile('discovery.lua')
            local found,stats=discovery.search(nil,{knownAddress='http://192.168.0.111:3000',
                broadcasts={'192.168.0.255'},duration=2})
            assert(#found == 1 and closed and stats.sent > 0 and stats.received > 0)
            assert(stats.errors['255.255.255.255'] == 'network unreachable')
            assert(#stats.targets == 3)
        ''')

    def test_http_discovery_subnet_bounds(self):
        self.discovery_runtime()
        self.lua.execute('''
            package.preload.socket=function() return {} end
            local lan,discovery=dofile('lanhttp.lua'),dofile('discovery.lua')
            local hosts=lan.hosts(discovery,{{ip='192.168.0.20',mask='255.255.255.0'}})
            assert(#hosts == 253 and hosts[1] == '192.168.0.1' and hosts[#hosts] == '192.168.0.254')
            for _,ip in ipairs(hosts) do assert(ip ~= '192.168.0.20') end
            hosts=lan.hosts(discovery,{{ip='192.168.0.140',mask='255.255.255.128'}})
            assert(#hosts == 125 and hosts[1] == '192.168.0.129' and hosts[#hosts] == '192.168.0.254')
            hosts=lan.hosts(discovery,{{ip='10.20.30.40',mask='255.255.0.0'}})
            assert(#hosts == 253 and hosts[1] == '10.20.30.1' and hosts[#hosts] == '10.20.30.254')
        ''')

    def test_http_fallback_identity_no_token_and_socket_cleanup(self):
        self.discovery_runtime()
        self.lua.execute('''
            local now,sockets,active,max_active=0,{},0,0
            local socket={gettime=function() return now end}
            function socket.tcp()
                local tcp={}; sockets[#sockets+1]=tcp; active=active+1; max_active=math.max(max_active,active)
                function tcp:settimeout(value) assert(value == 0); return 1 end
                function tcp:connect(ip,port) self.ip=ip; self.port=port; return nil,'timeout' end
                function tcp:getpeername()
                    if self.ip == '192.168.0.2' or self.ip == '192.168.0.3' then return self.ip,self.port end
                end
                function tcp:close() if not self.closed then self.closed=true; active=active-1 end; return 1 end
                return tcp
            end
            function socket.select(_,peers) now=now+0.04; return {},peers end
            package.preload.socket=function() return socket end
            local lan,discovery=dofile('lanhttp.lua'),dofile('discovery.lua')
            local queries=0
            local api={request=function(url,token,path,filename,progress,options)
                assert(token == nil and path == '/api/discovery' and options.max_bytes == 4096)
                queries=queries+1
                if url == 'http://192.168.0.3:3000' then return {service='other',apiVersion=1,discoveryVersion=1} end
                return {service='koreader-plugin-sync',apiVersion=1,discoveryVersion=1,name='My PC',authRequired=true}
            end}
            local found,stats=lan.search(discovery,api,nil,{interfaces={{ip='192.168.0.20',mask='255.255.255.0'}}})
            assert(#found == 1 and found[1].address == 'http://192.168.0.2:3000' and found[1].authRequired)
            assert(stats.open == 2 and stats.verified == 1 and queries == 2 and active == 0 and max_active <= 24)
            for _,tcp in ipairs(sockets) do assert(tcp.closed) end
            -- Even a progress error must close every pending descriptor.
            local ok=pcall(lan.search,discovery,api,function() error('UI failure') end,
                {interfaces={{ip='192.168.0.20',mask='255.255.255.0'}}})
            assert(not ok and active == 0)
        ''')

    def test_http_fallback_real_nonblocking_sockets(self):
        requests=[]

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append((self.path,self.headers.get('Authorization')))
                body=json.dumps({'service':'koreader-plugin-sync','apiVersion':1,
                                 'discoveryVersion':1,'name':'Local PC','authRequired':True}).encode()
                self.send_response(200)
                self.send_header('Content-Length',str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self,*args):
                pass

        server=ThreadingHTTPServer(('127.0.0.2',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True)
        thread.start()
        lua=self.lua
        self.discovery_runtime()
        handles=[]

        def tcp():
            sock=pysocket.socket(pysocket.AF_INET,pysocket.SOCK_STREAM)
            handles.append(sock)
            table=lua.table()
            table.py_socket=sock

            def settimeout(_,value):
                sock.setblocking(False)
                return True

            def connect(_,ip,port):
                result=sock.connect_ex((ip,int(port)))
                if result == 0:
                    return True
                if result in (errno.EINPROGRESS,errno.EWOULDBLOCK,errno.EALREADY,10035,10036):
                    return None,'timeout'
                return None,'refused'

            def getpeername(_):
                try:
                    return sock.getpeername()
                except OSError:
                    return None

            table.settimeout=settimeout
            table.connect=connect
            table.getpeername=getpeername
            table.close=lambda _: sock.close()
            return table

        def select(_,peers,timeout):
            tables=list(peers.values())
            writable=pyselect.select([], [t.py_socket for t in tables],[],timeout)[1]
            return lua.table(),lua.table_from([t for t in tables if t.py_socket in writable])

        def request(url,token,path,*args):
            self.assertIsNone(token)
            connection=http.client.HTTPConnection(url.removeprefix('http://'),timeout=0.7)
            try:
                connection.request('GET',path)
                response=connection.getresponse()
                if response.status != 200:
                    raise ValueError(response.status)
                return lua.table_from(json.loads(response.read()))
            finally:
                connection.close()

        g=lua.globals()
        g.py_tcp=tcp
        g.py_select=select
        g.py_time=time.monotonic
        g.py_request=request
        g.fixture_port=server.server_port
        try:
            lua.execute('''
                package.preload.socket=function() return {tcp=function() return py_tcp() end,
                    select=py_select,gettime=py_time} end
                local lan,discovery=dofile('lanhttp.lua'),dofile('discovery.lua')
                local found=lan.search(discovery,{request=py_request},nil,{
                    interfaces={{ip='127.0.0.1',mask='255.255.255.252'}},
                    knownAddress='http://127.0.0.2:' .. fixture_port})
                assert(#found == 1 and found[1].address == 'http://127.0.0.2:' .. fixture_port)
            ''')
            self.assertEqual(requests,[('/api/discovery',None)])
            self.assertTrue(all(sock.fileno() == -1 for sock in handles))
        finally:
            for sock in handles:
                sock.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_discovery_broadcast_retry_dedup_deadline_and_cleanup(self):
        self.discovery_runtime()
        self.lua.execute('''
            local json=require('json')
            local now,sent,closed=0,0,false
            local packets={}
            local udp={}
            function udp:setsockname(host,port) assert(host == '*' and port == 0); self.bound=true; return 1 end
            function udp:setoption(name,value) assert(self.bound and name == 'broadcast' and value); return 1 end
            function udp:settimeout(value) assert(value > 0 and value < 1); return 1 end
            function udp:sendto(data,ip,port)
                assert(ip == '255.255.255.255' and port == 3001)
                local request=json.decode(data)
                assert(request.type == 'pluginsync-discover' and request.token == nil)
                sent=sent+1
                local response=json.encode{type='pluginsync-server',service='koreader-plugin-sync',apiVersion=1,
                    nonce=request.nonce,port=3000,name='PC'}
                packets[#packets+1]={'garbage','192.168.0.1'}
                packets[#packets+1]={response,'192.168.0.2'}
                packets[#packets+1]={response,'192.168.0.2'}
                packets[#packets+1]={response,'192.168.0.3'}
                return 1
            end
            function udp:receivefrom() now=now+0.2; local item=table.remove(packets,1); if item then return unpack(item) end; return nil,'timeout' end
            function udp:close() closed=true end
            package.preload.socket=function() return {udp4=function() return udp end,gettime=function() return now end} end
            local discovery=dofile('discovery.lua')
            local progress_count=0
            local found=discovery.search(function(elapsed,total,count)
                assert(elapsed <= total and count <= 2); progress_count=progress_count+1
            end)
            assert(#found == 2 and sent >= 2 and closed and now <= 4.3 and progress_count > 0)
            assert(found[1].address == 'http://192.168.0.2:3000')
            udp.sendto=function() return nil,'permission denied' end
            closed=false
            assert(not pcall(discovery.search))
            assert(closed)
        ''')

    def test_install_progress_and_filename_on_failure(self):
        files=self.extract(self.make_zip())
        target=(self.base/'target').as_posix()
        self.lua.globals().pending=self.lua.table_from({'files':files,'stage':(self.base/'stage').as_posix(),'target':target})
        self.lua.globals().test_fs=self.fs
        self.lua.execute('''
            local installer=dofile('installer.lua')
            local counts,chunk_updates={},0
            installer.install(pending,test_fs,function(current,total,name,bytes)
                assert(total == 3 and name and bytes >= 0)
                counts[#counts+1]=current; chunk_updates=chunk_updates+1
            end)
            assert(counts[#counts] == 3 and chunk_updates >= 6)
            local copies=0
            local broken=setmetatable({copy=function(...)
                copies=copies+1
                if copies == 2 then error('No space left on device') end
                return test_fs.copy(...)
            end},{__index=test_fs})
            local ok,err=pcall(installer.install,pending,broken)
            assert(not ok and err:find('main.lua',1,true) and err:find('No space',1,true))
        ''')

    def test_extract_and_overlay(self):
        files = self.extract(self.make_zip())
        target = self.base / 'installed/demo.koplugin'
        target.mkdir(parents=True)
        (target / 'main.lua').write_text('old')
        (target / 'private.txt').write_text('keep')
        pending = self.lua.table_from({'files':files,'stage':(self.base/'stage').as_posix(),'target':target.as_posix()})
        self.installer.install(pending,self.fs)
        self.assertEqual((target/'main.lua').read_text(),'return {new=true}')
        self.assertEqual((target/'private.txt').read_text(),'keep')
        self.assertEqual((target/'sub/new.txt').read_text(),'new')

    def test_malicious_or_broken_archives(self):
        cases = [
            {'demo.koplugin/../../escape': b'bad'},
            {'/demo.koplugin/main.lua': b'bad'},
            {'other.koplugin/main.lua': b'bad'},
            {'demo.koplugin/a\\evil': b'bad'},
            {'demo.koplugin/a:evil': b'bad'},
            {'demo.koplugin/main.lua': b'missing meta'},
        ]
        for entries in cases:
            with self.assertRaises(Exception):
                self.extract(self.make_zip(entries))
        with self.assertRaises(Exception):
            self.extract(self.make_zip(compression=zipfile.ZIP_DEFLATED))
        filename = Path(self.make_zip())
        data = filename.read_bytes().replace(b'return {new=true}',b'return {new=fals}',1)
        filename.write_bytes(data)
        with self.assertRaisesRegex(Exception,'CRC'):
            self.extract(filename.as_posix())
        filename.write_bytes(data[:40])
        with self.assertRaises(Exception):
            self.extract(filename.as_posix())

    def test_protected_ids_and_target_conflict(self):
        for name in ['kosync.koplugin','../evil.koplugin']:
            with self.assertRaises(Exception):
                self.installer.check(name,self.fs,'mine.koplugin')
        self.installer.check('demo.koplugin',self.fs,'mine.koplugin')
        self.installer.check('pluginsync.koplugin',self.fs,'pluginsync.koplugin')
        self.installer.check('pluginSync.koplugin',self.fs,'pluginsync.koplugin')
        files = self.extract(self.make_zip())
        target = self.base / 'target'
        target.mkdir()
        (target/'main.lua').write_text('old')
        (target/'_meta.lua').mkdir()
        pending=self.lua.table_from({'files':files,'stage':(self.base/'stage').as_posix(),'target':target.as_posix()})
        with self.assertRaises(Exception):
            self.installer.install(pending,self.fs)
        self.assertEqual((target/'main.lua').read_text(),'old')

    def test_node_zip_interoperability(self):
        filename=(self.base/'node.zip').as_posix()
        fixture=ROOT/'.research/node-fixture.zip'
        self.assertTrue(fixture.exists(), 'Run node tests/make-fixture.mjs first')
        shutil.copyfile(fixture,filename)
        self.extract(filename)
        # Windows LuaJIT uses narrow fopen; read back with the same Lua API.
        value=self.lua.execute('local f=assert(io.open(...,"rb")); local s=f:read("*a"); f:close(); return s',
                               (self.base/'stage/中文.txt').as_posix())
        self.assertEqual(value,'你好')
        with zipfile.ZipFile(filename) as z:
            self.assertIsNone(z.testzip())

    def test_ui_download_confirm_install_cancel_and_retry(self):
        package=self.make_zip()
        root=(self.base/'installed').as_posix()
        self.fs.mkdir(root)
        lua=self.lua
        lua.globals().test_root=root
        lua.globals().test_temp=(self.base/'download').as_posix()
        lua.globals().fixture_zip=package
        lua.execute('''
            UI={shown={},restarts=0}
            function UI:show(widget) self.shown[#self.shown+1]=widget; self.last=widget end
            function UI:close(widget) widget.closed=true end
            function UI:nextTick(fn) fn() end
            function UI:forceRePaint() end
            function UI:askForRestart() self.restarts=self.restarts+1 end
            local Widget={}
            function Widget:extend(t) return setmetatable(t,{__index=self}) end
            function Widget:new(t) return setmetatable(t or {},{__index=self}) end
            function Widget:onMenuChoice(item) if item.callback then item.callback() end end
            function Widget:onShowKeyboard() end
            function Widget:getInputText() return self.input end
            function Widget:switchItemTable(title,items) self.title=title; self.item_table=items end
            function Widget:reportProgress(value) self.progress_value=value end
            for _,name in ipairs{'ui/widget/container/widgetcontainer','ui/widget/infomessage',
                'ui/widget/confirmbox','ui/widget/inputdialog','ui/widget/menu',
                'ui/widget/buttondialog','ui/widget/progressbardialog'} do
                package.preload[name]=function() return Widget end
            end
            package.preload['ui/uimanager']=function() return UI end
            package.preload['ui/network/manager']=function() return {runWhenConnected=function(_,fn) fn() end} end
            package.preload.datastorage=function() return {getDataDir=function() return '.' end,getSettingsDir=function() return '.' end} end
            local settings={data={}}
            function settings:readSetting(key,default) return self.data[key] or default end
            function settings:saveSetting(key,value) self.data[key]=value end
            function settings:flush() end
            package.preload.luasettings=function() return {open=function() return settings end} end
            package.preload.json=function() return {} end
            package.preload['socket.http']=function() return {} end
            package.preload.socketutil=function() return {} end
            local clock=0
            package.preload.socket=function() return {gettime=function() clock=clock+1; return clock end} end
            G_reader_settings=settings
            local Plugin=dofile('main.lua')
            client=Plugin:new{path='.',ui={menu={registerToMainMenu=function() end}}}
            client:init()
            local menu_items={}
            client:addToMainMenu(menu_items)
            menu_items.pluginsync.callback()
            local home=client.home_menu
            assert(home and home.item_table[1].text == '当前版本：' .. dofile('_meta.lua').version)
            assert(home.item_table[1].enabled == false)
            assert(#home.item_table == 7) -- no pending install after startup
            home:onMenuSelect(home.item_table[2])
            local dialog=UI.last
            dialog.input='http://192.168.1.100:3000'
            dialog.buttons[1][2].callback()
            assert(dialog.closed and not home.closed and client.home_menu == home)
            assert(client.settings:readSetting('server') == dialog.input)
            assert(home.item_table[2].text:find('192.168.1.100:3000',1,true))
            local real_probe,real_search=client.probeServer,client.discovery.search
            client.probeServer=function() return true end
            client.discovery.search=function() error('must not broadcast when saved address works') end
            home:onMenuSelect(home.item_table[3])
            assert(UI.last.title == '上次服务器可用（点击使用）')
            local discovered=client.discovery_menu
            discovered:onMenuSelect(discovered.item_table[1])
            assert(client.settings:readSetting('server') == 'http://192.168.1.100:3000' and discovered.closed)
            client.probeServer=function(_,address)
                if address == 'http://192.168.1.100:3000' then error('timeout') end
                return true
            end
            client.discovery.search=function() return {{name='New PC',address='http://192.168.1.20:4000'}} end
            client:searchServers()
            discovered=client.discovery_menu
            assert(discovered.item_table[1].text:find('New PC',1,true))
            discovered:onMenuSelect(discovered.item_table[1])
            assert(client.settings:readSetting('server') == 'http://192.168.1.20:4000')
            client.discovery.search=function() return {{name='Locked PC',address='http://192.168.1.30:3000',authRequired=true}} end
            client.probeServer=function() error('请求失败: 401') end
            client:searchServers(true)
            discovered=client.discovery_menu
            discovered:onMenuSelect(discovered.item_table[1])
            assert(UI.last.ok_text == '保存并设置 Token')
            assert(client.settings:readSetting('server') == 'http://192.168.1.20:4000')
            UI.last.ok_callback()
            assert(client.settings:readSetting('server') == 'http://192.168.1.30:3000')
            dialog=UI.last; dialog.input='new-token'; dialog.buttons[1][2].callback()
            assert(client.settings:readSetting('token') == 'new-token')
            client.discovery.search=function() return {} end
            client:searchServers(true)
            assert(UI.last.text:find('未发现服务器',1,true) and not home.closed)
            local real_http_search=client.lanhttp.search
            client.lanhttp.search=function(discovery,api,progress,options)
                assert(options.knownAddress == 'http://192.168.1.30:3000')
                return {{name='HTTP PC',address='http://192.168.1.40:3000'}},{tested=10,open=1,verified=1}
            end
            client:searchServers(true)
            assert(client.discovery_menu.item_table[1].text:find('HTTP PC',1,true))
            client.discovery.search=function() error('UDP not supported') end
            client:searchServers(true)
            assert(client.discovery_menu.item_table[1].text:find('HTTP PC',1,true))
            client.lanhttp.search=real_http_search
            client.probeServer=real_probe; client.discovery.search=real_search
            home:onMenuSelect(home.item_table[2])
            dialog=UI.last; dialog.buttons[1][1].callback()
            assert(dialog.closed and not home.closed)
            local saved_request=client.request
            client.request=function() return {ok=true,service='koreader-plugin-sync'} end
            home:onMenuSelect(home.item_table[5])
            assert(UI.last.text == '连接成功。' and not home.closed)
            UI:close(UI.last)
            client.request=function() error('simulated timeout') end
            home:onMenuSelect(home.item_table[5])
            assert(UI.last.text:find('simulated timeout') and not home.closed)
            client.request=saved_request
            client.temp=test_temp; client.default_root=test_root
            function client:roots() return {test_root} end
            function client:request(path,filename,progress)
                if path == '/api/plugins' then return {plugins=self.plugins,apiVersion=1} end
                self.fsutil.copy(fixture_zip,filename)
                if progress then progress(1024); progress(2048,2048) end
                return '1.1.0'
            end
            client.plugins={{id='demo.koplugin',name='测试插件',version='1.1.0'}}
            client:showList()
            local list=client.list_menu
            assert(list.multilines_forced and list.single_line == false and list.items_per_page == 4)
            assert(list.title == '需要更新 · 0/1 项')
            assert(list.item_table[2].select_enabled == false)
            list:onMenuSelect(list.item_table[1])
            UI.last.buttons[2][2].callback() -- all plugins, no network request
            list=client.list_menu
            assert(list.title == '全部 · 1/1 项')
            list:onMenuSelect(list.item_table[1])
            UI.last.buttons[1][1].callback() -- refresh from inside list
            list=client.list_menu
            assert(client.filter == 'all' and list.title == '全部 · 1/1 项')
            list:onMenuSelect(list.item_table[1])
            UI.last.buttons[4][2].callback()
            assert(client.sort == 'name_desc')
            client:fetch(true)
            assert(client.filter == 'updates' and client.sort == 'priority')
            assert(client.list_menu.title == '需要更新 · 0/1 项')
            client.filter='all'; client:showList(); list=client.list_menu
            local one_plugin=client.plugins
            for i=1,9 do client.plugins[#client.plugins+1]={id='extra-' .. i .. '.koplugin',name='Extra ' .. i} end
            client:showList(); list=client.list_menu
            list.page=2; list.itemnumber=6
            list:onMenuSelect(list.item_table[6])
            client:showList()
            assert(client.list_menu == list and not list.closed and list.page == 2 and list.itemnumber == 6)
            list.onLeftButtonTap()
            UI.last.buttons[1][1].callback() -- refresh without returning to page one
            assert(client.list_menu == list and list.page == 2 and list.itemnumber == 6)
            client.plugins={one_plugin[1]}; client:showList()
            assert(client.list_menu == list and list.page == 1)
            local entry=list.item_table[2]
            local displayed=entry.bidi_wrap_func(entry.text:gsub('\\n',' '))
            assert(displayed == '测试插件\\n状态：未安装\\n本机版本：未安装\\nPC 版本：1.1.0')
            assert(entry.mandatory == '下载')
            list:onMenuSelect(entry)
            assert(UI.last.ok_text == '下载' and not list.closed)
            list.close_callback()
            client:download{id='demo.koplugin',version='1.0.0'}
            assert(client.pending and client.pending.version == '1.1.0')
            assert(not require('libs/libkoreader-lfs').attributes(test_root .. '/demo.koplugin'))
            assert(UI.last.ok_text == '安装' and UI.restarts == 0)
            assert(#home.item_table == 8)
            home:onMenuSelect(home.item_table[8])
            assert(UI.last.ok_text == '安装')
            UI.last.cancel_callback()
            assert(not client.pending and not require('libs/libkoreader-lfs').attributes(test_temp))
            assert(#home.item_table == 7)
            client:download{id='demo.koplugin'}
            assert(UI.last.text:find('空间预估',1,true))
            local normal_space=client.fsutil.availableSpace
            client.fsutil.availableSpace=function() return 0 end
            UI.last.ok_callback() -- recheck even if confirmation originally had space
            assert(client.pending and UI.restarts == 0 and UI.last.text:find('空间不足',1,true))
            assert(not require('libs/libkoreader-lfs').attributes(test_root .. '/demo.koplugin'))
            client.fsutil.availableSpace=normal_space
            client:confirmInstall()
            local original=client.installer.install
            client.installer.install=function() error('simulated write failure') end
            UI.last.ok_callback()
            assert(client.pending and UI.restarts == 0 and UI.last.text:find('simulated write failure'))
            assert(#home.item_table == 8)
            assert(client.settings:readSetting('history')[1].result == '失败')
            client.installer.install=original
            home:onMenuSelect(home.item_table[8]); UI.last.ok_callback()
            assert(not client.pending and UI.restarts == 1)
            assert(#home.item_table == 7)
            assert(client.settings:readSetting('history')[1].result == '成功')
            local records=client.settings:readSetting('installed')
            records['demo.koplugin'].version='0.5.0'
            local _,_,local_version,source=client:localInfo{id='demo.koplugin'}
            assert(local_version == '1.1.0' and source == 'metadata')
            client.fsutil.write(test_root .. '/demo.koplugin/_meta.lua','return {version="1.2.0"}')
            _,_,local_version,source=client:localInfo{id='demo.koplugin'}
            assert(local_version == '1.2.0' and source == 'metadata')
            client.fsutil.write(test_root .. '/demo.koplugin/_meta.lua','return {}')
            _,_,local_version,source=client:localInfo{id='demo.koplugin'}
            assert(local_version == '0.5.0' and source == 'record')
            client.fsutil.write(test_root .. '/demo.koplugin/_meta.lua','return {version="1.1.0"}')
            records['demo.koplugin'].version='1.1.0'
            client:showHistory()
            assert(UI.last.item_table[1].text:find('安装成功',1,true))
            local saw_download,saw_install=false,false
            for _,widget in ipairs(UI.shown) do
                if widget.title == '下载插件' then saw_download=true end
                if widget.title == '安装插件' and widget.progress_value then saw_install=true end
            end
            assert(saw_download and saw_install)
            local working_request=client.request
            client.request=function() error('connection timeout') end
            client:showList()
            local retained_list=client.list_menu
            client:fetch()
            assert(client.list_menu == retained_list and not retained_list.closed)
            client:download{id='demo.koplugin',version='1.1.0'}
            assert(not client.pending and client.settings:readSetting('history')[1].operation == '下载')
            assert(client.settings:readSetting('history')[1].result == '失败')
            assert(not require('libs/libkoreader-lfs').attributes(test_temp))
            assert(UI.last.text:find('超时',1,true))
            client.request=working_request
            client.settings:saveSetting('token','s[e]cret')
            assert(client:recordResult({id='demo.koplugin'},'失败','hidden s[e]cret','下载'))
            assert(not client.settings:readSetting('history')[1].detail:find('s[e]cret',1,true))
            assert(not require('libs/libkoreader-lfs').attributes(test_temp))
            -- Self update must target the running directory, then block more work.
            client.self_id='demo.koplugin'; client.path=test_root .. '/demo.koplugin'
            assert(client:targetFor('pluginSync.koplugin') == client.path)
            assert(client:targetFor('pluginsync.koplugin') == client.path)
            client:download{id='demo.koplugin'}
            assert(client.pending.is_self and UI.last.text:find('自更新'))
            UI.last.ok_callback()
            assert(client.restart_required and not client.pending and UI.restarts == 2)
            assert(#home.item_table == 7)
            client:download{id='demo.koplugin'}
            assert(not client.pending and UI.restarts == 3)
            local ran=false
            client:busyWork('blocked',function() ran=true end,function() end)
            assert(not ran and UI.restarts == 4)
            -- A post-copy settings failure must still require restart.
            client.restart_required=false
            client:download{id='demo.koplugin'}
            client.settings.flush=function() error('simulated settings failure') end
            UI.last.ok_callback()
            assert(client.restart_required and UI.restarts == 5)
            assert(#home.item_table == 7) -- copied self-update cannot be retried
        ''')
        self.assertEqual((Path(root)/'demo.koplugin/main.lua').read_text(),'return {new=true}')

    def test_http_validation_timeouts_and_failures(self):
        self.lua.globals().download_file=(self.base/'download.zip').as_posix()
        self.lua.execute('''
            response_code=200; response_body='abc'; response_length='3'
            request_throws=false; now=0
            local http={request=function(req)
                assert(req.redirect == false and req.headers.Authorization == 'Bearer secret')
                if request_throws then error('connection reset') end
                local ok,err=req.sink(response_body)
                if not ok then return nil,err end
                req.sink(nil)
                return 1,response_code,{['content-length']=response_length,['x-plugin-version']='v1%2Bbuild'}
            end}
            reset_count=0
            package.preload['socket.http']=function() return http end
            package.preload.socketutil=function() return {
                set_timeout=function() end,reset_timeout=function() reset_count=reset_count+1 end} end
            package.preload.socket=function() return {gettime=function() return now end} end
            package.preload.json=function() return {decode=function() return {apiVersion=1} end} end
            local api=dofile('api.lua')
            assert(api.base(' http://192.168.1.2:3000/ ') == 'http://192.168.1.2:3000')
            assert(not pcall(api.base,'http://host/path'))
            assert(not pcall(api.request,'http://host','','//evil/download',download_file))
            local updates={}
            assert(api.request('http://host','secret','/api/plugins/demo.koplugin/download',download_file,function(bytes,total)
                updates[#updates+1]={bytes=bytes,total=total}
            end) == 'v1+build')
            assert(#updates == 2 and updates[1].bytes == 3 and updates[1].total == nil)
            assert(updates[2].total == 3)
            response_length='4'
            assert(not pcall(api.request,'http://host','secret','/api/plugins/demo.koplugin/download',download_file))
            response_length='3'; response_code=302
            assert(not pcall(api.request,'http://host','secret','/api/plugins/demo.koplugin/download',download_file))
            request_throws=true
            assert(not pcall(api.request,'http://host','secret','/api/plugins',nil))
            assert(reset_count == 4)
        ''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
