import { test } from 'node:test';
import assert from 'node:assert/strict';
import dgram from 'node:dgram';
import { once } from 'node:events';
import { createDiscoveryResponder, attachDiscovery } from '../src/discovery.js';
import { createServer } from '../src/server.js';

async function bind(socket) {
  socket.bind(0, '127.0.0.1');
  await once(socket, 'listening');
  return socket.address().port;
}
async function ready(socket) {
  try { if (socket.address().port) return; } catch { /* binding */ }
  await once(socket,'listening');
}
async function query(port, request) {
  const socket = dgram.createSocket('udp4');
  try {
    const response = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('discovery timeout')), 1000);
      socket.once('message', (message, remote) => { clearTimeout(timer); resolve({ message: JSON.parse(message), remote }); });
      socket.once('error', error => { clearTimeout(timer); reject(error); });
    });
    socket.send(JSON.stringify(request), port, '127.0.0.1');
    return await response;
  } finally { socket.close(); }
}

test('UDP protocol, invalid packets, custom HTTP port, and no credential disclosure', async t => {
  const responder=createDiscoveryResponder({httpPort:4567,name:'My PC\n',authRequired:true});
  t.after(()=>responder.close());
  const port=await bind(responder);
  const client=dgram.createSocket('udp4');
  await bind(client); t.after(()=>client.close());
  const replies=[];
  client.on('message', message=>replies.push(JSON.parse(message)));
  for (const data of ['not json','null','[]',JSON.stringify({type:'pluginsync-discover',apiVersion:2,nonce:'valid-nonce'}),
    JSON.stringify({type:'pluginsync-discover',apiVersion:1,nonce:'bad'}),'x'.repeat(513)])
    client.send(data,port,'127.0.0.1');
  const request={type:'pluginsync-discover',apiVersion:1,nonce:'request-123456'};
  client.send(JSON.stringify(request),port,'127.0.0.1');
  await new Promise(resolve=>setTimeout(resolve,100));
  assert.equal(replies.length,1);
  assert.equal(replies[0].nonce,request.nonce);
  assert.equal(replies[0].port,4567); assert.equal(replies[0].name,'My PC');
  assert.equal(replies[0].authRequired,true);
  assert.deepEqual(Object.keys(replies[0]).sort(),['type','service','apiVersion','nonce','name','port','authRequired'].sort());
});

test('discovery follows HTTP startup/shutdown and advertises real HTTP port', async t => {
  const server=createServer({token:'secret'});
  const logs={log() {},warn() {}};
  const getDiscovery=attachDiscovery(server,{},logs,0);
  server.listen(0,'127.0.0.1'); await once(server,'listening');
  const discovery=getDiscovery(); await ready(discovery);
  t.after(()=>{if (server.listening) server.close();});
  const reply=await query(discovery.address().port,{type:'pluginsync-discover',apiVersion:1,nonce:'lifecycle-1234'});
  assert.equal(reply.message.port,server.address().port);
  const closed=once(discovery,'close');
  await new Promise(resolve=>server.close(resolve)); await closed;
  assert.equal(attachDiscovery(createServer({}),{discovery:false}),null);
});

test('UDP bind conflict leaves HTTP service available', async t => {
  const occupied=dgram.createSocket('udp4'); const port=await bind(occupied);
  t.after(()=>occupied.close());
  let report;
  const warning=new Promise(resolve=>{report=resolve;});
  const server=createServer({});
  attachDiscovery(server,{}, {log() {},warn:report},port);
  server.listen(0,'127.0.0.1'); await once(server,'listening');
  t.after(()=>new Promise(resolve=>server.close(resolve)));
  assert.match(await warning,/HTTP still works/);
  assert.equal((await (await fetch(`http://127.0.0.1:${server.address().port}/api/health`)).json()).ok,true);
});
