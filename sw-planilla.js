// Service worker de la app de Planilla: abre sin conexión y se actualiza solo.
const CACHE = 'planilla-v57';
const BASE = ['./', 'planilla.webmanifest', 'mi-planilla-192.png', 'mi-planilla-512.png', 'mi-planilla-180.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => Promise.all(BASE.map(u => c.add(u).catch(() => { })))).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.hostname.endsWith('supabase.co') || u.hostname.endsWith('openstreetmap.org') || u.hostname.startsWith('maps.google') || u.pathname.endsWith('version.json')) return; // datos y mapas siempre en vivo
  if (e.request.mode === 'navigate') {
    // primero la red (para tener siempre la última versión), si no hay conexión usa la copia guardada
    e.respondWith(fetch(e.request).then(r => { if (r.ok) { const c = r.clone(); caches.open(CACHE).then(x => x.put('./', c)); } return r; }).catch(() => caches.match('./')));
    return;
  }
  // librerías, fuentes e íconos: copia guardada y se refresca en segundo plano
  e.respondWith(caches.match(e.request).then(m => {
    const red = fetch(e.request).then(r => { if (r.ok || r.type === 'opaque') { const c = r.clone(); caches.open(CACHE).then(x => x.put(e.request, c)); } return r; }).catch(() => m);
    return m || red;
  }));
});

// notificaciones push: comprobantes, solicitudes resueltas y solicitudes nuevas
self.addEventListener('push', e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch (_) { d = { title: 'Mi Planilla', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Mi Planilla', {
    body: d.body || '', icon: 'mi-planilla-192.png', badge: 'mi-planilla-192.png', tag: d.tag || undefined, renotify: !!d.tag, data: { url: d.url || '#/' },
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const destino = new URL('./' + (e.notification.data?.url || ''), self.registration.scope).href;
  e.waitUntil(clients.matchAll({ type: 'window', includeUncontrolled: true }).then(ws => {
    const w = ws.find(x => x.url.startsWith(self.registration.scope));
    if (w) return w.focus().then(f => (f || w).navigate ? (f || w).navigate(destino) : null).catch(() => clients.openWindow(destino));
    return clients.openWindow(destino);
  }));
});
