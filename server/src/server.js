import http from 'node:http';
import os from 'node:os';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { list, packagePlugin } from './scanner.js';
import { attachDiscovery } from './discovery.js';

export function createServer(config) {
  return http.createServer(async (req, res) => {
    const json = (code, value) => { res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(value)); };
    try {
      const url = new URL(req.url, 'http://localhost');
      if (req.method === 'GET' && url.pathname === '/api/discovery') {
        if (config.discovery === false) return json(404, { error: 'Discovery disabled' });
        return json(200, {
        service: 'koreader-plugin-sync', apiVersion: 1, discoveryVersion: 1,
        name: (config.discoveryName || os.hostname()).replace(/[\x00-\x1f\x7f]/g, '').slice(0,80),
        authRequired: Boolean(config.token),
        });
      }
      if (config.token && req.headers.authorization !== `Bearer ${config.token}`) return json(401, { error: 'Unauthorized' });
      if (req.method !== 'GET') return json(405, { error: 'GET only' });
      if (url.pathname === '/api/health') return json(200, { ok: true, service: 'koreader-plugin-sync', apiVersion: 1 });
      if (url.pathname === '/api/plugins') return json(200, await list(config));
      const match = url.pathname.match(/^\/api\/plugins\/([^/]+)\/download$/);
      if (!match) return json(404, { error: 'Not found' });
      const { data, version } = await packagePlugin(config, decodeURIComponent(match[1]));
      res.writeHead(200, { 'Content-Type': 'application/zip', 'Content-Length': data.length,
        'X-Plugin-Version': encodeURIComponent(version ?? ''), 'Cache-Control': 'no-store' });
      res.end(data);
    } catch (e) { json(e.status ?? (e.code === 'ENOENT' ? 404 : e instanceof URIError ? 400 : 500), { error: e.message }); }
  });
}
export async function loadConfig(filename) {
  const defaults = { host: '0.0.0.0', port: 3000, discovery: true, maxFiles: 5000, maxBytes: 50 * 1024 * 1024,
    exclude: ['.git', 'node_modules', '.DS_Store', 'Thumbs.db'] };
  const config = { ...defaults, ...JSON.parse(await fs.readFile(filename, 'utf8')) };
  if (typeof config.pluginRoot !== 'string' || !config.pluginRoot) throw new Error('pluginRoot is required');
  config.pluginRoot = path.resolve(path.dirname(filename), config.pluginRoot);
  if (!(await fs.stat(config.pluginRoot)).isDirectory()) throw new Error('pluginRoot must be a directory');
  for (const key of ['maxFiles', 'maxBytes'])
    if (!Number.isSafeInteger(config[key]) || config[key] < 1) throw new Error(`Invalid ${key}`);
  if (config.maxFiles > 5000 || config.maxBytes > 50 * 1024 * 1024) throw new Error('Limits exceed client support');
  if (!Array.isArray(config.exclude) || config.exclude.some(x => typeof x !== 'string')) throw new Error('exclude must be a string array');
  if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535) throw new Error('Invalid port');
  if (typeof config.discovery !== 'boolean') throw new Error('discovery must be true or false');
  if (config.discoveryName !== undefined && typeof config.discoveryName !== 'string') throw new Error('discoveryName must be a string');
  return config;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const filename = path.resolve(process.argv[2] ?? 'config.json');
  try {
    const config = await loadConfig(filename);
    const server = createServer(config);
    attachDiscovery(server, config);
    server.on('error', e => { console.error(e.message); process.exitCode = 1; });
    server.listen(config.port, config.host, () => console.log(`PluginSync listening on ${config.host}:${config.port}; source: ${config.pluginRoot}`));
  } catch (e) { console.error(e.message); process.exitCode = 1; }
}
