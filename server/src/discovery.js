import dgram from 'node:dgram';
import os from 'node:os';

export const DISCOVERY_PORT = 3001;
export function createDiscoveryResponder({ httpPort, name = os.hostname(), authRequired = false }) {
  const socket = dgram.createSocket('udp4');
  socket.on('message', (message, remote) => {
    if (message.length > 512) return;
    let request;
    try { request = JSON.parse(message.toString('utf8')); } catch { return; }
    if (!request || request.type !== 'pluginsync-discover' || request.apiVersion !== 1
        || typeof request.nonce !== 'string' || !/^[A-Za-z0-9._-]{8,64}$/.test(request.nonce)) return;
    const reply = Buffer.from(JSON.stringify({
      type: 'pluginsync-server', service: 'koreader-plugin-sync', apiVersion: 1,
      nonce: request.nonce, name: String(name).replace(/[\x00-\x1f\x7f]/g, '').slice(0, 80),
      port: httpPort, authRequired: Boolean(authRequired),
    }));
    socket.send(reply, remote.port, remote.address, () => {});
  });
  return socket;
}

export function attachDiscovery(server, config, log = console, port = DISCOVERY_PORT) {
  if (config.discovery === false) return null;
  let discovery;
  server.once('listening', () => {
    const address = server.address();
    // Discovery is IPv4. Honor an explicitly bound HTTP address.
    if (!address || typeof address === 'string' || address.family !== 'IPv4') {
      log.warn('UDP discovery skipped: HTTP must listen on IPv4.');
      return;
    }
    discovery = createDiscoveryResponder({ httpPort: address.port,
      name: config.discoveryName || os.hostname(), authRequired: Boolean(config.token) });
    discovery.on('error', error => {
      log.warn(`UDP discovery unavailable (${error.code || error.message}); HTTP still works. Allow UDP ${DISCOVERY_PORT} or check port conflicts.`);
      try { discovery.close(); } catch { /* already closed */ }
    });
    discovery.bind(port, address.address, () => log.log(`PluginSync discovery on UDP ${discovery.address().port}`));
  });
  server.once('close', () => { if (discovery) { try { discovery.close(); } catch { /* not running */ } } });
  return () => discovery;
}
