// In-browser player (replaces mpv). Plays the file directly when the
// browser can, otherwise asks the server to remux or transcode it to
// fragmented MP4 on the fly. Transcoded streams can't be range-seeked, so
// seeking outside what's buffered restarts the stream at the new offset;
// the custom seek bar always shows the file's full timeline.
import { $, store } from './app.js';

let ctx;
const video = () => $('video');

export const DEFAULT_OPTIONS = {
  volume: 33,        // percent; up to 1000 with boost (mpv --volume-max=1000)
  boost: true,
  mute: false,
  noAudio: false,
  loop: false,
  keepOpen: false,   // stay open at the end instead of closing
  autoNext: false,   // play the next row when a video ends
  fit: '75',         // '50' | '75' | '100' | 'fullscreen'
  speed: 1,
};

export function playerOptions() {
  return { ...DEFAULT_OPTIONS, ...(store('player') || {}) };
}
export function savePlayerOptions(o) { store('player', o); }

let opts = playerOptions();
let item = null;
let modes = [];
let mode = '';
let offset = 0;          // stream start offset (seconds) for remux/transcode
let pendingSeek = null;  // direct mode: seek once metadata is in
let audio = null;        // { ctx, gain } once Web Audio boost is needed

export const playerOpen = () => !$('player').hidden;

const fmt = (t) => {
  if (!isFinite(t) || t < 0) t = 0;
  t = Math.floor(t);
  const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
  return (h ? h + ':' + String(m).padStart(2, '0') : m) + ':' + String(s).padStart(2, '0');
};

function playbackChain(it) {
  const v = video();
  const hevc = (it.codec || '').toLowerCase() === 'hevc';
  const hevcOk = !hevc || v.canPlayType('video/mp4; codecs="hvc1.1.6.L93.B0"') !== '';
  const chain = [];
  if (it.play === 'direct' && hevcOk) chain.push('direct');
  if ((it.play === 'direct' || it.play === 'remux') && hevcOk) chain.push('remux');
  chain.push('transcode');
  return chain;
}

function duration() {
  const v = video();
  if (mode === 'direct' && isFinite(v.duration) && v.duration > 0) return v.duration;
  return item?.duration || 0;
}
const position = () => (mode === 'direct' ? 0 : offset) + video().currentTime;

function load(start) {
  const v = video();
  start = Math.max(0, Math.min(start || 0, Math.max(0, duration() - 1)));
  if (mode === 'direct') {
    offset = 0;
    pendingSeek = start > 0 ? start : null;
    v.src = `/api/media/${item.id}/file`;
  } else {
    offset = start;
    pendingSeek = null;
    v.src = `/api/media/${item.id}/stream?mode=${mode}&start=${start.toFixed(2)}`;
  }
  $('player-mode').textContent = mode;
  applyOptions();
  v.play().catch(() => {});
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

export function openPlayer(it, startPercent) {
  item = it;
  opts = playerOptions();
  modes = playbackChain(it);
  mode = modes[0];
  $('player-title').textContent = it.filename;
  $('player').hidden = false;
  $('player').style.setProperty('--fit', opts.fit === 'fullscreen' ? '100%' : opts.fit + '%');
  if (opts.fit === 'fullscreen' && !document.fullscreenElement) $('player').requestFullscreen?.().catch(() => {});
  const start = startPercent ? (it.duration || 0) * startPercent / 100 : 0;
  load(start);
  poke();
}

export function closePlayer() {
  const v = video();
  v.pause();
  v.removeAttribute('src');
  v.load(); // aborts the request, which also stops any server-side ffmpeg
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  $('player').hidden = true;
  item = null;
  ctx.renderRows();
  ctx.focusTable();
}

function seekTo(t) {
  const v = video();
  t = Math.max(0, Math.min(t, duration() - 0.5));
  if (mode === 'direct') {
    v.currentTime = t;
  } else {
    // Within the part of the stream already received? Seek locally.
    const rel = t - offset;
    for (let i = 0; i < v.buffered.length; i++) {
      if (rel >= v.buffered.start(i) && rel <= v.buffered.end(i)) { v.currentTime = rel; return; }
    }
    const paused = v.paused;
    load(t);
    if (paused) v.pause();
  }
  updateBar();
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
  v.muted = opts.mute || opts.noAudio;
  v.playbackRate = opts.speed;
  const vol = $('pl-vol');
  vol.max = maxVol;
  vol.value = opts.volume;
  $('pl-vol-label').textContent = opts.volume + '%';
  $('pl-mute').textContent = v.muted ? '🔇' : '🔊';
  $('pl-speed').value = String(opts.speed);
  if ($('pl-speed').value !== String(opts.speed)) {
    // speed not in the dropdown (e.g. 1.1×): add it
    const o = new Option(opts.speed + '×', String(opts.speed));
    $('pl-speed').add(o);
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
  const p = position();
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

function playNeighbor(delta) {
  const { items } = ctx.state;
  const i = items.findIndex((x) => x.id === item?.id);
  const next = items[i + delta];
  if (!next) { osd(delta > 0 ? 'End of list' : 'Start of list'); return; }
  ctx.select(i + delta);
  ctx.play(next);
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

function onKey(e) {
  if (!playerOpen()) return;
  if (e.target.tagName === 'SELECT' || (e.target.tagName === 'INPUT' && e.target.type !== 'range')) return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const v = video();
  const p = position();
  const speeds = (f) => {
    const s = Math.round(Math.max(0.25, Math.min(4, opts.speed * f)) * 100) / 100;
    setOpt('speed', s, `Speed ${s}×`);
  };
  const volStep = (d) => { setOpt('volume', opts.volume + d); osd(`Volume ${opts.volume}%`); };
  const actions = {
    ' ': togglePause, k: togglePause, p: togglePause,
    ArrowLeft: () => seekTo(p - (e.shiftKey ? 1 : 5)),
    ArrowRight: () => seekTo(p + (e.shiftKey ? 1 : 5)),
    ArrowUp: () => seekTo(p + 60),
    ArrowDown: () => seekTo(p - 60),
    PageUp: () => seekTo(p + duration() / 10),
    PageDown: () => seekTo(p - duration() / 10),
    Home: () => seekTo(0),
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
    '.': () => { v.pause(); v.currentTime += 1 / 30; },
    ',': () => { v.pause(); v.currentTime -= 1 / 30; },
    o: () => osd(`${fmt(p)} / ${fmt(duration())}  ·  ${mode}`, 2000),
    q: closePlayer, Escape: closePlayer,
  };
  const fn = actions[e.key];
  if (fn) {
    e.preventDefault();
    e.stopPropagation();
    fn();
    poke();
    updateBar();
  }
}

export function initPlayer(c) {
  ctx = c;
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

  document.addEventListener('keydown', onKey, true);
  $('player').addEventListener('mousemove', poke);
  $('player-close').addEventListener('click', closePlayer);
  $('pl-play').addEventListener('click', togglePause);
  $('pl-mute').addEventListener('click', () => setOpt('mute', !opts.mute));
  $('pl-loop').addEventListener('click', () => setOpt('loop', !opts.loop));
  $('pl-fs').addEventListener('click', toggleFullscreen);
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
  seek.addEventListener('pointerup', (e) => { if (dragging) { dragging = false; seekTo(seekFromEvent(e)); } });
}
