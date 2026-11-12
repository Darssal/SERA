'use strict';
// The v4 worker deletes sera-shell-* caches without a cross-worker lock.
// A different namespace keeps an installing v5 candidate out of its reach.
const CACHE = 'sera-runtime-v5';
const SHELL_LOCK = 'sera-runtime-shell';
const SHELL_KEY = 'active-shell';
const DB = 'sera-platform-state';
const SCOPE_KEY = 'active-scope';
const base = self.registration.scope;
const asset = path => new URL(path, base).href;
let warming = null;
const clientShells = new Map();
const hasShellLocks = typeof navigator !== 'undefined' && typeof navigator.locks?.request === 'function';
const withShellLock = operation => hasShellLocks
  ? navigator.locks.request(SHELL_LOCK, {mode: 'exclusive'}, operation)
  : operation();
function database() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB, 1);
    request.onupgradeneeded = () => request.result.createObjectStore('meta');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function read(key) {
  const db = await database();
  try {return await new Promise((resolve, reject) => {const req = db.transaction('meta').objectStore('meta').get(key);req.onsuccess = () => resolve(req.result);req.onerror = () => reject(req.error);});}
  finally {db.close();}
}
async function write(key, value) {
  const db = await database();
  try {await new Promise((resolve, reject) => {const tx = db.transaction('meta', 'readwrite');tx.objectStore('meta').put(value, key);tx.oncomplete = resolve;tx.onerror = () => reject(tx.error);});}
  finally {db.close();}
}
async function shellFor(clientId) {
  const name = clientId && (clientShells.get(clientId) || await read(`client-shell:${clientId}`));
  return name || (await read(SHELL_KEY))?.name || CACHE;
}
async function cleanupShells() {
  // Without origin-wide coordination retain complete versions conservatively.
  // Legacy workers do not participate in our lock, so leave their caches alone.
  if (!hasShellLocks) return;
  const keep = new Set([(await read(SHELL_KEY))?.name]);
  for (const client of await self.clients.matchAll({type: 'window', includeUncontrolled: true})) keep.add(await shellFor(client.id));
  for (const name of await caches.keys()) if (name.startsWith(`${CACHE}-`) && !keep.has(name)) await caches.delete(name);
}
async function verifiedResource(value, item) {
  if (!value?.ok || value.type === 'opaque') return false;
  const bytes = await value.clone().arrayBuffer();
  if (bytes.byteLength !== item.bytes) return false;
  const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(b => b.toString(16).padStart(2, '0')).join('');
  return digest === item.sha256;
}
async function prepareShellResources() {
  if (warming) return warming;
  warming = (async () => {
    const previous = await read(SHELL_KEY);
    let target;
    let committed = false;
    try {
      const response = await fetch(asset('sera-cache-manifest.json'), {cache: 'no-store', credentials: 'omit'});
      if (!response.ok) throw new Error('离线资源清单不可用，请完成 Web 发布构建后重试。');
      const manifest = await response.json();
      if (manifest.schemaVersion !== 1 || !/^[a-f0-9]{64}$/.test(manifest.version) || !Array.isArray(manifest.resources)) throw new Error('离线资源清单无效。');
      const names = new Set();
      for (const item of manifest.resources) {
        if (typeof item.path !== 'string' || item.path.startsWith('/') || item.path.split('/').includes('..') || !/^[a-f0-9]{64}$/.test(item.sha256) || !Number.isSafeInteger(item.bytes) || item.bytes < 0 || names.has(item.path)) throw new Error('离线资源路径或校验值无效。');
        const url = new URL(item.path, base);
        if (!url.href.startsWith(base) || url.origin !== new URL(base).origin || url.pathname.startsWith('/api/') || url.search || url.hash) throw new Error('离线清单包含非静态资源。');
        names.add(item.path);
      }
      for (const name of ['index.html', 'flutter_bootstrap.js', 'main.dart.js', 'sera-platform.js', 'assets/FontManifest.json', 'assets/AssetManifest.bin', 'canvaskit/canvaskit.js', 'canvaskit/canvaskit.wasm']) if (!names.has(name)) throw new Error('离线清单缺少核心运行文件。');
      if (previous?.version === manifest.version && previous.name?.startsWith(`${CACHE}-`)) {
        return {ready: true, name: previous.name, version: manifest.version, resources: manifest.resources.length,
          reusedResources: 0, reusedBytes: 0, downloadedResources: 0, downloadedBytes: 0};
      }
      // Each writer owns its candidate, including browsers without Web Locks.
      target = `${CACHE}-${manifest.version}-${crypto.getRandomValues(new Uint32Array(4)).join('-')}`;
      const cache = await caches.open(target);
      let reusedResources = 0, reusedBytes = 0, downloadedResources = 0, downloadedBytes = 0;
      if (previous?.name !== target) {
        const previousCache = previous?.name ? await caches.open(previous.name) : null;
        let next = 0;
        let failed = null;
        await Promise.all(Array.from({length: Math.min(6, manifest.resources.length)}, async () => {
          while (!failed && next < manifest.resources.length) {
            const item = manifest.resources[next++];
            const url = asset(item.path);
            try {
              let value = null;
              try {
                const cached = await previousCache?.match(url);
                if (await verifiedResource(cached, item)) value = cached;
              } catch (_) { /* An unavailable old resource can be downloaded. */ }
              const reused = value !== null;
              if (!reused) {
                value = await fetch(url, {cache: 'no-store', credentials: 'omit'});
                if (!value.ok || value.type === 'opaque') throw new Error('离线资源下载未完成，请联网后刷新重试。');
                if (!await verifiedResource(value, item)) throw new Error('发布文件校验不一致，继续保留完整旧版本，请稍后刷新。');
              }
              await cache.put(url, value);
              if (reused) {reusedResources++;reusedBytes += item.bytes;}
              else {downloadedResources++;downloadedBytes += item.bytes;}
            } catch (error) {failed ||= error;}
          }
        }));
        // All writers have settled before a failed candidate is removed.
        if (failed) throw failed;
        // The pointer is the commit: quota/network/hash failures leave the
        // previous complete shell active, never a partly downloaded upgrade.
        await write(SHELL_KEY, {name: target, version: manifest.version, resources: manifest.resources.length, at: Date.now()});
        committed = true;
      }
      return {ready: true, name: target, version: manifest.version, resources: manifest.resources.length,
        reusedResources, reusedBytes, downloadedResources, downloadedBytes};
    } catch (error) {
      if (target && !committed) await caches.delete(target).catch(() => {});
      await write('last-shell-error', {message: String(error.message || error), at: Date.now()});
      if (previous?.name && await (await caches.open(previous.name)).match(asset('flutter_bootstrap.js'))) return {ready: true, name: previous.name, version: previous.version, usingCached: true, warning: '离线资源更新暂未完成，正在使用完整缓存版本。'};
      throw error;
    }
  })().finally(() => {warming = null;});
  return warming;
}
async function prepareShell(clientId, cleanup = false) {
  return withShellLock(async () => {
    const shell = await prepareShellResources();
    if (clientId) {
      await write(`client-shell:${clientId}`, shell.name);
      clientShells.set(clientId, shell.name);
    }
    if (cleanup) await cleanupShells();
    return shell;
  });
}
self.addEventListener('install', event => {
  event.waitUntil((async () => {await prepareShell();await self.skipWaiting();})());
});
self.addEventListener('activate', event => {
  event.waitUntil(withShellLock(async () => {
    // Installation has already committed a complete shell. Keep any cache
    // bound to a live old tab until that tab navigates to the new version.
    await cleanupShells();
    await self.clients.claim();
  }));
});
self.addEventListener('message', event => {
  event.waitUntil((async () => {
    try {
      if (event.data?.type === 'prepare-shell') {
        const shell = await prepareShell(event.source?.id, true);
        event.ports[0]?.postMessage({ok: true, ...shell});return;
      } else if (event.data?.type === 'set-scope') {
        const scope = String(event.data.scope || 'signed-out');
        const previousScope = await read(SCOPE_KEY) || 'signed-out';
        await write(SCOPE_KEY, scope);
        for (const notification of await self.registration.getNotifications()) if (notification.data?.sera && notification.data.scope !== scope) notification.close();
        event.ports[0]?.postMessage({ok: true, previousScope});return;
      } else if (event.data?.type === 'get-scope') {
        event.ports[0]?.postMessage({ok: true, activeScope: await read(SCOPE_KEY) || 'signed-out'});return;
      } else if (event.data?.type === 'reminder-snapshot') {
        await write(`snapshot:${event.data.scope}`, event.data.snapshot);
      } else if (event.data?.type === 'diagnostics') {
        event.ports[0]?.postMessage({ok: true, value: await read('last-push')});return;
      }
      event.ports[0]?.postMessage({ok: true});
    } catch (error) {event.ports[0]?.postMessage({ok: false, error: error.message});}
  })());
});
function apiPath(path) {return new URL(path, new URL(base).origin).href;}
self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== new URL(base).origin || url.pathname.startsWith('/api/') || url.pathname === '/health' || request.headers.has('Authorization')) return;
  const shell = request.mode === 'navigate';
  const flutterAsset = url.pathname.startsWith(new URL('assets/', base).pathname);
  const staticAsset = shell || flutterAsset || /\.(?:js|css|wasm|png|svg|jpg|jpeg|webp|ico|otf|ttf|woff2?)$/.test(url.pathname) || url.href === asset('manifest.json');
  if (!staticAsset) return;
  event.respondWith((async () => {
    const cache = await caches.open(await shellFor(event.clientId));
    if (!shell) {
      const cached = await cache.match(request);
      if (cached) return cached;
    }
    try {
      const response = await fetch(request);
      // Navigation HTML from the network must not overwrite an old shell's
      // hash-verified index before a whole upgrade has committed.
      if (!shell && response.ok && response.type !== 'opaque') await cache.put(request, response.clone());
      return response;
    } catch (error) {
      return await cache.match(request) || (shell ? await cache.match(asset('index.html')) : null) || Response.error();
    }
  })());
});
const quietNow = (start, end, timeZone) => {
  if (start === end) return false;
  const now = new Date();
  const parts = timeZone ? new Intl.DateTimeFormat('en-GB', {timeZone, hour: '2-digit', minute: '2-digit', hourCycle: 'h23'}).formatToParts(now) : null;
  const minute = parts ? Number(parts.find(p => p.type === 'hour').value) * 60 + Number(parts.find(p => p.type === 'minute').value) : now.getHours() * 60 + now.getMinutes();
  return start < end ? minute >= start && minute < end : minute >= start || minute < end;
};
const safeRoute = route => /^\/(?:18|24)\?taskId=[^#\s]+$/.test(route || '') || route === '/27' ? route : '/27';
self.addEventListener('push', event => {
  event.waitUntil((async () => {
    let value;
    try {value = event.data?.json();} catch (_) {await write('last-push', {status: 'invalid-payload', at: Date.now()});return;}
    const scope = await read(SCOPE_KEY);
    if (!value || !scope || scope === 'signed-out' || value.scope !== scope) {await write('last-push', {status: 'wrong-account', at: Date.now()});return;}
    const now = Date.now();
    if (Number(value.expiresAt) && now > Number(value.expiresAt)) {await write('last-push', {status: 'expired', at: now});return;}
    if (Number(value.fireAt) && now + 2000 < Number(value.fireAt)) {await write('last-push', {status: 'early', at: now});return;}
    try {
      if (quietNow(Number(value.quietStart ?? 1320), Number(value.quietEnd ?? 480), value.timeZone)) {await write('last-push', {status: 'quiet-hours', at: now});return;}
    } catch (_) {await write('last-push', {status: 'invalid-time-zone', at: now});return;}
    const key = `delivery:${scope}:${value.id}`;
    const previous = await read(key);
    if (previous && (String(previous.generation) === String(value.generation) || Number(previous.generation) > Number(value.generation))) return;
    const snapshot = await read(`snapshot:${scope}`);
    const serverTest = value.kind === 'test' && Number(value.generation) === 0;
    if (!serverTest && snapshot && Number(snapshot.revision) > Number(value.generation)) {await write('last-push', {status: 'stale-generation', at: now});return;}
    // Validate against the current account/session immediately before display.
    {
      try {
        const url = new URL(apiPath('/api/v1/push/validate'));url.searchParams.set('id', String(value.id));url.searchParams.set('generation', String(value.generation));
        const response = await fetch(url, {credentials: 'include', cache: 'no-store'});
        if (!response.ok) {await write('last-push', {status: `validation-http-${response.status}`, at: now});return;}
        const checked = await response.json();
        if (!checked.valid || checked.scope !== scope) {await write('last-push', {status: 'invalidated', at: now});return;}
      } catch (_) {await write('last-push', {status: 'validation-offline', at: now});return;}
    }
    if (Notification.permission !== 'granted' || await read(SCOPE_KEY) !== scope) return;
    await self.registration.showNotification(String(value.title || 'SERA 提醒'), {
      body: String(value.body || ''), icon: asset('sera-icon.svg'), badge: asset('sera-icon.svg'),
      tag: `sera:${scope}:${value.id}`, renotify: false,
      data: {sera: true, scope, route: safeRoute(value.route), id: value.id, generation: value.generation},
    });
    await write(key, {generation: value.generation, at: now});
    await write('last-push', {status: 'shown', id: value.id, generation: value.generation, at: now});
  })());
});
self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil((async () => {
    const data = event.notification.data;
    if (!data?.sera || await read(SCOPE_KEY) !== data.scope) return;
    const target = `${base}#${safeRoute(data.route)}`;
    const windows = await self.clients.matchAll({type: 'window', includeUncontrolled: true});
    const client = windows.find(item => item.url.startsWith(base));
    if (client) {await client.navigate(target);await client.focus();}
    else await self.clients.openWindow(target);
  })());
});
self.addEventListener('pushsubscriptionchange', event => {
  // Subscription renewal needs the authenticated app to register its new endpoint.
  // Never retain access/refresh tokens or silently claim server registration.
  event.waitUntil(write('last-push', {status: 'subscription-changed-open-app', at: Date.now()}));
});
