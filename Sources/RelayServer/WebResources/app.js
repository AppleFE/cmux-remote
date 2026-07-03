'use strict';

// cmux Remote — web client.
// Mirrors the iOS app exactly: 4 tabs (workspaces / active / inbox / settings),
// per-workspace surface lists with create+close, a terminal mirror, an event
// inbox, and connection settings.
//
// Protocol:
//   1. POST /v1/devices/me/register  → {device_id, token}   (Tailscale whois gate)
//   2. WS  /v1/ws  with subprotocol `bearer.<token>`
//   3. First frame: HelloFrame {deviceId, appVersion, protocolVersion}
//   4. RPC: {id, method, params}  ↔  {id, ok, result, error}
//   5. Server pushes PushFrame {type: screen.full|screen.diff|event|...}

const SCHEME    = location.protocol === 'https:' ? 'https' : 'http';
const WS_SCHEME = location.protocol === 'https:' ? 'wss' : 'ws';
const HOST = location.hostname;
const PORT = location.port || (SCHEME === 'https:' ? '443' : '80');
const BASE    = `${SCHEME}://${HOST}:${PORT}`;
const WS_URL  = `${WS_SCHEME}://${HOST}:${PORT}/v1/ws`;
const PROTOCOL_VERSION = 1;
const APP_VERSION = 'web-2.0';
const SUBSCRIPTION_LINES = 200;

// ---------- state ----------
let ws = null;
let term = null;
let fitAddon = null;
let reconnectDelay = 1000;
const pending = new Map(); // rpc id → {resolve, reject}

let connection = 'disconnected'; // disconnected | connecting | connected
let selectedTab = 'workspaces';

let workspaces = [];                       // [{id, name, index}]
let surfacesByWorkspace = {};              // {wsId: [{id, title, index}]}
let surfacesLoading = new Set();           // wsIds mid surface.list

let currentWorkspaceId = null;
let currentSurfaceId = null;
let requestedSurfaceId = null;             // surface to open on next active show
let currentRev = 0;
let surfaceRows = 0, surfaceCols = 0;

let notifications = [];                    // newest first
let readNotifIds = new Set();
let busyWorkspaces = new Set();            // wsIds mid create/rename/close
let busySurfaces = new Set();              // "wsId:surfaceAction"

let battery = { available: false, percent: null, state: null, isCharging: null, powerSource: null };

// ---------- DOM helpers ----------
const $  = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}
// ---------- terminal column width (CJK/fullwidth-aware) ----------
// read_text gives plain rendered rows; to size xterm so wide TUI borders
// (and Korean/CJK text) don't wrap, we measure each row's display width
// ( Hangul/CJK = 2 columns, box-drawing/ASCII = 1 ) instead of code units.
function isFullWidthCode(code) {
  return (
    (code >= 0x1100 && code <= 0x115F) ||
    (code >= 0x2E80 && code <= 0x303E) ||
    (code >= 0x3040 && code <= 0x33BF) ||
    (code >= 0x3400 && code <= 0x4DBF) ||
    (code >= 0x4E00 && code <= 0xA4CF) ||
    (code >= 0xAC00 && code <= 0xD7A3) ||
    (code >= 0xF900 && code <= 0xFAFF) ||
    (code >= 0xFE30 && code <= 0xFE6F) ||
    (code >= 0xFF01 && code <= 0xFF60) ||
    (code >= 0xFFE0 && code <= 0xFFE6) ||
    (code >= 0x1F300 && code <= 0x1FAFF)
  );
}
function displayWidth(str) {
  let w = 0;
  for (const ch of String(str)) {
    const code = ch.codePointAt(0);
    if (code < 0x20 || code === 0x7f) continue; // control chars take no width
    w += isFullWidthCode(code) ? 2 : 1;
  }
  return w;
}

// ---------- token (localStorage) ----------
const getToken    = () => localStorage.getItem('cmux_bearer');
const setToken    = t => localStorage.setItem('cmux_bearer', t);
const getDeviceId = () => localStorage.getItem('cmux_device_id');
const setDeviceId = d => localStorage.setItem('cmux_device_id', d);

async function ensureRegistered() {
  if (getToken() && getDeviceId()) return;
  setStatus('connecting');
  let r;
  try {
    r = await fetch(`${BASE}/v1/devices/me/register`, { method: 'POST' });
  } catch (e) {
    banner(`연결 실패: ${e.message}. 같은 tailnet에 있는지, relay가 켜져 있는지 확인.`, 'error');
    throw e;
  }
  if (r.status === 403) {
    banner('403: 이 기기가 tailnet에 있지 않거나 허용되지 않았습니다.', 'error');
    throw new Error('forbidden');
  }
  if (!r.ok) {
    banner(`등록 실패: HTTP ${r.status}`, 'error');
    throw new Error(`register ${r.status}`);
  }
  const body = await r.json();
  setToken(body.token);
  setDeviceId(body.device_id);
}

// ---------- WebSocket ----------
let authFailures = 0;
function connect() {
  const token = getToken();
  if (!token) { ensureRegistered().then(connect).catch(() => scheduleReconnect()); return; }
  setStatus('connecting');
  let opened = false;
  let wsClient;
  try {
    wsClient = new WebSocket(WS_URL, [`bearer.${token}`]);
  } catch (e) {
    scheduleReconnect();
    return;
  }
  ws = wsClient;
  wsClient.binaryType = 'arraybuffer';
  wsClient.onopen = () => {
    opened = true;
    authFailures = 0;
    setStatus('connected');
    reconnectDelay = 1000;
    sendHello();
    bootstrap().catch(e => console.error('bootstrap', e));
  };
  wsClient.onmessage = ev => {
    const text = typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data);
    handleMessage(text);
  };
  wsClient.onclose = () => {
    if (ws === wsClient) ws = null;
    pending.clear();
    if (opened) {
      setStatus('disconnected');
      scheduleReconnect();
    } else {
      handleAuthFailure();
    }
  };
  wsClient.onerror = () => { /* close handler decides recovery */ };
}

function handleAuthFailure() {
  localStorage.removeItem('cmux_bearer');
  localStorage.removeItem('cmux_device_id');
  setStatus('disconnected');
  authFailures++;
  const delay = Math.min(1000 * Math.pow(2, Math.min(authFailures, 4)), 15000);
  setTimeout(() => {
    ensureRegistered().then(() => { authFailures = 0; connect(); })
      .catch(() => scheduleReconnect());
  }, delay);
}

function scheduleReconnect() {
  setTimeout(() => connect(), reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, 15000);
}

function sendHello() {
  send({ deviceId: getDeviceId(), appVersion: APP_VERSION, protocolVersion: PROTOCOL_VERSION });
}

function send(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

// ---------- RPC ----------
function rpc(method, params = {}) {
  return new Promise((resolve, reject) => {
    if (!ws || ws.readyState !== WebSocket.OPEN) { reject(new Error('ws not open')); return; }
    const id = (crypto.randomUUID ? crypto.randomUUID() : String(Date.now() + Math.random()));
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
    setTimeout(() => {
      const p = pending.get(id);
      if (p) {
        pending.delete(id);
        p.reject(new Error(`rpc timeout: ${method}`));
      }
    }, 15000);
  });
}

// ---------- inbound dispatch ----------
function handleMessage(text) {
  let msg;
  try { msg = JSON.parse(text); } catch { return; }

  // RPC response?
  if (msg.id && pending.has(msg.id)) {
    const p = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) p.reject(new Error(msg.error.message || 'rpc error'));
    else p.resolve(msg.result);
    return;
  }

  // PushFrame?
  if (msg.type) handlePush(msg);
}

function handlePush(frame) {
  switch (frame.type) {
    case 'screen.full':     renderFull(frame); break;
    case 'screen.diff':     applyDiff(frame); break;
    case 'screen.checksum': /* relay re-syncs on mismatch */ break;
    case 'event':           handleEvent(frame); break;
    case 'ping':            send({ type: 'pong', ts: Date.now() }); break;
    case 'pong':            break;
    default: break;
  }
}

// ---------- screen rendering ----------
function cursorHome(row, col) {
  return `\x1b[${(row ?? 0) + 1};${(col ?? 0) + 1}H`;
}

function syncTerminalSize() {
  if (!term) return;
  const cols = surfaceCols || term.cols;
  const rows = surfaceRows || term.rows;
  if (cols !== term.cols || rows !== term.rows) {
    try { term.resize(Math.max(1, cols), Math.max(1, rows)); } catch {}
  }
}
function pinTerminalToBottom() {
  // The terminal is sized to the full surface grid (often taller than the
  // viewport), so we pin both xterm's own buffer and the scrolling wrap to
  // the bottom — that's where the live cursor / most recent output is.
  if (term) { try { term.scrollToBottom(); } catch {} }
  const wrap = document.getElementById('terminal-wrap');
  if (wrap) wrap.scrollTop = wrap.scrollHeight;
}

function renderFull(frame) {
  if (!term) return;
  if (frame.surface_id) currentSurfaceId = frame.surface_id;
  currentRev = frame.rev || 0;
  surfaceCols = frame.cols || surfaceCols;
  surfaceRows = (frame.rows && frame.rows.length) || frame.rows_count || surfaceRows;
  syncTerminalSize();
  term.reset();
  const rows = frame.rows || [];
  for (let i = 0; i < rows.length; i++) {
    term.write(`\x1b[${i + 1};1H\x1b[2K\x1b[0m${rows[i] || ''}`);
  }
  if (frame.cursor) {
    const r = frame.cursor.row ?? frame.cursor.y ?? 0;
    const c = frame.cursor.col ?? frame.cursor.x ?? 0;
    term.write(cursorHome(r, c));
  }
}

function applyDiff(frame) {
  if (!term || !frame.ops) return;
  if (frame.surface_id) currentSurfaceId = frame.surface_id;
  currentRev = frame.rev || currentRev;
  let maxRow = surfaceRows;
  for (const op of frame.ops) {
    if (op.op === 'row' && (op.y ?? 0) + 1 > maxRow) maxRow = (op.y ?? 0) + 1;
  }
  if (maxRow > surfaceRows) { surfaceRows = maxRow; syncTerminalSize(); }
  for (const op of frame.ops) {
    switch (op.op) {
      case 'clear':      term.write('\x1b[2J\x1b[H'); break;
      case 'row':        term.write(`\x1b[${(op.y ?? 0) + 1};1H\x1b[2K\x1b[0m${op.text || ''}`); break;
      case 'cursor':     term.write(cursorHome(op.y, op.x)); break;
    }
  }
}

// ---------- events / inbox ----------
// Faithful JS port of SharedKit InboxNotification.record(from:) — turns an
// event push frame into a NotificationRecord when it is an inbox-worthy event.
function handleEvent(frame) {
  const rec = buildNotification(frame);
  if (rec) {
    notifications.unshift(rec);
    if (notifications.length > 200) notifications.length = 200;
    renderInbox();
    renderInboxBadge();
    if (frame.payload && frame.payload.title) banner(frame.payload.title);
  }
  if (frame.category === 'workspace') {
    refreshWorkspaces().catch(() => {});
  } else if (frame.category === 'surface') {
    // Re-fetch surfaces for the known workspaces so cards/surface-bar update.
    for (const ws of workspaces) refreshSurfaces(ws.id).catch(() => {});
  }
}

function buildNotification(frame) {
  if (!isInboxEvent(frame)) return null;
  const p = (frame.payload && typeof frame.payload === 'object') ? frame.payload : {};
  const workspaceId = str(p, 'workspace_id') || str(p, 'workspaceId') || str(p, 'workspace') || 'unknown';
  const title = str(p, 'title') || str(p, 'headline') || titleFallback(frame);
  const body = str(p, 'body') || str(p, 'message') || str(p, 'text') || str(p, 'summary')
            || str(p, 'reason') || str(p, 'status') || str(p, 'prompt')
            || nested(p, 'details', 'message') || nested(p, 'details', 'body') || title;
  const surfaceId = str(p, 'surface_id') || str(p, 'surfaceId') || str(p, 'surface');
  const id = str(p, 'id') || str(p, 'notification_id') || str(p, 'notificationId')
          || str(p, 'event_id') || str(p, 'eventId') || nested(p, 'details', 'id')
          || (isNeedsInputEvent(frame)
              ? synthNeedsInputId(frame.name, workspaceId, surfaceId, title, body)
              : (crypto.randomUUID ? crypto.randomUUID() : String(Date.now())));
  const subtitle = str(p, 'subtitle') || str(p, 'workspace_title') || str(p, 'workspaceTitle')
                || str(p, 'surface_title') || str(p, 'surfaceTitle');
  const ts = intVal(p, 'ts') || Math.floor(Date.now() / 1000);
  const threadId = str(p, 'thread_id') || str(p, 'threadId') || `workspace-${workspaceId}`;
  return { id, workspaceId, surfaceId, title, subtitle, body, ts, threadId, category: frame.category, name: frame.name };
}

function isInboxEvent(frame) { return isNotificationEvent(frame) || isNeedsInputEvent(frame); }
function isNotificationEvent(frame) { return frame.category === 'notification' || frame.name === 'notification.created'; }
function isNeedsInputEvent(frame) {
  const text = inboxSearchText(frame);
  const needsHuman = /needs input|waiting for your input|needs your attention|needs your approval|approval required|permission prompt/.test(text);
  return needsHuman && (hasKnownAgentSource(text) || /needs input/.test(text));
}
function hasKnownAgentSource(text) { return /claude|codex|openai/.test(text); }
function inboxSearchText(frame) {
  const p = (frame.payload && typeof frame.payload === 'object') ? frame.payload : {};
  const vals = [frame.category || '', frame.name || ''];
  const keys = ['app','source','kind','type','status','state','reason','title','subtitle','body',
    'message','text','summary','workspace_title','workspaceTitle','surface_title','surfaceTitle',
    'agent','model','role'];
  for (const k of keys) { const v = str(p, k); if (v) vals.push(v); }
  appendStringLeaves(p, vals);
  return vals.join(' ').toLowerCase().replace(/[_-]/g, ' ');
}
function appendStringLeaves(obj, vals) {
  for (const v of Object.values(obj || {})) {
    if (typeof v === 'string') { if (v) vals.push(v); }
    else if (Array.isArray(v)) v.forEach(x => { if (typeof x === 'string' && x) vals.push(x); else if (x && typeof x === 'object') appendStringLeaves(x, vals); });
    else if (v && typeof v === 'object') appendStringLeaves(v, vals);
  }
}
function titleFallback(frame) {
  if (isNeedsInputEvent(frame)) return `${needsInputSourceName(frame)} needs input`;
  if (frame.name === 'notification.created') return 'cmux 알림';
  return frame.name || 'cmux event';
}
function needsInputSourceName(frame) {
  const t = inboxSearchText(frame);
  if (/codex/.test(t)) return 'Codex';
  if (/openai/.test(t)) return 'OpenAI';
  if (/claude/.test(t)) return 'Claude Code';
  if (frame.category === 'hook') return 'cmux hook';
  if (frame.category === 'agent') return 'Agent';
  return 'cmux';
}
function synthNeedsInputId(name, wsId, sId, title, body) {
  const raw = [name, wsId, sId || '', title, body].join('|');
  const slug = raw.replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 96);
  return `needs-input-${slug}`;
}

function str(o, k) { const v = o && o[k]; return (typeof v === 'string' && v) ? v : null; }
function intVal(o, k) { const v = o && o[k]; return (typeof v === 'number') ? Math.floor(v) : null; }
function nested(o, ...keys) {
  let cur = o;
  for (const k of keys) { if (!cur || typeof cur !== 'object') return null; cur = cur[k]; }
  return (typeof cur === 'string' && cur) ? cur : null;
}

// unread helpers (mirror WorkspaceNotificationTally)
function unreadByWorkspace() {
  const counts = {};
  for (const n of notifications) if (!readNotifIds.has(n.id)) counts[n.workspaceId] = (counts[n.workspaceId] || 0) + 1;
  return counts;
}
function unreadCount() {
  let c = 0; for (const n of notifications) if (!readNotifIds.has(n.id)) c++; return c;
}
function markWorkspaceSeen(wsId) {
  for (const n of notifications) if (n.workspaceId === wsId) readNotifIds.add(n.id);
  renderInboxBadge();
}

// ---------- terminal init ----------
function initTerminal() {
  if (term) return;
  term = new Terminal({
    fontFamily: 'Menlo, Monaco, "DejaVu Sans Mono", "Courier New", monospace',
    fontSize: 13,
    lineHeight: 1.1,
    theme: {
      background: '#24283b',
      foreground: '#c0caf5',
      cursor:     '#c0caf5',
      cursorAccent: '#24283b',
      selectionBackground: '#33467c',
      black:   '#32344a', red:     '#f7768e', green:   '#9ece6a', yellow:  '#e0af68',
      blue:    '#7aa2f7', magenta: '#bb9af7', cyan:    '#7dcfff', white:   '#a9b1d6',
      brightBlack:   '#444b6a', brightRed:     '#ff7a93', brightGreen:   '#b9f27c', brightYellow:  '#ff9e64',
      brightBlue:    '#7da6ff', brightMagenta: '#bb9af7', brightCyan:    '#0db9d7', brightWhite:   '#acb0d0',
    },
    cursorBlink: true,
    convertEol: false,
    scrollback: 1000,
    allowProposedApi: true,
  });
  fitAddon = new FitAddon.FitAddon();
  term.loadAddon(fitAddon);
  term.open(document.getElementById('terminal'));
  try { fitAddon.fit(); } catch {}

  term.attachCustomKeyEventHandler((event) => {
    if (event.type !== 'keydown') return true;
    const mods = [];
    if (event.ctrlKey) mods.push('ctrl');
    if (event.altKey) mods.push('alt');
    if (event.shiftKey) mods.push('shift');
    if (event.metaKey) mods.push('cmd');
    const keyName = mapDomKey(event);
    if (!keyName) return true;
    if (mods.length === 0 && !isSpecialKey(keyName)) return true;
    const ordered = ['ctrl', 'alt', 'shift', 'cmd'].filter(m => mods.includes(m));
    const encoded = ordered.length ? ordered.join('+') + '+' + keyName : keyName;
    sendKey(encoded);
    return false;
  });

  term.onData(data => sendInput(data));
  // The terminal mirrors the remote surface grid (a fixed cols×rows), so on
  // resize we re-apply that grid size rather than fitting to the viewport
  // (which would scramble the absolute-row layout). The wrap scrolls instead.
  window.addEventListener('resize', () => { syncTerminalSize(); pinTerminalToBottom(); });
  window.addEventListener('orientationchange', () => setTimeout(() => { syncTerminalSize(); pinTerminalToBottom(); }, 200));
}

// ---------- input ----------
function mapDomKey(event) {
  switch (event.key) {
    case 'Enter': return 'enter';
    case 'Tab': return 'tab';
    case 'Escape': return 'esc';
    case 'Backspace': return 'backspace';
    case 'Delete': return 'delete';
    case 'ArrowUp': return 'up';
    case 'ArrowDown': return 'down';
    case 'ArrowLeft': return 'left';
    case 'ArrowRight': return 'right';
    case 'Home': return 'home';
    case 'End': return 'end';
    case 'PageUp': return 'pgup';
    case 'PageDown': return 'pgdn';
    case ' ': return 'space';
  }
  if (event.key.length === 1) return event.key.toLowerCase();
  return null;
}
function isSpecialKey(name) {
  return ['up', 'down', 'left', 'right', 'home', 'end', 'pgup', 'pgdn', 'esc'].includes(name);
}
function encodeKey(data) {
  switch (data) {
    case '\r': case '\n': return 'enter';
    case '\t': return 'tab';
    case '\x1b': return 'esc';
    case '\x7f': case '\b': return 'backspace';
    case '\x1b[A': return 'up';
    case '\x1b[B': return 'down';
    case '\x1b[C': return 'right';
    case '\x1b[D': return 'left';
    case '\x1b[H': return 'home';
    case '\x1b[F': return 'end';
    case '\x1b[5~': return 'pgup';
    case '\x1b[6~': return 'pgdn';
    case '\x1b[3~': return 'delete';
  }
  if (data.length === 1) {
    const code = data.charCodeAt(0);
    if (code >= 1 && code <= 26) return 'ctrl+' + String.fromCharCode(96 + code);
    return null;
  }
  return null;
}
function sendInput(data) {
  if (!currentWorkspaceId || !currentSurfaceId) return;
  const key = encodeKey(data);
  if (key !== null) sendKey(key);
  else sendText(data);
}
function sendText(text) {
  if (!currentWorkspaceId || !currentSurfaceId) return;
  showInputFeedback(`Sent ${text.trim() || 'text'}`, false);
  rpc('surface.send_text', { workspace_id: currentWorkspaceId, surface_id: currentSurfaceId, text })
    .catch(e => showInputFeedback(String(e.message || e), true));
}
function sendKey(key) {
  if (!currentWorkspaceId || !currentSurfaceId) return;
  rpc('surface.send_key', { workspace_id: currentWorkspaceId, surface_id: currentSurfaceId, key })
    .catch(e => console.warn('send_key', e));
}
function submitCommand(command) {
  const trimmed = (command || '').trim();
  if (!currentWorkspaceId || !currentSurfaceId) return;
  if (!trimmed) { sendKey('enter'); return; }
  showInputFeedback(`Sent ${trimmed}`, false);
  rpc('surface.send_text', { workspace_id: currentWorkspaceId, surface_id: currentSurfaceId, text: trimmed })
    .then(() => rpc('surface.send_key', { workspace_id: currentWorkspaceId, surface_id: currentSurfaceId, key: 'enter' }))
    .catch(e => showInputFeedback(String(e.message || e), true));
}

// ============================================================
//  TAB ROUTING
// ============================================================
function switchTab(tab) {
  selectedTab = tab;
  for (const s of ['workspaces', 'active', 'inbox', 'settings']) {
    $(`#screen-${s}`).classList.toggle('hidden', s !== tab);
  }
  $$('#tabbar .tab').forEach(t => t.classList.toggle('active', t.dataset.tab === tab));
  if (tab === 'active') {
    // Defer init+fit+subscribe to the next frame so #screen-active has been
    // laid out (real height). xterm opened into a zero-height container
    // (e.g. while the screen was hidden) caches bogus metrics and renders
    // blank, so we never init the terminal before it is visible.
    requestAnimationFrame(() => {
      initTerminal();
      if (fitAddon) { try { fitAddon.fit(); } catch {} }
      if (!currentWorkspaceId && workspaces.length) {
        currentWorkspaceId = workspaces[0].id;
        renderActiveHeader();
        renderSurfaceBar();
      }
      consumeRequestedSurface();
    });
  }
}

// ============================================================
//  BOOTSTRAP / DATA
// ============================================================
async function bootstrap() {
  await refreshWorkspaces();
  refreshBattery().catch(() => {});
  renderSettings();
}

async function refreshWorkspaces() {
  try {
    const result = await rpc('workspace.list');
    const loaded = ((result && result.workspaces) || []).map(w => ({
      id: w.id,
      name: w.name || w.title || `#${w.index}`,
      index: w.index ?? 0,
    })).sort((a, b) => a.index - b.index);
    workspaces = loaded;
    if (currentWorkspaceId && !loaded.some(w => w.id === currentWorkspaceId)) currentWorkspaceId = null;
    renderWorkspaces();
    renderDrawer();
    renderActiveHeader();
    // Load surfaces for every workspace (workspaces tab shows them inline).
    await Promise.all(loaded.map(w => refreshSurfaces(w.id)));
  } catch (e) {
    setConnError(`workspace.list 실패: ${e.message}`);
  }
}

async function refreshSurfaces(workspaceId) {
  surfacesLoading.add(workspaceId);
  try {
    const result = await rpc('surface.list', { workspace_id: workspaceId });
    const list = ((result && result.surfaces) || []).map(s => ({
      id: s.id, title: s.title || `surface ${s.index}`, index: s.index ?? 0,
    })).sort((a, b) => a.index - b.index);
    surfacesByWorkspace[workspaceId] = list;
  } catch {
    surfacesByWorkspace[workspaceId] = surfacesByWorkspace[workspaceId] || [];
  } finally {
    surfacesLoading.delete(workspaceId);
  }
  renderWorkspaces();
  renderSurfaceBar();
  renderDrawer();
}

function surfacesFor(wsId) { return surfacesByWorkspace[wsId] || []; }

// ============================================================
//  WORKSPACES TAB
// ============================================================
function renderWorkspaces() {
  const list = $('#workspace-list');
  const empty = $('#workspace-empty');
  const search = $('#workspace-search').value.trim().toLowerCase();
  const filtered = search ? workspaces.filter(w => (w.name || '').toLowerCase().includes(search)) : workspaces;

  list.innerHTML = '';
  empty.classList.toggle('hidden', filtered.length > 0);

  const unread = unreadByWorkspace();
  for (const ws of filtered) {
    const card = el('div', 'workspace-card' + (ws.id === currentWorkspaceId ? ' selected' : ''));

    const head = el('div', 'ws-card-head');
    head.addEventListener('click', () => openWorkspace(ws.id, null));

    const idx = el('div', 'ws-index', String(ws.index + 1).padStart(2, '0'));
    const meta = el('div', 'ws-meta');
    const name = el('div', 'ws-name', ws.name);
    const surfCount = surfacesFor(ws.id).length;
    const sub = el('div', 'ws-sub');
    sub.appendChild(el('span', 'count', String(surfCount)));
    sub.appendChild(el('span', 'label', 'surfaces'));
    meta.appendChild(name); meta.appendChild(sub);

    head.appendChild(idx); head.appendChild(meta);

    const uc = unread[ws.id] || 0;
    if (uc > 0) head.appendChild(el('span', 'ws-unread', uc > 99 ? '99+' : String(uc)));

    const actions = el('div', 'ws-actions');
    const renameBtn = el('button', 'ws-action', '✎');
    renameBtn.title = 'Rename';
    renameBtn.addEventListener('click', e => { e.stopPropagation(); promptRenameWorkspace(ws); });
    const closeBtn = el('button', 'ws-action danger', '×');
    closeBtn.title = 'Close workspace';
    closeBtn.addEventListener('click', e => { e.stopPropagation(); confirmCloseWorkspace(ws); });
    actions.appendChild(renameBtn); actions.appendChild(closeBtn);
    head.appendChild(actions);

    card.appendChild(head);

    // Inline surfaces list (the user's key requirement: show surfaces per
    // workspace, and allow creating new surfaces from here).
    const surfWrap = el('div', 'ws-surfaces');
    const surfaces = surfacesFor(ws.id);
    if (surfacesLoading.has(ws.id) && surfaces.length === 0) {
      surfWrap.appendChild(el('div', 'ws-surface-loading', 'loading surfaces…'));
    }
    for (const s of surfaces) {
      const row = el('div', 'ws-surface-row');
      row.addEventListener('click', ev => { ev.stopPropagation(); openWorkspace(ws.id, s.id); });
      row.appendChild(el('span', 'play', '▶'));
      row.appendChild(el('span', 's-title', s.title));
      if (surfaces.length > 1) {
        const sc = el('button', 's-close', '×');
        sc.title = 'Close surface';
        sc.addEventListener('click', ev => { ev.stopPropagation(); confirmCloseSurface(ws, s); });
        row.appendChild(sc);
      }
      surfWrap.appendChild(row);
    }
    const newSurf = el('div', 'ws-new-surface' + (busyWorkspaces.has(ws.id) ? ' busy' : ''));
    newSurf.textContent = busyWorkspaces.has(ws.id) ? '…' : '+ NEW SURFACE';
    newSurf.addEventListener('click', ev => { ev.stopPropagation(); createSurface(ws.id); });
    surfWrap.appendChild(newSurf);

    card.appendChild(surfWrap);
    list.appendChild(card);
  }
}

async function createWorkspace() {
  const name = await promptModal({ title: 'New Workspace', label: 'name', confirmText: 'Create', placeholder: 'name' });
  if (!name || !name.trim()) return;
  try {
    await rpc('workspace.create', { title: name.trim() });
    await refreshWorkspaces();
  } catch (e) {
    setWorkspaceError(String(e.message || e));
  }
}

async function promptRenameWorkspace(ws) {
  const title = await promptModal({ title: 'Rename Workspace', label: 'name', confirmText: 'Rename', placeholder: 'name', initial: ws.name });
  if (!title || !title.trim()) return;
  try {
    await rpc('workspace.rename', { workspace_id: ws.id, title: title.trim() });
    await refreshWorkspaces();
  } catch (e) {
    setWorkspaceError(String(e.message || e));
  }
}

async function confirmCloseWorkspace(ws) {
  const ok = await confirmModal({ title: 'Close workspace?', body: `This closes ${ws.name} in cmux.`, confirmText: `Close ${ws.name}`, danger: true });
  if (!ok) return;
  busyWorkspaces.add(ws.id); renderWorkspaces();
  try {
    await rpc('workspace.close', { workspace_id: ws.id });
    if (surfacesByWorkspace[ws.id]) delete surfacesByWorkspace[ws.id];
    if (currentWorkspaceId === ws.id) currentWorkspaceId = null;
    await refreshWorkspaces();
  } catch (e) {
    setWorkspaceError(String(e.message || e));
  } finally {
    busyWorkspaces.delete(ws.id); renderWorkspaces();
  }
}

async function createSurface(workspaceId) {
  if (busyWorkspaces.has(workspaceId)) return;
  busyWorkspaces.add(workspaceId); renderWorkspaces();
  try {
    const res = await rpc('surface.create', { workspace_id: workspaceId, type: 'terminal', focus: true });
    await refreshSurfaces(workspaceId);
    // cmux returns the new surface under `surface_id` (or `id`); fall back to
    // the last surface, since cmux appends new surfaces at the end.
    const list = surfacesFor(workspaceId);
    const sid = (res && (res.surface_id || res.id)) || (list.length ? list[list.length - 1].id : null);
    if (sid) openWorkspace(workspaceId, sid);
  } catch (e) {
    setWorkspaceError(String(e.message || e));
  } finally {
    busyWorkspaces.delete(workspaceId); renderWorkspaces();
  }
}

async function confirmCloseSurface(ws, surface) {
  if (surfacesFor(ws.id).length <= 1) { setWorkspaceError('Cannot close the last surface.'); return; }
  const ok = await confirmModal({ title: 'Close surface?', body: `This closes ${surface.title} in cmux.`, confirmText: `Close ${surface.title}`, danger: true });
  if (!ok) return;
  try {
    await rpc('surface.close', { workspace_id: ws.id, surface_id: surface.id });
    if (currentSurfaceId === surface.id) {
      try { await rpc('surface.unsubscribe', { surface_id: surface.id }); } catch {}
      currentSurfaceId = null;
    }
    await refreshSurfaces(ws.id);
  } catch (e) {
    setWorkspaceError(String(e.message || e));
  }
}

function openWorkspace(workspaceId, surfaceId) {
  currentWorkspaceId = workspaceId;
  markWorkspaceSeen(workspaceId);
  requestedSurfaceId = surfaceId || null;
  switchTab('active');
}

function setWorkspaceError(msg) {
  const box = $('#workspace-error');
  if (!msg) { box.classList.add('hidden'); return; }
  box.classList.remove('hidden');
  box.querySelector('.msg').textContent = msg;
}

// ============================================================
//  ACTIVE TAB (terminal)
// ============================================================
function renderActiveHeader() {
  const ws = workspaces.find(w => w.id === currentWorkspaceId);
  $('#active-workspace-name').textContent = ws ? ws.name : 'no workspace';
}

function renderSurfaceBar() {
  const bar = $('#surface-bar');
  bar.innerHTML = '';
  const ws = workspaces.find(w => w.id === currentWorkspaceId);
  if (!ws) return;
  const surfaces = surfacesFor(ws.id);
  for (const s of surfaces) {
    const chip = el('div', 'surface-chip' + (s.id === currentSurfaceId ? ' selected' : ''));
    const label = el('span', 's-label', s.title);
    label.addEventListener('click', () => subscribeSurface(ws.id, s.id));
    chip.appendChild(label);
    if (surfaces.length > 1) {
      const x = el('button', 's-x', '×');
      x.addEventListener('click', e => { e.stopPropagation(); confirmCloseSurface(ws, s); });
      chip.appendChild(x);
    }
    bar.appendChild(chip);
  }
  const newChip = el('div', 'new-surface-chip' + (busyWorkspaces.has(ws.id) ? ' busy' : ''), busyWorkspaces.has(ws.id) ? '…' : '+ NEW');
  newChip.addEventListener('click', () => createSurface(ws.id));
  bar.appendChild(newChip);
}

async function subscribeSurface(workspaceId, surfaceId) {
  const ws = workspaces.find(w => w.id === workspaceId);
  if (!ws) return;
  const surface = surfacesFor(workspaceId).find(s => s.id === surfaceId);
  if (!surface) return;

  if (currentSurfaceId && currentSurfaceId !== surfaceId) {
    try { await rpc('surface.unsubscribe', { surface_id: currentSurfaceId }); } catch {}
  }
  currentWorkspaceId = workspaceId;
  currentSurfaceId = surfaceId;
  renderActiveHeader();
  renderSurfaceBar();

  try {
    await rpc('surface.subscribe', { workspace_id: workspaceId, surface_id: surfaceId, lines: SUBSCRIPTION_LINES });
    await rpc('surface.focus', { workspace_id: workspaceId, surface_id: surfaceId });
    if (term) {
      try {
        const r = await rpc('surface.read_text', { workspace_id: workspaceId, surface_id: surfaceId, lines: SUBSCRIPTION_LINES });
        if (r && r.text) {
          const textRows = r.text.split('\n');
          surfaceRows = textRows.length;
          // Size to the surface's real width (widest row by display columns)
          // so wide TUI borders / CJK text don't wrap. Never force 80.
          const contentCols = textRows.reduce((m, r) => Math.max(m, displayWidth(r)), 0);
          if (contentCols > (surfaceCols || 0)) surfaceCols = contentCols;
          syncTerminalSize();
          term.reset();
          for (let i = 0; i < textRows.length; i++) {
            term.write(`\x1b[${i + 1};1H\x1b[2K\x1b[0m${textRows[i]}`);
          }
          pinTerminalToBottom();
        }
      } catch (e) { console.warn('read_text failed', e); }
    }
  } catch (e) {
    banner(`구독 실패: ${e.message}`, 'error');
  }
}

async function subscribeFirstSurfaceIfNeeded() {
  if (!currentWorkspaceId) return;
  if (currentSurfaceId) { await subscribeSurface(currentWorkspaceId, currentSurfaceId); return; }
  const first = surfacesFor(currentWorkspaceId)[0];
  if (first) await subscribeSurface(currentWorkspaceId, first.id);
}

function consumeRequestedSurface() {
  if (!requestedSurfaceId) { subscribeFirstSurfaceIfNeeded(); return; }
  const sid = requestedSurfaceId;
  requestedSurfaceId = null;
  if (surfacesFor(currentWorkspaceId).some(s => s.id === sid)) {
    subscribeSurface(currentWorkspaceId, sid);
  } else {
    subscribeFirstSurfaceIfNeeded();
  }
}

function showInputFeedback(msg, isError) {
  const box = $('#input-feedback');
  if (!msg) { box.classList.add('hidden'); return; }
  box.classList.remove('hidden');
  box.classList.toggle('error', !!isError);
  box.textContent = msg;
  clearTimeout(showInputFeedback._t);
  showInputFeedback._t = setTimeout(() => box.classList.add('hidden'), 2500);
}

// ---- drawer (pick any surface) ----
function openDrawer() { $('#drawer').classList.remove('hidden'); }
function closeDrawer() { $('#drawer').classList.add('hidden'); }
function renderDrawer() {
  const list = $('#drawer-list');
  list.innerHTML = '';
  if (workspaces.length === 0) { list.appendChild(el('div', 'muted', 'no workspaces')); return; }
  for (const ws of workspaces) {
    const block = el('div', 'drawer-ws');
    block.appendChild(el('div', 'drawer-ws-name', ws.name));
    const surfaces = surfacesFor(ws.id);
    if (surfaces.length === 0) {
      block.appendChild(el('div', 'muted', '(no surfaces)'));
    }
    for (const s of surfaces) {
      const row = el('div', 'drawer-surface');
      row.addEventListener('click', () => {
        closeDrawer();
        openWorkspace(ws.id, s.id);
      });
      row.appendChild(el('span', 'play', '▶'));
      row.appendChild(el('span', 's-title', s.title));
      block.appendChild(row);
    }
    list.appendChild(block);
  }
}

// ============================================================
//  INBOX TAB
// ============================================================
function renderInbox() {
  const list = $('#inbox-list');
  const empty = $('#inbox-empty');
  $('#inbox-count').textContent = `[${notifications.length}]`;
  list.innerHTML = '';
  empty.classList.toggle('hidden', notifications.length > 0);
  for (const n of notifications) {
    const item = el('div', 'inbox-item');
    item.addEventListener('click', () => openNotification(n));
    const head = el('div', 'ii-head');
    head.appendChild(el('span', 'ii-mark', '›'));
    head.appendChild(el('span', 'ii-title', n.title));
    item.appendChild(head);
    if (n.subtitle) item.appendChild(el('div', 'ii-sub', n.subtitle));
    item.appendChild(el('div', 'ii-body', n.body));
    item.appendChild(el('div', 'ii-time', new Date(n.ts * 1000).toLocaleString()));
    list.appendChild(item);
  }
}

function renderInboxBadge() {
  const badge = $('#inbox-badge');
  const c = unreadCount();
  if (c > 0) {
    badge.classList.remove('hidden');
    badge.textContent = c > 99 ? '99+' : String(c);
  } else {
    badge.classList.add('hidden');
  }
}

function openNotification(n) {
  if (workspaces.some(w => w.id === n.workspaceId)) {
    openWorkspace(n.workspaceId, n.surfaceId || null);
  } else {
    switchTab('inbox');
    banner('이 알림의 워크스페이스를 찾을 수 없습니다.', 'error');
  }
}

// ============================================================
//  SETTINGS TAB
// ============================================================
function renderSettings() {
  $('#set-endpoint').textContent = `${HOST}:${PORT}`;
  $('#set-status').textContent = connection;
  $('#set-device').textContent = getDeviceId() || '—';
  $('#set-battery').textContent = batteryDisplay();
  $('#set-power').textContent = battery.state || (battery.powerSource || '--');
}

function batteryDisplay() {
  if (!battery.available) return (battery.powerSource === 'AC Power') ? 'AC' : '--';
  const pct = Math.round(battery.percent);
  return battery.isCharging ? `${pct}% ↯` : `${pct}%`;
}

async function refreshBattery() {
  try {
    const r = await rpc('host.battery');
    if (r) {
      battery = {
        available: !!r.available,
        percent: typeof r.percent === 'number' ? Math.max(0, Math.min(100, r.percent)) : null,
        state: r.state || null,
        isCharging: r.is_charging != null ? r.is_charging : (r.isCharging != null ? r.isCharging : null),
        powerSource: r.power_source || r.powerSource || null,
      };
    }
  } catch { battery = { ...battery, available: false }; }
  renderBatteryBadges();
  renderSettings();
}

function renderBatteryBadges() {
  const txt = batteryDisplay();
  $('#battery').textContent = txt;
  const ab = $('#active-battery');
  ab.textContent = txt;
  ab.classList.toggle('on', !!battery.available);
}

// ============================================================
//  UI HELPERS
// ============================================================
function setStatus(s) {
  connection = s;
  const statusEl = $('#status');
  statusEl.textContent = s;
  statusEl.className = 'status ' + s;
  // mirror into workspaces tab conn dot + settings
  const dot = $('#ws-conn-dot');
  dot.className = 'dot ' + (s === 'connected' ? 'connected' : s === 'connecting' ? 'connecting' : 'disconnected');
  const map = { connected: 'relay connected', connecting: 'connecting…', disconnected: 'offline' };
  $('#ws-conn-text').textContent = map[s] || s;
  renderSettings();
}

function setConnError(msg) {
  const dot = $('#ws-conn-dot');
  dot.className = 'dot error';
  $('#ws-conn-text').textContent = 'needs attention';
  banner(msg, 'error');
}

let bannerTimer = null;
function banner(msg, kind) {
  const box = $('#banner');
  box.textContent = msg;
  box.className = 'banner' + (kind ? ' ' + kind : '');
  if (bannerTimer) clearTimeout(bannerTimer);
  bannerTimer = setTimeout(() => { box.className = 'banner hidden'; }, 3500);
}

// ============================================================
//  MODAL
// ============================================================
let modalResolver = null;
function promptModal({ title, label, confirmText = 'OK', placeholder = '', initial = '' }) {
  return new Promise(resolve => {
    modalResolver = resolve;
    $('#modal-title').textContent = title;
    $('#modal-body').textContent = label || '';
    const input = $('#modal-input');
    input.classList.remove('hidden');
    input.placeholder = placeholder;
    input.value = initial;
    $('#modal-confirm').textContent = confirmText;
    $('#modal-confirm').className = 'modal-btn primary';
    $('#modal').classList.remove('hidden');
    setTimeout(() => { input.focus(); input.select(); }, 0);
  });
}
function confirmModal({ title, body, confirmText = 'OK', danger = false }) {
  return new Promise(resolve => {
    modalResolver = resolve;
    $('#modal-title').textContent = title;
    $('#modal-body').textContent = body;
    $('#modal-input').classList.add('hidden');
    $('#modal-confirm').textContent = confirmText;
    $('#modal-confirm').className = 'modal-btn ' + (danger ? 'danger' : 'primary');
    $('#modal').classList.remove('hidden');
  });
}
function closeModal(result) {
  $('#modal').classList.add('hidden');
  const r = modalResolver; modalResolver = null;
  if (r) r(result);
}

// ============================================================
//  EVENT WIRING
// ============================================================
function wireEvents() {
  // tabs
  $$('#tabbar .tab').forEach(t => t.addEventListener('click', () => switchTab(t.dataset.tab)));

  // workspaces tab
  $('#new-workspace-btn').addEventListener('click', createWorkspace);
  $('#workspace-search').addEventListener('input', renderWorkspaces);

  // active tab
  $('#active-back').addEventListener('click', () => switchTab('workspaces'));
  $('#active-close').addEventListener('click', () => switchTab('workspaces'));
  $('#active-drawer-btn').addEventListener('click', openDrawer);
  $('#drawer-close').addEventListener('click', closeDrawer);
  $('#drawer').addEventListener('click', e => { if (e.target.id === 'drawer') closeDrawer(); });
  $('#active-battery').addEventListener('click', () => refreshBattery());
  $('#scroll-bottom-btn').addEventListener('click', pinTerminalToBottom);

  // command composer
  const cmd = $('#command-input');
  cmd.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); submitCommand(cmd.value); cmd.value = ''; }
  });
  $('#enter-btn').addEventListener('click', () => { submitCommand(cmd.value); cmd.value = ''; });
  $('#input-mode-btn').addEventListener('click', toggleInputMode);
  $('#key-backspace').addEventListener('click', () => sendKey('backspace'));
  $('#key-paste').addEventListener('click', pasteClipboard);
  $('#key-attach').addEventListener('click', () => $('#file-input').click());
  $('#file-input').addEventListener('change', e => attachFile(e.target.files[0]));

  // keypad (data-key + data-special)
  $$('#accessory .keypad-grid button').forEach(btn => {
    btn.addEventListener('click', () => {
      const k = btn.dataset.key;
      if (k) { sendKey(k); return; }
      const s = btn.dataset.special;
      if (s === 'ok') { sendText('OK'); sendKey('enter'); }
      else if (s === 'slash') sendSymbol('/');
      else if (s === 'dollar') sendSymbol('$');
      else if (s === 'slashnew') sendText('/new');
    });
  });

  // settings
  $('#reconnect-btn').addEventListener('click', reconnect);
  $('#refresh-battery-btn').addEventListener('click', () => refreshBattery());
  $('#unpair-btn').addEventListener('click', unpair);

  // modal
  $('#modal-cancel').addEventListener('click', () => closeModal(null));
  $('#modal-confirm').addEventListener('click', () => {
    const input = $('#modal-input');
    if (!input.classList.contains('hidden')) closeModal(input.value);
    else closeModal(true);
  });
  $('#modal-input').addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); $('#modal-confirm').click(); }
  });
  $('#modal').addEventListener('click', e => { if (e.target.id === 'modal') closeModal(null); });
}

let liveInputMode = false;
function toggleInputMode() {
  liveInputMode = !liveInputMode;
  const btn = $('#input-mode-btn');
  btn.textContent = liveInputMode ? 'LIVE' : 'CMD';
  btn.classList.toggle('live', liveInputMode);
  const input = $('#command-input');
  if (liveInputMode) {
    input.placeholder = '입력하면 바로 전송됩니다…';
    input.value = '';
  } else {
    input.placeholder = 'type a command…';
  }
}

function pasteClipboard() {
  navigator.clipboard && navigator.clipboard.readText().then(t => {
    const input = $('#command-input');
    input.value = (input.value + (input.value && !input.value.endsWith(' ') ? ' ' : '') + t);
    input.focus();
  }).catch(() => banner('클립보드 접근이 거부되었습니다.', 'error'));
}
function appendPathToDraft(path) {
  const input = $('#command-input');
  if (!input.value || input.value.endsWith(' ') || input.value.endsWith('\n')) input.value += path;
  else input.value += ' ' + path;
  input.focus();
}

async function attachFile(file) {
  // Mirrors iOS attachPhoto: upload via file.upload RPC and append the
  // returned path to the command draft. Scales images down first to keep
  // the base64 payload reasonable.
  if (!file) return;
  const input = $('#command-input');
  input.disabled = true;
  showInputFeedback('Uploading…', false);
  try {
    const { data, mime, name } = await prepareAttachment(file);
    const res = await rpc('file.upload', {
      filename: name,
      mime_type: mime,
      data_base64: data,
    });
    const path = (res && (res.path || res.filename)) || name;
    appendPathToDraft(path);
    showInputFeedback(`Attached ${name}`, false);
  } catch (e) {
    showInputFeedback(String(e.message || e), true);
  } finally {
    input.disabled = false;
    $('#file-input').value = '';
  }
}

function prepareAttachment(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error('file read failed'));
    reader.onload = () => {
      const dataUrl = reader.result;
      const base64 = dataUrl.split(',')[1] || '';
      if (file.type.startsWith('image/')) {
        // Downscale large images via a canvas (max 2048px, JPEG) to match iOS.
        const img = new Image();
        img.onload = () => {
          const maxDim = 2048;
          const scale = Math.min(1, maxDim / Math.max(img.width, img.height));
          const canvas = document.createElement('canvas');
          canvas.width = Math.round(img.width * scale);
          canvas.height = Math.round(img.height * scale);
          canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
          const jpeg = canvas.toDataURL('image/jpeg', 0.78).split(',')[1] || '';
          resolve({ data: jpeg, mime: 'image/jpeg', name: `web-image-${Date.now()}.jpg` });
        };
        img.onerror = () => resolve({ data: base64, mime: file.type, name: file.name });
        img.src = dataUrl;
      } else {
        resolve({ data: base64, mime: file.type || 'application/octet-stream', name: file.name });
      }
    };
    reader.readAsDataURL(file);
  });
}

function sendSymbol(sym) {
  if (liveInputMode) sendText(sym);
  else { const input = $('#command-input'); input.value += sym; }
}

async function reconnect() {
  if (ws) { try { ws.close(); } catch {} ws = null; }
  pending.clear();
  reconnectDelay = 1000;
  setStatus('connecting');
  try { await ensureRegistered(); connect(); }
  catch (e) { setStatus('disconnected'); scheduleReconnect(); }
}

async function unpair() {
  const ok = await confirmModal({ title: 'Unpair this device?', body: '토큰과 기기 ID를 삭제하고 다시 등록합니다.', confirmText: 'Unpair', danger: true });
  if (!ok) return;
  localStorage.removeItem('cmux_bearer');
  localStorage.removeItem('cmux_device_id');
  if (ws) { try { ws.close(); } catch {} ws = null; }
  notifications = []; readNotifIds = new Set();
  renderInbox(); renderInboxBadge();
  reconnect();
}

// ============================================================
//  BOOT
// ============================================================
wireEvents();
renderInbox();
renderInboxBadge();
renderSettings();
ensureRegistered()
  .then(() => { connect(); })
  .catch(e => console.error('boot', e));
