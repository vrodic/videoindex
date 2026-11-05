// videoindex web UI — main module: media table, search / condition boxes,
// keyboard handling. Other panels live in their own modules and get the
// shared `ctx` object passed to their init().
import { initPreview, refreshPreview } from './preview.js';
import { initActors, refreshMediaActors } from './actors.js';
import { closeModal, modalOpen } from './modal.js';
import { openWordCloud } from './wordcloud.js';
import { openDashboard } from './dashboard.js';
import { openScan } from './scan.js';
import { openOptions, openHelp } from './dialogs.js';
import { playerOptions } from './options.js';
import { playNeed, PLAY_NEED_LABEL, PLAY_NEED_TITLE, PLAY_NEED_RANK } from './playmode.js';
import { $, esc, store, api } from './util.js';

const DEFAULT_CONDITIONS = [
  'AND like > 2 ORDER BY viewed_time, random() -- (Default: Highly liked, oldest viewed first)',
  'ORDER BY view_count ASC, file_size DESC -- (Least viewed first)',
  'ORDER BY view_count DESC -- (Most viewed)',
  'ORDER BY file_size DESC -- (Largest files)',
  'ORDER BY viewed_time DESC -- (Recently viewed)',
  'ORDER BY id DESC -- (Recently added)',
  'AND (like IS NULL OR like >= 0) ORDER BY random() -- (Unrated & liked, shuffled)',
  'AND like > 0 ORDER BY like DESC -- (Liked videos)',
];

const COLUMNS = [
  { id: 'select', title: '✓', cls: 'c' },
  { id: 'id', title: 'ID', cls: 'n' },
  { id: 'filename', title: 'Filename' },
  { id: 'need', title: 'Play' },
  { id: 'views', title: 'Views', cls: 'n' },
  { id: 'like', title: 'Likes', cls: 'n' },
  { id: 'sizeMB', title: 'Size (MB)', cls: 'n' },
  { id: 'viewed', title: 'Last Viewed' },
  { id: 'width', title: 'Width', cls: 'n' },
  { id: 'density', title: 'Density', cls: 'n' },
];

const ROW_H = 26;

// Search, condition, sort, and selected ID come from the URL first (so a link
// reopens the same view), then from what was last used in this browser.
const urlParams = new URLSearchParams(location.search);

function parseSort(str) {
  if (!str) return null;
  const [key, dir] = str.split(':');
  if (!key || !COLUMNS.some((c) => c.id === key && c.id !== 'select')) return null;
  return { key, asc: dir !== 'desc' };
}

function parseInitialId() {
  const param = urlParams.get('id');
  if (param != null) {
    const n = Number(param);
    if (!Number.isNaN(n)) return n;
  }
  const saved = store('selectedId');
  if (saved != null) {
    const n = Number(saved);
    if (!Number.isNaN(n)) return n;
  }
  return null;
}

const initialSort = parseSort(urlParams.get('sort')) ?? store('sort') ?? null;
let targetInitialId = parseInitialId();

export const state = {
  items: [],
  sel: -1,
  search: urlParams.get('search') ?? store('search') ?? '',
  cond: urlParams.get('cond') ?? store('cond') ?? DEFAULT_CONDITIONS[0],
  sort: initialSort,        // { key, asc }
  checked: new Set(),       // ids ticked in the ✓ column
  session: new Set(),       // ids played this session
  missing: new Set(),       // ids whose file is gone
  lastQueryOk: false,
  condSaved: true,          // current condition already in history (or chosen from it)
  config: { allowDelete: true },
};

// ctx is what other modules use to talk back to the main view.
export const ctx = {
  state, api,
  current: () => state.items[state.sel] ?? null,
  reload, select, selectById, renderRows, setCondition, setSearch, markMissing,
  focusTable: () => $('table').focus({ preventScroll: true }),
  play: (item, startPercent) => playItem(item, startPercent),
};

// --- loading ---------------------------------------------------------------

let loadSeq = 0;
export async function reload({ keepSelection = true } = {}) {
  const seq = ++loadSeq;
  const prevId = keepSelection ? (ctx.current()?.id ?? targetInitialId) : null;
  targetInitialId = null;
  const qs = new URLSearchParams({ search: state.search, cond: state.cond });
  saveQueryState();
  let data;
  try {
    data = await api('/api/items?' + qs);
  } catch (e) {
    data = { items: [], error: e.message };
  }
  if (seq !== loadSeq) return;
  state.items = data.items;
  for (const it of state.items) it.need = playNeed(it);
  state.checked.clear();
  state.lastQueryOk = !data.error;
  setStatus(data.error ? 'Query error: ' + data.error : `${data.items.length} item${data.items.length === 1 ? '' : 's'}`, !!data.error);
  if (state.sort) sortItems();
  let idx = prevId != null ? state.items.findIndex((it) => it.id === prevId) : -1;
  if (idx < 0 && state.items.length) idx = Math.min(Math.max(state.sel, 0), state.items.length - 1);
  if (prevId == null || idx < 0) $('tbody').scrollTop = 0;
  select(state.items.length ? idx : -1, { force: true });
}

// Mirror the current search / condition / sort / selected ID into the address bar and storage.
function saveQueryState() {
  store('search', state.search);
  store('cond', state.cond);
  if (state.sort) store('sort', state.sort);
  else store('sort', null);
  const qs = new URLSearchParams();
  if (state.search) qs.set('search', state.search);
  qs.set('cond', state.cond);
  if (state.sort) qs.set('sort', `${state.sort.key}:${state.sort.asc ? 'asc' : 'desc'}`);
  const cur = ctx.current();
  if (cur?.id != null) qs.set('id', cur.id);
  const url = location.pathname + '?' + qs + location.hash;
  if (url !== location.pathname + location.search + location.hash) history.replaceState(null, '', url);
}

function setStatus(text, error) {
  const el = $('status');
  el.textContent = text;
  el.classList.toggle('error', error);
  el.title = text;
}

// --- sorting ---------------------------------------------------------------

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
function cmp(a, b, key) {
  const x = a[key], y = b[key];
  if (key === 'filename') return collator.compare(x, y);
  if (key === 'need') return PLAY_NEED_RANK[x] - PLAY_NEED_RANK[y];
  if (x == null && y == null) return 0;
  if (x == null) return -1;   // missing values sort lowest, like the original
  if (y == null) return 1;
  return x < y ? -1 : x > y ? 1 : 0;
}

function sortItems() {
  const { key, asc } = state.sort;
  state.items.sort((a, b) => (asc ? cmp(a, b, key) : cmp(b, a, key)));
}

function onHeaderClick(col) {
  if (col.id === 'select') {
    const all = state.items.every((it) => state.checked.has(it.id));
    state.items.forEach((it) => (all ? state.checked.delete(it.id) : state.checked.add(it.id)));
    renderRows();
    return;
  }
  const id = ctx.current()?.id;
  state.sort = state.sort?.key === col.id ? { key: col.id, asc: !state.sort.asc } : { key: col.id, asc: true };
  sortItems();
  renderHeader();
  saveQueryState();
  selectById(id, { force: true });
}

function resetSort() {
  state.sort = null;
  renderHeader();
  saveQueryState();
  reload();
}

function renderHeader() {
  $('btn-reset-sort').disabled = !state.sort;
  $('thead').innerHTML = COLUMNS.map((c) => {
    const sorted = state.sort?.key === c.id;
    return `<div data-col="${c.id}" class="${c.cls || ''}${sorted ? ' sorted' + (state.sort.asc ? '' : ' desc') : ''}">${esc(c.title)}</div>`;
  }).join('');
}

// --- table rendering (virtualized) -----------------------------------------

let renderedRange = '';
function visibleRange() {
  const body = $('tbody');
  const first = Math.max(0, Math.floor(body.scrollTop / ROW_H) - 8);
  const last = Math.min(state.items.length, Math.ceil((body.scrollTop + body.clientHeight) / ROW_H) + 8);
  return [first, last];
}

export function renderRows() {
  const spacer = $('tspacer');
  spacer.style.height = state.items.length * ROW_H + 'px';
  const [first, last] = visibleRange();
  renderedRange = `${first}-${last}-${state.items.length}`;
  let html = '';
  for (let i = first; i < last; i++) {
    const it = state.items[i];
    const cls = ['trow'];
    if (i % 2) cls.push('alt');
    if (state.session.has(it.id)) cls.push('session');
    else if ((it.views ?? 0) > 0 || it.viewed) cls.push('viewed');
    if (i === state.sel) cls.push('sel');
    if (state.missing.has(it.id)) cls.push('missing');
    html += `<div class="${cls.join(' ')}" data-i="${i}" style="top:${i * ROW_H}px">` +
      `<div class="c"><input type="checkbox" tabindex="-1"${state.checked.has(it.id) ? ' checked' : ''}></div>` +
      `<div class="n">${it.id}</div>` +
      `<div title="${esc(it.filename)}">${esc(it.filename)}</div>` +
      `<div class="need need-${it.need}" title="${PLAY_NEED_TITLE[it.need]}">${PLAY_NEED_LABEL[it.need]}</div>` +
      `<div class="n">${it.views ?? ''}</div>` +
      `<div class="n ${likeClass(it.like)}">${it.like ?? ''}</div>` +
      `<div class="n">${it.sizeMB}</div>` +
      `<div>${esc(it.viewed ?? '')}</div>` +
      `<div class="n">${it.width ?? ''}</div>` +
      `<div class="n">${it.density ?? ''}</div>` +
      `</div>`;
  }
  spacer.innerHTML = html;
}

export function likeClass(like) {
  if (like == null) return '';
  if (like < 0) return 'like-neg';
  if (like === 0) return '';
  return 'like-' + Math.min(like, 5);
}

function scrollIntoView(i) {
  const body = $('tbody');
  const top = i * ROW_H;
  if (top < body.scrollTop) body.scrollTop = top;
  else if (top + ROW_H > body.scrollTop + body.clientHeight) body.scrollTop = top + ROW_H - body.clientHeight;
}

// --- selection ---------------------------------------------------------------

let lastSelectedId = null;
export function select(i, { force = false } = {}) {
  if (i >= state.items.length) i = state.items.length - 1;
  state.sel = i;
  if (i >= 0) scrollIntoView(i);
  // Only rebuild rows when the visible window moved; otherwise just move the
  // highlight so the row elements survive (double-click needs that).
  const [first, last] = visibleRange();
  if (force || renderedRange !== `${first}-${last}-${state.items.length}`) renderRows();
  else for (const row of $('tspacer').children) row.classList.toggle('sel', +row.dataset.i === i);
  const id = ctx.current()?.id ?? null;
  if (id !== lastSelectedId || force) {
    lastSelectedId = id;
    checkAndSaveCustomCondition();
    refreshPreview();
    refreshMediaActors();
    saveQueryState();
  }
}

export function selectById(id, opts) {
  const i = state.items.findIndex((it) => it.id === id);
  select(i >= 0 ? i : Math.min(state.sel, state.items.length - 1), opts);
}

function moveSelection(delta) {
  if (!state.items.length) return;
  const target = Math.min(Math.max((state.sel < 0 ? -1 : state.sel) + delta, 0), state.items.length - 1);
  if (target !== state.sel) select(target);
}

export function markMissing(id) {
  if (state.missing.has(id)) return;
  state.missing.add(id);
  renderRows();
}

// --- actions -------------------------------------------------------------------

// The player (player.html) runs either in its own pop-up window, sized to a
// share of the screen, or — with the "inline" option — in a frame covering
// this page. It is reused for every play (later plays are sent to it with
// postMessage).
let playerWin = null;    // the player's window: the pop-up or the frame's window
let inlineFrame = null;  // the <iframe> for inline playback, once created

function openPlayer(item, startPercent = 0) {
  return playerOptions().inline ? openInlinePlayer(item, startPercent) : openPlayerWindow(item, startPercent);
}

function openInlinePlayer(item, startPercent) {
  if (!inlineFrame) {
    inlineFrame = document.createElement('iframe');
    inlineFrame.className = 'inline-player';
    inlineFrame.title = 'Player';
    inlineFrame.allow = 'autoplay; fullscreen';
    inlineFrame.hidden = true;
    document.body.append(inlineFrame);
  }
  if (inlineFrame.hidden) {
    // Fresh load for each opening; while showing, reuse it like the pop-up.
    inlineFrame.src = `/player.html?id=${item.id}&start=${startPercent}`;
    inlineFrame.hidden = false;
  } else {
    inlineFrame.contentWindow.postMessage({ type: 'play', id: item.id, start: startPercent }, location.origin);
  }
  playerWin = inlineFrame.contentWindow;
  inlineFrame.focus();
  return true;
}

function openPlayerWindow(item, startPercent = 0) {
  if (playerWin && !playerWin.closed && playerWin !== inlineFrame?.contentWindow) {
    playerWin.postMessage({ type: 'play', id: item.id, start: startPercent }, location.origin);
    playerWin.focus();
    return true;
  }
  const f = Math.min(100, Math.max(20, playerOptions().windowSize)) / 100;
  const w = Math.round(screen.availWidth * f);
  const h = Math.round(screen.availHeight * f);
  const left = Math.round((screen.availLeft ?? 0) + (screen.availWidth - w) / 2);
  const top = Math.round((screen.availTop ?? 0) + (screen.availHeight - h) / 2);
  playerWin = window.open(`/player.html?id=${item.id}&start=${startPercent}`, 'videoindex-player',
    `popup=yes,toolbar=no,location=no,menubar=no,status=no,scrollbars=no,width=${w},height=${h},left=${left},top=${top}`);
  if (!playerWin) {
    setStatus('The player window was blocked — allow pop-ups for this site', true);
    return false;
  }
  return true;
}

// Messages from the player window: it asks for the next/previous row and
// reports when it closes.
window.addEventListener('message', (e) => {
  if (e.origin !== location.origin || !e.data) return;
  // After this page reloads, re-adopt a player window that is still open.
  if ((!playerWin || playerWin.closed) && e.source?.name === 'videoindex-player') playerWin = e.source;
  if (e.source !== playerWin) return;
  if (e.data.type === 'neighbor') {
    const i = state.items.findIndex((x) => x.id === e.data.id);
    const next = i >= 0 ? state.items[i + e.data.delta] : null;
    if (!next) {
      playerWin.postMessage({ type: 'osd', text: e.data.delta > 0 ? 'End of list' : 'Start of list' }, location.origin);
      return;
    }
    select(i + e.data.delta);
    playItem(next);
  } else if (e.data.type === 'closed') {
    if (inlineFrame && e.source === inlineFrame.contentWindow) {
      inlineFrame.hidden = true;
      inlineFrame.src = 'about:blank';
      playerWin = null;
    }
    window.focus();
    ctx.focusTable();
  }
});

function launchMpv(item, startPercent, prefix) {
  let p = prefix ? prefix.replace(/\/+$/, '') : '';
  const rel = (item.filename || '').replace(/^\/+/, '');
  const fullPath = p ? `${p}/${rel}` : rel;
  const qs = new URLSearchParams();
  qs.set('url', fullPath);
  if (startPercent && startPercent > 0) qs.set('start', `${startPercent}%`);
  qs.set('volume', '33');
  qs.set('volume-max', '1000');
  qs.set('autofit', '75%x75%');
  const uri = `mpv://play/?${qs.toString()}`;
  let link = document.getElementById('mpv-launcher');
  if (!link) {
    link = document.createElement('a');
    link.id = 'mpv-launcher';
    link.style.display = 'none';
    document.body.appendChild(link);
  }
  link.href = uri;
  link.click();
  setStatus(`Launching MPV: ${fullPath}`, false);
}

async function playItem(item, startPercent) {
  if (!item) return;
  const opts = playerOptions();
  const useMpv = opts.mpvMode === 'all' || (opts.mpvMode === 'transcode' && item.need !== 'direct');
  if (useMpv) {
    launchMpv(item, startPercent, opts.mpvPrefix);
  } else {
    if (!openPlayer(item, startPercent)) return;
  }
  try {
    const r = await api(`/api/media/${item.id}/viewed`, { method: 'POST' });
    item.views = r.views;
    item.viewed = r.viewed;
  } catch (e) { console.error(e); }
  state.session.add(item.id);
  renderRows();
}

async function like() {
  const item = ctx.current();
  if (!item) return;
  const r = await api(`/api/media/${item.id}/like`, { method: 'POST' });
  item.like = r.like;
  renderRows();
  moveSelection(1);
}

// First press records a dislike; once the value drops below -1 the server
// deletes the file (disk + DB) — the original tool's two-step guard.
async function dislikeOrDelete() {
  const item = ctx.current();
  if (!item) return;
  const r = await api(`/api/media/${item.id}/dislike`, { method: 'POST' });
  item.like = r.like;
  if (r.deleted) {
    const i = state.items.indexOf(item);
    state.items.splice(i, 1);
    setStatus(`Deleted ${item.filename} — ${state.items.length} items`, false);
    select(Math.min(i, state.items.length - 1), { force: true });
  } else {
    renderRows();
    moveSelection(1);
  }
}

// --- condition box -----------------------------------------------------------

function customConditions() { return store('customConditions') || []; }

function allConditions() {
  const out = [...DEFAULT_CONDITIONS];
  for (const c of customConditions()) if (!out.includes(c)) out.push(c);
  return out;
}

export function setCondition(cond, { fromHistory = true } = {}) {
  state.cond = cond;
  state.condSaved = fromHistory;
  $('cond').value = cond;
  if (state.sort) {
    state.sort = null;
    renderHeader();
  }
  reload();
}

export function setSearch(text) {
  $('search').value = text;
  state.search = text;
  reload();
}

// A typed condition joins the history once it has produced a successful
// query and the user moved on to browsing the results.
function checkAndSaveCustomCondition() {
  if (!state.lastQueryOk || state.condSaved) return;
  const c = state.cond.trim();
  state.condSaved = true;
  if (!c || allConditions().includes(c)) return;
  store('customConditions', [...customConditions(), c]);
}

function renderConditionList() {
  const custom = new Set(customConditions());
  $('cond-list').innerHTML = allConditions().map((c, i) =>
    `<li data-i="${i}"${c === state.cond ? ' class="active"' : ''}><span title="${esc(c)}">${esc(c)}</span>` +
    (custom.has(c) && !DEFAULT_CONDITIONS.includes(c) ? `<button data-del="${i}" title="Forget this condition">✕</button>` : '') +
    '</li>').join('');
}

function initConditionBox() {
  const input = $('cond');
  const list = $('cond-list');
  input.value = state.cond;
  let t;
  input.addEventListener('input', () => {
    clearTimeout(t);
    t = setTimeout(() => {
      state.cond = input.value;
      state.condSaved = false;
      if (state.sort) {
        state.sort = null;
        renderHeader();
      }
      reload();
    }, 250);
  });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      clearTimeout(t);
      state.cond = input.value;
      state.condSaved = false;
      if (state.sort) {
        state.sort = null;
        renderHeader();
      }
      reload();
      ctx.focusTable();
    }
    if (e.key === 'ArrowDown' && e.altKey) { toggleList(true); }
  });
  const toggleList = (show = list.hidden) => {
    if (show) renderConditionList();
    list.hidden = !show;
  };
  $('cond-toggle').addEventListener('click', () => toggleList());
  list.addEventListener('mousedown', (e) => e.preventDefault());
  list.addEventListener('click', (e) => {
    const all = allConditions();
    const del = e.target.closest('[data-del]');
    if (del) {
      const c = all[+del.dataset.del];
      store('customConditions', customConditions().filter((x) => x !== c));
      renderConditionList();
      return;
    }
    const li = e.target.closest('li');
    if (!li) return;
    toggleList(false);
    setCondition(all[+li.dataset.i]);
    ctx.focusTable();
  });
  document.addEventListener('click', (e) => { if (!e.target.closest('#cond-combo')) list.hidden = true; });
}

// --- splitter ----------------------------------------------------------------

function initSplitter() {
  const app = document.documentElement;
  const saved = store('previewWidth');
  if (saved) app.style.setProperty('--preview-w', saved + 'px');
  $('divider').addEventListener('pointerdown', (e) => {
    const div = e.currentTarget;
    div.setPointerCapture(e.pointerId);
    const move = (ev) => {
      // keep the table usable on the left, and room for both preview columns
      const w = Math.min(Math.max(window.innerWidth - ev.clientX - 12, 380), window.innerWidth - 600);
      app.style.setProperty('--preview-w', w + 'px');
      store('previewWidth', w);
    };
    const up = () => { div.removeEventListener('pointermove', move); div.removeEventListener('pointerup', up); };
    div.addEventListener('pointermove', move);
    div.addEventListener('pointerup', up);
  });
}

// --- keyboard ------------------------------------------------------------------

function pageRows() { return Math.max(1, Math.floor($('tbody').clientHeight / ROW_H) - 1); }

function onTableKey(e) {
  if (modalOpen()) return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const k = e.key;
  const handled = {
    ArrowDown: () => moveSelection(1),
    ArrowUp: () => moveSelection(-1),
    PageDown: () => moveSelection(pageRows()),
    PageUp: () => moveSelection(-pageRows()),
    Home: () => state.items.length && select(0),
    End: () => state.items.length && select(state.items.length - 1),
    Enter: () => playItem(ctx.current()),
    Delete: () => dislikeOrDelete(),
    Backspace: () => dislikeOrDelete(),
    Insert: () => like(),
    '+': () => like(),
    '=': () => like(),
    ' ': () => {
      const it = ctx.current();
      if (!it) return;
      state.checked.has(it.id) ? state.checked.delete(it.id) : state.checked.add(it.id);
      renderRows();
    },
  }[k];
  if (handled) {
    e.preventDefault();
    handled();
  }
}

function inEditable(el) {
  return el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || el.isContentEditable);
}

function onGlobalKey(e) {
  if (modalOpen()) {
    if (e.key === 'Escape') { e.preventDefault(); closeModal(); }
    return;
  }
  const mod = e.metaKey || e.ctrlKey;
  const k = e.key.toLowerCase();
  if (mod && k === 'f') { e.preventDefault(); $('search').focus(); $('search').select(); return; }
  if (mod && k === 'l') { e.preventDefault(); $('cond').focus(); $('cond').select(); return; }
  if (mod && k === 'k') { e.preventDefault(); openWordCloud(ctx); return; }
  if (e.key === 'Escape' && inEditable(document.activeElement)) {
    if (!$('cond-list').hidden) { $('cond-list').hidden = true; return; }
    ctx.focusTable();
    return;
  }
  if (mod || e.altKey || inEditable(document.activeElement)) return;
  const shortcuts = {
    '/': () => { $('search').focus(); $('search').select(); },
    c: () => { $('cond').focus(); $('cond').select(); },
    w: () => openWordCloud(ctx),
    d: () => openDashboard(ctx),
    r: () => resetSort(),
    o: () => openOptions(),
    '?': () => openHelp(),
  }[e.key];
  if (shortcuts) {
    e.preventDefault();
    shortcuts();
  }
}

// --- init ----------------------------------------------------------------------

async function init() {
  state.config = await api('/api/config').catch(() => state.config);
  renderHeader();
  $('thead').addEventListener('click', (e) => {
    const cell = e.target.closest('[data-col]');
    if (cell) onHeaderClick(COLUMNS.find((c) => c.id === cell.dataset.col));
  });
  const body = $('tbody');
  let raf = 0;
  body.addEventListener('scroll', () => { if (!raf) raf = requestAnimationFrame(() => { raf = 0; renderRows(); }); });
  new ResizeObserver(() => renderRows()).observe(body);
  body.addEventListener('mousedown', (e) => {
    const row = e.target.closest('.trow');
    if (row && e.target.type !== 'checkbox') select(+row.dataset.i);
  });
  body.addEventListener('click', (e) => {
    if (e.target.type !== 'checkbox') return;
    const id = state.items[+e.target.closest('.trow').dataset.i].id;
    e.target.checked ? state.checked.add(id) : state.checked.delete(id);
  });
  body.addEventListener('dblclick', (e) => {
    const row = e.target.closest('.trow');
    if (row) playItem(state.items[+row.dataset.i]);
  });
  $('table').addEventListener('keydown', onTableKey);
  document.addEventListener('keydown', onGlobalKey);

  let st;
  $('search').addEventListener('input', () => {
    clearTimeout(st);
    st = setTimeout(() => { state.search = $('search').value; reload(); }, 150);
  });
  $('search').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { clearTimeout(st); state.search = $('search').value; reload(); ctx.focusTable(); }
    if (e.key === 'ArrowDown') { e.preventDefault(); ctx.focusTable(); }
  });

  $('search').value = state.search;
  $('btn-reset-sort').addEventListener('click', () => { resetSort(); ctx.focusTable(); });
  $('btn-words').addEventListener('click', () => openWordCloud(ctx));
  $('btn-dashboard').addEventListener('click', () => openDashboard(ctx));
  $('btn-scan').addEventListener('click', () => openScan(ctx));
  $('btn-options').addEventListener('click', () => openOptions());
  $('btn-help').addEventListener('click', () => openHelp());

  initConditionBox();
  initSplitter();
  initPreview(ctx);
  initActors(ctx);

  const saveSelectedId = () => {
    const cur = ctx.current();
    if (cur?.id != null) store('selectedId', cur.id);
  };
  window.addEventListener('beforeunload', saveSelectedId);
  window.addEventListener('pagehide', saveSelectedId);

  await reload();
  ctx.focusTable();
}

init();
