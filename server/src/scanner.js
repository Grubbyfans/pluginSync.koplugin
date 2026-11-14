import fs from 'node:fs/promises';
import path from 'node:path';
import { zip } from './zip.js';

export function validId(id) {
  return typeof id === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]*\.koplugin$/.test(id) && !id.includes('..');
}
export function safePart(name) {
  return name && name !== '.' && name !== '..' && !/[\\/:\x00-\x1f]/.test(name);
}
async function readText(file) {
  try { return await fs.readFile(file, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return ''; throw e; }
}
export async function metadata(dir, id, versions = {}) {
  const text = await readText(path.join(dir, 'pluginsync.json'));
  const meta = text ? JSON.parse(text) : {};
  const lua = await readText(path.join(dir, '_meta.lua'));
  const version = meta.version ?? versions[id] ?? lua.match(/\bversion\s*=\s*["']([^"'\r\n]+)["']/)?.[1] ?? null;
  return { id, name: typeof meta.name === 'string' ? meta.name : id,
    version: typeof version === 'string' && version.trim() ? version.trim() : null };
}
export async function list(config) {
  const raw = await readText(path.join(config.pluginRoot, 'versions.json'));
  const versions = raw ? JSON.parse(raw) : {};
  const plugins = [], errors = [];
  for (const item of await fs.readdir(config.pluginRoot, { withFileTypes: true })) {
    if (!item.isDirectory() || item.isSymbolicLink() || !validId(item.name)) continue;
    try {
      plugins.push({ ...await metadata(path.join(config.pluginRoot, item.name), item.name, versions),
        downloadPath: `/api/plugins/${encodeURIComponent(item.name)}/download` });
    } catch (e) { errors.push({ id: item.name, error: e.message }); }
  }
  return { apiVersion: 1, plugins: plugins.sort((a, b) => a.id.localeCompare(b.id)), errors };
}
export async function packagePlugin(config, id) {
  if (!validId(id)) throw Object.assign(new Error('Invalid plugin ID'), { status: 400 });
  const root = path.resolve(config.pluginRoot), dir = path.join(root, id);
  const stat = await fs.lstat(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw Object.assign(new Error('Not a plugin directory'), { status: 400 });
  const realRoot = await fs.realpath(root);
  async function contained(file) {
    const relative = path.relative(realRoot, await fs.realpath(file));
    if (relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('Path outside plugin root');
  }
  const files = []; let bytes = 0;
  async function walk(current, relative) {
    await contained(current);
    for (const entry of await fs.readdir(current, { withFileTypes: true })) {
      if ((config.exclude ?? []).includes(entry.name) || entry.name.endsWith('.part')) continue;
      if (!safePart(entry.name)) throw new Error('Unsafe filename');
      const full = path.join(current, entry.name), rel = `${relative}/${entry.name}`;
      const before = await fs.lstat(full);
      if (before.isSymbolicLink()) continue;
      if (before.isDirectory()) { await walk(full, rel); continue; }
      if (!before.isFile()) continue;
      await contained(full);
      if (files.length >= config.maxFiles || bytes + before.size > config.maxBytes) throw new Error('Plugin exceeds limits');
      const handle = await fs.open(full, 'r');
      let data;
      try {
        const opened = await handle.stat();
        if (opened.ino !== before.ino || opened.dev !== before.dev) throw new Error('Source changed; retry download');
        data = await handle.readFile();
        const after = await handle.stat();
        if (after.size !== before.size || after.mtimeMs !== before.mtimeMs || data.length !== before.size)
          throw new Error('Source changed; retry download');
      } finally { await handle.close(); }
      bytes += data.length; files.push({ name: rel, data });
    }
  }
  await walk(dir, id);
  for (const required of ['main.lua', '_meta.lua'])
    if (!files.some(f => f.name === `${id}/${required}`)) throw new Error(`Missing ${required}`);
  // Capture version from the downloaded bytes, not from a potentially stale list.
  const get = name => files.find(f => f.name === `${id}/${name}`)?.data.toString('utf8');
  const json = get('pluginsync.json');
  const versionsRaw = await readText(path.join(root, 'versions.json'));
  const version = (json ? JSON.parse(json).version : null)
    ?? (versionsRaw ? JSON.parse(versionsRaw)[id] : null)
    ?? get('_meta.lua')?.match(/\bversion\s*=\s*["']([^"'\r\n]+)["']/)?.[1] ?? null;
  return { data: zip(files), version: typeof version === 'string' ? version : null };
}
