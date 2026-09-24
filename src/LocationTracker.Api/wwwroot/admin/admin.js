// Admin live map. Same-origin with the API, so the HttpOnly auth cookies ride along on every
// fetch; the only thing script has to do is echo the readable csrf_token cookie on writes.
// Display names and emails are user-controlled, so everything is rendered with textContent,
// never innerHTML.
(() => {
  'use strict';

  const POLL_MS = 5000;
  const DETAIL_EVERY_N_POLLS = 3;
  const RECENT_MS = 5 * 60 * 1000;

  const $ = (id) => document.getElementById(id);

  const state = {
    users: [],            // UserLatestLocationResponse[]
    selectedUserId: null,
    selectedTripId: null,
    markers: new Map(),   // userId -> L.CircleMarker
    trailLayer: null,
    tripLayer: null,
    pollTimer: null,
    pollCount: 0,
    firstFit: true,
  };

  // ---------------------------------------------------------------------------
  // HTTP
  // ---------------------------------------------------------------------------
  class AuthRequired extends Error {}

  function csrfToken() {
    const m = document.cookie.match(/(?:^|; )csrf_token=([^;]*)/);
    return m ? decodeURIComponent(m[1]) : null;
  }

  let refreshing = null;

  // Single-flight: several polls can hit an expired token at once, and refresh tokens rotate,
  // so a second concurrent refresh would present an already-used token and trip replay
  // detection, revoking the whole session.
  function refreshSession() {
    if (!refreshing) {
      refreshing = fetch('/api/auth/refresh', {
        method: 'POST',
        credentials: 'same-origin',
        headers: csrfHeaders(),
      }).then((r) => r.ok).catch(() => false).finally(() => { refreshing = null; });
    }
    return refreshing;
  }

  function csrfHeaders() {
    const token = csrfToken();
    return token ? { 'X-CSRF-Token': token } : {};
  }

  async function api(path, { method = 'GET', body, retry = true } = {}) {
    const headers = { Accept: 'application/json', ...(method === 'GET' ? {} : csrfHeaders()) };
    if (body !== undefined) headers['Content-Type'] = 'application/json';

    const res = await fetch(path, {
      method,
      headers,
      credentials: 'same-origin',
      body: body === undefined ? undefined : JSON.stringify(body),
    });

    if (res.status === 401 && retry) {
      if (await refreshSession()) return api(path, { method, body, retry: false });
      throw new AuthRequired();
    }
    if (res.status === 401) throw new AuthRequired();
    if (res.status === 204) return null;
    if (!res.ok) {
      let message = `${res.status} ${res.statusText}`;
      try { message = (await res.json()).message || message; } catch { /* not JSON */ }
      throw new Error(message);
    }
    return res.json();
  }

  // ---------------------------------------------------------------------------
  // Formatting
  // ---------------------------------------------------------------------------
  const timeFmt = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'medium' });

  function ago(iso) {
    const s = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 1000));
    if (s < 60) return `${s}s ago`;
    if (s < 3600) return `${Math.round(s / 60)} min ago`;
    if (s < 86400) return `${Math.round(s / 3600)} h ago`;
    return `${Math.round(s / 86400)} d ago`;
  }

  function km(meters) {
    return meters >= 1000 ? `${(meters / 1000).toFixed(2)} km` : `${Math.round(meters)} m`;
  }

  function kmh(mps) {
    return mps == null ? '—' : `${(mps * 3.6).toFixed(1)} km/h`;
  }

  function el(tag, props = {}, ...children) {
    const node = document.createElement(tag);
    Object.assign(node, props);
    for (const c of children) node.append(c);
    return node;
  }

  function statusOf(u) {
    if (u.activeTripId) return 'active';
    if (u.latest && Date.now() - Date.parse(u.latest.recordedAtUtc) < RECENT_MS) return 'recent';
    return 'stale';
  }

  const COLORS = { active: '#16a34a', recent: '#2f6fed', stale: '#98a2b3' };

  // ---------------------------------------------------------------------------
  // Map
  // ---------------------------------------------------------------------------
  let map;

  function initMap() {
    if (map) return;
    map = L.map('map', { zoomControl: true }).setView([30.0444, 31.2357], 11);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      referrerPolicy: 'strict-origin-when-cross-origin',
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    }).addTo(map);
  }

  function popupFor(u) {
    const l = u.latest;
    const box = el('div', {},
      el('strong', { textContent: u.displayName || u.email }),
      el('div', { textContent: u.email }),
      el('div', { textContent: `${timeFmt.format(new Date(l.recordedAtUtc))} (${ago(l.recordedAtUtc)})` }),
      el('div', { textContent: `Speed ${kmh(l.speed)} · ±${l.accuracyMeters == null ? '?' : Math.round(l.accuracyMeters)} m` }),
    );
    if (u.activeTripId) box.append(el('div', { textContent: `On trip #${u.activeTripId}` }));
    return box;
  }

  function renderMarkers() {
    const seen = new Set();
    for (const u of state.users) {
      if (!u.latest) continue;
      seen.add(u.userId);
      const pos = [u.latest.latitude, u.latest.longitude];
      const color = COLORS[statusOf(u)];
      const selected = u.userId === state.selectedUserId;
      let m = state.markers.get(u.userId);
      if (!m) {
        m = L.circleMarker(pos).addTo(map);
        m.on('click', () => selectUser(u.userId));
        state.markers.set(u.userId, m);
      }
      m.setLatLng(pos);
      m.setStyle({ radius: selected ? 10 : 7, color: '#fff', weight: 2, fillColor: color, fillOpacity: 1 });
      m.bindPopup(popupFor(u));
      m.bindTooltip(u.displayName || u.email, { direction: 'top', offset: [0, -8] });
    }
    for (const [id, m] of state.markers) {
      if (!seen.has(id)) { m.remove(); state.markers.delete(id); }
    }

    if (state.firstFit && state.markers.size) {
      state.firstFit = false;
      const bounds = L.latLngBounds([...state.markers.values()].map((m) => m.getLatLng()));
      map.fitBounds(bounds.pad(0.3), { maxZoom: 15 });
    }
  }

  // ---------------------------------------------------------------------------
  // Sidebar
  // ---------------------------------------------------------------------------
  function renderUsers() {
    const term = $('search').value.trim().toLowerCase();
    const list = $('user-list');
    const users = [...state.users]
      .filter((u) => !term || (u.displayName || '').toLowerCase().includes(term) || u.email.toLowerCase().includes(term))
      .sort((a, b) => {
        const ta = a.latest ? Date.parse(a.latest.recordedAtUtc) : 0;
        const tb = b.latest ? Date.parse(b.latest.recordedAtUtc) : 0;
        return tb - ta;
      });

    list.replaceChildren(...users.map((u) => {
      const status = statusOf(u);
      const name = el('div', { className: 'name' },
        el('span', { className: `dot ${status}` }),
        el('span', { textContent: u.displayName || u.email }));
      if (u.activeTripId) name.append(el('span', { className: 'badge', textContent: 'on trip' }));
      const sub = el('div', {
        className: 'sub',
        textContent: u.latest ? `${u.email} · ${ago(u.latest.recordedAtUtc)}` : `${u.email} · no points yet`,
      });
      const li = el('li', {}, name, sub);
      if (u.userId === state.selectedUserId) li.classList.add('selected');
      li.addEventListener('click', () => selectUser(u.userId));
      return li;
    }));

    $('poll-status').textContent = `${state.users.length} users · updated ${new Date().toLocaleTimeString()}`;
  }

  async function selectUser(userId) {
    state.selectedUserId = userId;
    state.selectedTripId = null;
    clearTrip();
    renderUsers();
    renderMarkers();

    const u = state.users.find((x) => x.userId === userId);
    $('detail').hidden = false;
    $('detail-name').textContent = u ? (u.displayName || u.email) : '';
    $('detail-meta').textContent = u && u.latest
      ? `${u.email} · last point ${timeFmt.format(new Date(u.latest.recordedAtUtc))}`
      : (u ? `${u.email} · no points yet` : '');

    if (u && u.latest) map.setView([u.latest.latitude, u.latest.longitude], Math.max(map.getZoom(), 15));

    await loadDetail(true);
  }

  function closeDetail() {
    state.selectedUserId = null;
    state.selectedTripId = null;
    clearTrail();
    clearTrip();
    $('detail').hidden = true;
    renderUsers();
    renderMarkers();
  }

  async function loadDetail(fit) {
    const id = state.selectedUserId;
    if (!id) return;
    const [locations, trips] = await Promise.all([
      $('show-trail').checked ? api(`/api/admin/users/${id}/locations?pageSize=500`) : Promise.resolve(null),
      api(`/api/admin/users/${id}/trips?pageSize=25`),
    ]);
    if (id !== state.selectedUserId) return; // selection changed while loading

    clearTrail();
    if (locations && locations.items.length > 1) {
      const pts = locations.items.slice().reverse().map((p) => [p.latitude, p.longitude]);
      state.trailLayer = L.polyline(pts, { color: '#2f6fed', weight: 3, opacity: 0.6 }).addTo(map);
      if (fit && !state.selectedTripId) map.fitBounds(state.trailLayer.getBounds().pad(0.2), { maxZoom: 17 });
    }
    renderTrips(trips.items);
  }

  function renderTrips(trips) {
    const list = $('trip-list');
    if (!trips.length) {
      list.replaceChildren(el('li', { className: 'sub', textContent: 'No trips yet.' }));
      return;
    }
    list.replaceChildren(...trips.map((t) => {
      const title = t.isActive
        ? `#${t.id} · in progress · ${km(t.distanceMeters)}`
        : `#${t.id} · ${km(t.distanceMeters)} · ${t.duration ?? ''}`;
      const sub = `${timeFmt.format(new Date(t.startedAtUtc))} · ${t.pointCount} pts · max ${kmh(t.maxSpeedMps)}` +
        (t.endReason ? ` · ${t.endReason}` : '');
      const li = el('li', {},
        el('div', { className: 'name' }, t.isActive ? el('span', { className: 'dot active' }) : '', el('span', { textContent: title })),
        el('div', { className: 'sub', textContent: sub }));
      if (t.id === state.selectedTripId) li.classList.add('selected');
      li.addEventListener('click', () => showTrip(t.id));
      return li;
    }));
  }

  async function showTrip(tripId) {
    state.selectedTripId = tripId;
    for (const li of $('trip-list').children) li.classList.remove('selected');
    const detail = await api(`/api/admin/trips/${tripId}`);
    clearTrip();
    const pts = detail.path.map((p) => [p.latitude, p.longitude]);
    if (!pts.length) return;
    state.tripLayer = L.layerGroup([
      L.polyline(pts, { color: '#f79009', weight: 5 }),
      L.circleMarker(pts[0], { radius: 6, color: '#fff', weight: 2, fillColor: '#16a34a', fillOpacity: 1 }).bindTooltip('Start'),
      L.circleMarker(pts[pts.length - 1], { radius: 6, color: '#fff', weight: 2, fillColor: '#d92d20', fillOpacity: 1 }).bindTooltip(detail.trip.isActive ? 'Now' : 'End'),
    ]).addTo(map);
    map.fitBounds(L.latLngBounds(pts).pad(0.2), { maxZoom: 17 });
    renderTrips((await api(`/api/admin/users/${state.selectedUserId}/trips?pageSize=25`)).items);
  }

  function clearTrail() { if (state.trailLayer) { state.trailLayer.remove(); state.trailLayer = null; } }
  function clearTrip() { if (state.tripLayer) { state.tripLayer.remove(); state.tripLayer = null; } }

  // ---------------------------------------------------------------------------
  // Polling
  // ---------------------------------------------------------------------------
  async function poll() {
    try {
      state.users = await api('/api/admin/locations/latest');
      renderMarkers();
      renderUsers();
      state.pollCount++;
      if (state.selectedUserId && state.pollCount % DETAIL_EVERY_N_POLLS === 0) await loadDetail(false);
    } catch (e) {
      if (e instanceof AuthRequired) return showLogin('Your session expired. Please sign in again.');
      $('poll-status').textContent = `Update failed: ${e.message}`;
    }
  }

  function startPolling() {
    stopPolling();
    poll();
    state.pollTimer = setInterval(poll, POLL_MS);
  }

  function stopPolling() {
    if (state.pollTimer) clearInterval(state.pollTimer);
    state.pollTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------------
  function showLogin(message = '') {
    stopPolling();
    $('app-view').hidden = true;
    $('login-view').hidden = false;
    $('login-error').textContent = message;
    $('login-email').focus();
  }

  function showApp(profile) {
    $('login-view').hidden = true;
    $('app-view').hidden = false;
    $('admin-name').textContent = profile.displayName || profile.email;
    initMap();
    // The map container was hidden when Leaflet measured it.
    setTimeout(() => map.invalidateSize(), 0);
    startPolling();
  }

  async function login(evt) {
    evt.preventDefault();
    const button = $('login-submit');
    button.disabled = true;
    $('login-error').textContent = '';
    try {
      const res = await fetch('/api/auth/login', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ email: $('login-email').value.trim(), password: $('login-password').value }),
      });
      if (res.status === 429) throw new Error('Too many attempts. Wait a minute and try again.');
      if (!res.ok) throw new Error('Invalid email or password.');
      const profile = await res.json();
      if (!profile.roles.includes('Admin')) {
        await api('/api/auth/logout', { method: 'POST', retry: false }).catch(() => {});
        throw new Error('This account is not an administrator.');
      }
      $('login-password').value = '';
      showApp(profile);
    } catch (e) {
      $('login-error').textContent = e.message;
    } finally {
      button.disabled = false;
    }
  }

  async function logout() {
    stopPolling();
    await api('/api/auth/logout', { method: 'POST', retry: false }).catch(() => {});
    closeDetail();
    for (const m of state.markers.values()) m.remove();
    state.markers.clear();
    state.firstFit = true;
    showLogin();
  }

  async function boot() {
    $('login-form').addEventListener('submit', login);
    $('logout').addEventListener('click', logout);
    $('search').addEventListener('input', renderUsers);
    $('detail-close').addEventListener('click', closeDetail);
    $('show-trail').addEventListener('change', () => { if (!$('show-trail').checked) clearTrail(); loadDetail(true); });

    try {
      const me = await api('/api/auth/me');
      if (me.roles.includes('Admin')) return showApp(me);
      showLogin('Signed in as a non-admin account. Sign in as an administrator.');
    } catch {
      showLogin();
    }
  }

  boot();
})();
