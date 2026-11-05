// Player window (replaces mpv). Opened by the list page as a popup
// (player.html?id=…&start=…), or embedded in it as a frame when the "inline"
// option is on, and reused for later plays via postMessage.
//
// Plays the file directly when the browser can, otherwise asks the server to
// remux or transcode it to fragmented MP4 on the fly. Those streams have no
// byte ranges, so every seek restarts the stream at the new offset (browsers
// — Firefox in particular — stall when asked to seek inside such a stream,
// even within what they've buffered). The custom seek bar always shows the
// file's full timeline.
import { $, api, store } from './util.js';
import { playerOptions, savePlayerOptions } from './options.js';
import { playbackChain } from './playmode.js';

const video = () => $('video');

let opts = playerOptions();
let item = null;
let modes = [];
let mode = '';
let offset = 0;          // stream start offset (seconds) for remux/transcode
let pendingSeek = null;  // direct mode: seek once metadata is in
let audio = null;        // { ctx, gain } once Web Audio boost is needed
let autoMuted = false;   // muted only because autoplay with sound was refused
let rotation = 0;        // client-side rotation in degrees: 0, 90, 180, 270

// Running inside the list page (inline option) rather than a pop-up.
const embedded = window.parent !== window;

const fmt = (t) => {
  if (!isFinite(t) || t < 0) t = 0;
  t = Math.floor(t);
  const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
  return (h ? h + ':' + String(m).padStart(2, '0') : m) + ':' + String(s).padStart(2, '0');
};

// --- talking to the list window ---------------------------------------------

function tellList(msg) {
  try {
    const list = embedded ? window.parent : window.opener;
    if (list && !list.closed) {
      list.postMessage(msg, location.origin);
      return true;
    }
  } catch { /* opener navigated away */ }
  return false;
}

window.addEventListener('message', (e) => {
  if (e.origin !== location.origin || !e.data) return;
  if (e.data.type === 'play') openItem(e.data.id, e.data.start);
  if (e.data.type === 'osd') osd(e.data.text);
});

// --- playback ------------------------------------------------------------------

function duration() {
  const v = video();
  if (mode === 'direct' && isFinite(v.duration) && v.duration > 0) return v.duration;
  return item?.duration || 0;
}
const position = () => (mode === 'direct' ? 0 : offset) + video().currentTime;

function startPlayback() {
  const v = video();
  v.play().catch((err) => {
    if (err.name !== 'NotAllowedError') return;
    // The browser refused autoplay with sound in this window: play muted
    // rather than not at all, and unmute on the first click / key press.
    autoMuted = true;
    v.muted = true;
    v.play().catch(() => {});
    osd('Autoplay with sound was blocked — click or press any key to unmute', 5000);
  });
}

let loadSeq = 0;
async function load(start, { paused = false } = {}) {
  const v = video();
  const seq = ++loadSeq;
  start = Math.max(0, Math.min(start || 0, Math.max(0, duration() - 1)));
  let streamMode = mode;
  if (mode === 'remux' && start > 0) {
    if ((item.codec || '').toLowerCase() === 'hevc') {
      // HEVC is often open-GOP: mid-file keyframes are CRA frames whose
      // leading pictures reference earlier ones, and browsers (Firefox)
      // can't start decoding a copied stream there. Transcode from the
      // seek point instead — also frame-accurate.
      streamMode = 'transcode';
    } else {
      // A stream copy can only start on a keyframe; start exactly there so
      // the re-encoded audio lines up (and the shown time is exact).
      const k = await api(`/api/media/${item.id}/keyframe?t=${start.toFixed(3)}`).catch(() => null);
      if (seq !== loadSeq) return; // superseded by a newer seek
      if (k && k.t >= 0) start = k.t;
    }
  }
  if (mode === 'direct') {
    offset = 0;
    pendingSeek = start > 0 ? start : null;
    v.src = `/api/media/${item.id}/file`;
  } else {
    offset = start;
    pendingSeek = null;
    v.src = `/api/media/${item.id}/stream?mode=${streamMode}&start=${start.toFixed(3)}`;
  }
  $('player-mode').textContent = streamMode;
  applyOptions();
  if (!paused) startPlayback();
}

function fallback(reason) {
  const i = modes.indexOf(mode);
  if (i < 0 || i + 1 >= modes.length) {
    osd('Cannot play this file' + (reason ? ': ' + reason : ''), 6000);
    return;
  }
  const at = position();
  mode = modes[i + 1];
  console.info(`player: ${reason}; falling back to ${mode}`);
  load(at);
}

async function openItem(id, startPercent) {
  clearTimeout(keySeekTimer);
  keySeekTarget = null;
  let it;
  try {
    it = await api(`/api/media/${id}`);
  } catch (e) {
    osd('Cannot load media ' + id + ': ' + e.message, 6000);
    return;
  }
  item = it;
  opts = playerOptions();
  modes = playbackChain(it);
  mode = modes[0];
  // The " — videoindex player" suffix is what "videoindex firefox-setup"
  // keys on to hide Firefox's address bar in this window.
  document.title = it.filename.split('/').pop() + ' — videoindex player';
  $('player-title').textContent = it.filename;
  rotation = (store('rotation') || {})[it.id] || 0;
  applyRotation();
  load(startPercent ? (it.duration || 0) * startPercent / 100 : 0);
  window.focus();
  poke();
}

function closePlayer() {
  clearTimeout(keySeekTimer);
  keySeekTarget = null;
  const v = video();
  v.pause();
  v.removeAttribute('src');
  v.load(); // aborts the request, which also stops any server-side ffmpeg
  item = null;
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  tellList({ type: 'closed' });
  if (embedded) return; // the list page hides the frame
  window.close();
  // Only reached when the browser won't let us close (window not opened by script).
  osd('Close this window to return to the list', 4000);
}

let keySeekTimer = 0;
let keySeekTarget = null;

function seekTo(t, { fast = false } = {}) {
  if (!item) return;
  const v = video();
  t = Math.max(0, Math.min(t, duration() - 0.5));
  if (mode === 'direct') {
    if (fast && typeof v.fastSeek === 'function') {
      try {
        v.fastSeek(t);
      } catch {
        v.currentTime = t;
      }
    } else {
      v.currentTime = t;
    }
  } else {
    load(t, { paused: v.paused });
  }
  updateBar();
}

function queueRelativeSeek(delta) {
  if (!item) return;
  const d = duration();
  const base = keySeekTarget !== null ? keySeekTarget : position();
  keySeekTarget = Math.max(0, Math.min(base + delta, d - 0.5));
  osd(fmt(keySeekTarget) + ' / ' + fmt(d));
  updateBar();
  clearTimeout(keySeekTimer);
  keySeekTimer = setTimeout(() => {
    const target = keySeekTarget;
    keySeekTarget = null;
    seekTo(target, { fast: true });
  }, 40);
}

// --- rotation ------------------------------------------------------------------

// Rotation is purely visual (a CSS transform), remembered per file. For a
// quarter turn the element is laid out with the window's width and height
// swapped, so object-fit: contain still fits the rotated picture.
function applyRotation() {
  const v = video();
  const quarter = rotation % 180 !== 0;
  v.classList.toggle('rotated', quarter);
  if (quarter) {
    const p = $('player');
    v.style.width = p.clientHeight + 'px';
    v.style.height = p.clientWidth + 'px';
    v.style.transform = `translate(-50%, -50%) rotate(${rotation}deg)`;
  } else {
    v.style.width = v.style.height = '';
    v.style.transform = rotation ? `rotate(${rotation}deg)` : '';
  }
  $('pl-rotate').classList.toggle('on', rotation !== 0);
}

function rotate(delta) {
  rotation = (rotation + delta + 360) % 360;
  applyRotation();
  if (item) {
    const saved = store('rotation') || {};
    if (rotation) saved[item.id] = rotation; else delete saved[item.id];
    store('rotation', saved);
  }
  osd(`Rotation ${rotation}°`);
}

// --- volume / options ------------------------------------------------------

function ensureAudioGraph() {
  if (audio) return audio;
  try {
    const ac = new AudioContext();
    const src = ac.createMediaElementSource(video());
    const gain = ac.createGain();
    src.connect(gain).connect(ac.destination);
    audio = { ctx: ac, gain };
  } catch (e) {
    console.warn('volume boost unavailable', e);
    audio = { ctx: null, gain: null };
  }
  return audio;
}

function applyOptions() {
  const v = video();
  const maxVol = opts.boost ? 1000 : 100;
  opts.volume = Math.max(0, Math.min(opts.volume, maxVol));
  v.volume = Math.min(opts.volume, 100) / 100;
  if (opts.volume > 100 || audio) {
    const a = ensureAudioGraph();
    if (a.gain) {
      a.gain.gain.value = Math.max(1, opts.volume / 100);
      if (a.ctx.state === 'suspended') a.ctx.resume();
    }
  }
  v.muted = opts.mute || opts.noAudio || autoMuted;
  v.playbackRate = opts.speed;
  const vol = $('pl-vol');
  vol.max = maxVol;
  vol.value = opts.volume;
  $('pl-vol-label').textContent = opts.volume + '%';
  $('pl-mute').textContent = v.muted ? '🔇' : '🔊';
  $('pl-speed').value = String(opts.speed);
  if ($('pl-speed').value !== String(opts.speed)) {
    // speed not in the dropdown (e.g. 1.1×): add it
    $('pl-speed').add(new Option(opts.speed + '×', String(opts.speed)));
    $('pl-speed').value = String(opts.speed);
  }
  $('pl-loop').classList.toggle('on', opts.loop);
}

function setOpt(key, value, message) {
  opts[key] = value;
  savePlayerOptions(opts);
  applyOptions();
  if (message) osd(message);
}

function unAutoMute() {
  if (!autoMuted) return;
  autoMuted = false;
  applyOptions();
}

// --- UI ----------------------------------------------------------------------

let osdTimer = 0;
function osd(text, ms = 1200) {
  const el = $('player-osd');
  el.textContent = text;
  el.classList.add('show');
  clearTimeout(osdTimer);
  osdTimer = setTimeout(() => el.classList.remove('show'), ms);
}

let idleTimer = 0;
function poke() {
  $('player').classList.remove('idle');
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => { if (!video().paused) $('player').classList.add('idle'); }, 2500);
}

function updateBar() {
  const v = video();
  const d = duration();
  const p = keySeekTarget !== null ? keySeekTarget : position();
  $('pl-time').textContent = fmt(p);
  $('pl-dur').textContent = fmt(d);
  $('pl-fill').style.width = d ? (p / d) * 100 + '%' : '0';
  let bufEnd = 0;
  for (let i = 0; i < v.buffered.length; i++) {
    if (v.buffered.start(i) <= v.currentTime + 1) bufEnd = Math.max(bufEnd, v.buffered.end(i));
  }
  const b = (mode === 'direct' ? 0 : offset) + bufEnd;
  $('pl-buf').style.width = d ? Math.min(100, (b / d) * 100) + '%' : '0';
  $('pl-play').textContent = v.paused ? '▶' : '❚❚';
}

function seekFromEvent(e) {
  const r = $('pl-seek').getBoundingClientRect();
  return Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * duration();
}

// Next / previous row of the list window's current query.
function playNeighbor(delta) {
  if (!item) return;
  if (!tellList({ type: 'neighbor', id: item.id, delta })) osd('The list window is closed');
}

function togglePause() {
  const v = video();
  if (v.paused) v.play().catch(() => {}); else v.pause();
  osd(v.paused ? 'Paused' : 'Play');
}

function toggleFullscreen() {
  if (document.fullscreenElement) document.exitFullscreen();
  else $('player').requestFullscreen?.();
}

function frameStep(dir) {
  // Only meaningful (and safe) on a range-seekable file.
  if (mode !== 'direct') { osd('Frame stepping needs direct playback'); return; }
  const v = video();
  v.pause();
  v.currentTime = Math.max(0, v.currentTime + dir / 30);
}

function onKey(e) {
  unAutoMute();
  if (e.target.tagName === 'SELECT' || (e.target.tagName === 'INPUT' && e.target.type !== 'range')) return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const p = position();
  const speeds = (f) => {
    const s = Math.round(Math.max(0.25, Math.min(4, opts.speed * f)) * 100) / 100;
    setOpt('speed', s, `Speed ${s}×`);
  };
  const volStep = (d) => { setOpt('volume', opts.volume + d); osd(`Volume ${opts.volume}%`); };
  const actions = {
    ' ': togglePause, k: togglePause, p: togglePause,
    ArrowLeft: () => queueRelativeSeek(-(e.shiftKey ? 1 : 5)),
    ArrowRight: () => queueRelativeSeek(e.shiftKey ? 1 : 5),
    ArrowUp: () => queueRelativeSeek(60),
    ArrowDown: () => queueRelativeSeek(-60),
    PageUp: () => queueRelativeSeek(duration() / 10),
    PageDown: () => queueRelativeSeek(-duration() / 10),
    Home: () => {
      clearTimeout(keySeekTimer);
      keySeekTarget = null;
      seekTo(0, { fast: true });
    },
    '9': () => volStep(-2), '/': () => volStep(-2),
    '0': () => volStep(2), '*': () => volStep(2),
    m: () => setOpt('mute', !opts.mute, opts.mute ? 'Unmuted' : 'Muted'),
    f: toggleFullscreen,
    '[': () => speeds(1 / 1.1), ']': () => speeds(1.1),
    '{': () => speeds(0.5), '}': () => speeds(2),
    Backspace: () => setOpt('speed', 1, 'Speed 1×'),
    l: () => setOpt('loop', !opts.loop, opts.loop ? 'Loop off' : 'Loop on'),
    L: () => setOpt('loop', !opts.loop, opts.loop ? 'Loop off' : 'Loop on'),
    n: () => playNeighbor(1), Enter: () => playNeighbor(1),
    N: () => playNeighbor(-1),
    '.': () => frameStep(1),
    ',': () => frameStep(-1),
    r: () => rotate(90),
    R: () => rotate(-90),
    o: () => osd(`${fmt(p)} / ${fmt(duration())}  ·  ${mode}`, 2000),
    q: closePlayer, Escape: closePlayer,
  };
  const fn = actions[e.key];
  if (fn) {
    e.preventDefault();
    fn();
    poke();
    updateBar();
  }
}

function init() {
  const v = video();
  v.addEventListener('timeupdate', updateBar);
  v.addEventListener('progress', updateBar);
  v.addEventListener('play', updateBar);
  v.addEventListener('pause', () => { updateBar(); poke(); });
  v.addEventListener('loadedmetadata', () => {
    if (!item) return;
    if (item.width && v.videoWidth === 0) { fallback('no decodable video track'); return; }
    if (pendingSeek != null) { v.currentTime = pendingSeek; pendingSeek = null; }
    v.playbackRate = opts.speed;
    updateBar();
  });
  v.addEventListener('error', () => {
    if (!item || !v.getAttribute('src')) return;
    fallback(v.error?.message || 'media error ' + v.error?.code);
  });
  v.addEventListener('ended', () => {
    if (!item) return;
    if (opts.loop) { seekTo(0); v.play().catch(() => {}); return; }
    if (opts.autoNext) { playNeighbor(1); return; }
    if (!opts.keepOpen) closePlayer();
  });
  v.addEventListener('click', togglePause);
  v.addEventListener('dblclick', toggleFullscreen);

  document.addEventListener('keydown', onKey);
  document.addEventListener('pointerdown', unAutoMute, true);
  $('player').addEventListener('mousemove', poke);
  $('player-close').addEventListener('click', closePlayer);
  $('pl-play').addEventListener('click', togglePause);
  $('pl-mute').addEventListener('click', () => setOpt('mute', !opts.mute));
  $('pl-loop').addEventListener('click', () => setOpt('loop', !opts.loop));
  $('pl-fs').addEventListener('click', toggleFullscreen);
  $('pl-rotate').addEventListener('click', (e) => rotate(e.shiftKey ? -90 : 90));
  new ResizeObserver(applyRotation).observe($('player'));
  $('pl-vol').addEventListener('input', (e) => setOpt('volume', +e.target.value));
  $('pl-speed').addEventListener('change', (e) => { setOpt('speed', +e.target.value); e.target.blur(); });

  const seek = $('pl-seek');
  let dragging = false;
  seek.addEventListener('pointerdown', (e) => { dragging = true; seek.setPointerCapture(e.pointerId); });
  seek.addEventListener('pointermove', (e) => {
    const t = seekFromEvent(e);
    const hover = $('pl-hover');
    hover.textContent = fmt(t);
    hover.style.left = (e.clientX - seek.getBoundingClientRect().left) + 'px';
    if (dragging) $('pl-fill').style.width = (t / duration()) * 100 + '%';
  });
  seek.addEventListener('pointerup', (e) => {
    if (dragging) {
      dragging = false;
      clearTimeout(keySeekTimer);
      keySeekTarget = null;
      seekTo(seekFromEvent(e), { fast: true });
    }
  });

  const q = new URLSearchParams(location.search);
  if (q.get('id')) openItem(+q.get('id'), +q.get('start') || 0);
}

init();
