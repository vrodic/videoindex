// Right-hand panel: a filmstrip of frames from the selected video (click one
// to play from there) and an "Up Next" column — the selection plus the next
// nine rows (click one to select it). Frames come from the server's on-disk
// thumbnail cache, generated with ffmpeg on first request.
import { $ } from './app.js';

const FILM_PERCENTS = [15, 30, 45, 60, 75, 90];
const UPNEXT_PERCENT = 45; // shares the cache entry with the 45% filmstrip frame
const UPNEXT_SLOTS = 10;   // current + 9 upcoming
const DEBOUNCE_MS = 300;
const CONCURRENCY = 2;

let ctx;
const filmImgs = {};
const upSlots = [];

// url -> object URL of the fetched JPEG (insertion-ordered for LRU eviction)
const blobs = new Map();
const failed = new Set();
const MAX_BLOBS = 600;

const thumbUrl = (id, pct) => `/api/media/${id}/thumb/${pct}`;

function cached(url) {
  const b = blobs.get(url);
  if (b) { blobs.delete(url); blobs.set(url, b); }
  return b;
}

async function fetchThumb(id, pct, signal) {
  const url = thumbUrl(id, pct);
  const hit = cached(url);
  if (hit) return { src: hit };
  if (failed.has(url)) return { failed: true };
  const res = await fetch(url, { signal });
  if (!res.ok) {
    if (res.headers.get('X-Missing')) { ctx.markMissing(id); return { missing: true }; }
    failed.add(url);
    return { failed: true };
  }
  const src = URL.createObjectURL(await res.blob());
  blobs.set(url, src);
  while (blobs.size > MAX_BLOBS) {
    const [k, v] = blobs.entries().next().value;
    blobs.delete(k);
    URL.revokeObjectURL(v);
  }
  return { src };
}

function show(thumbEl, result) {
  const img = thumbEl.querySelector('img');
  thumbEl.classList.toggle('missing', !!result?.missing);
  thumbEl.classList.toggle('failed', !!result?.failed);
  if (result?.src) img.src = result.src;
  else img.removeAttribute('src');
}

export function initPreview(c) {
  ctx = c;
  const film = $('filmstrip');
  for (const pct of FILM_PERCENTS) {
    const wrap = document.createElement('div');
    wrap.className = 'film-item';
    wrap.innerHTML = `<div class="thumb" title="Play from ${pct}%"><img alt=""></div><div class="cap">${pct}%</div>`;
    wrap.firstChild.addEventListener('click', () => ctx.play(ctx.current(), pct));
    film.appendChild(wrap);
    filmImgs[pct] = wrap.firstChild;
  }
  const up = $('upnext');
  for (let slot = 0; slot < UPNEXT_SLOTS; slot++) {
    const t = document.createElement('div');
    t.className = 'thumb' + (slot === 0 ? ' current' : '');
    t.innerHTML = '<img alt="">';
    t.addEventListener('click', () => {
      if (t.dataset.id) ctx.selectById(+t.dataset.id);
      ctx.focusTable();
    });
    up.appendChild(t);
    upSlots.push(t);
  }
}

let controller = null;
let timer = 0;

export function refreshPreview() {
  controller?.abort();
  clearTimeout(timer);
  const { items, sel } = ctx.state;
  const item = items[sel];
  $('filmstrip').scrollTop = 0;
  $('upnext').scrollTop = 0;

  const label = $('preview-label');
  label.textContent = item ? item.filename : '';
  label.title = item ? item.filename : '';

  // Instantly show whatever is already cached.
  for (const pct of FILM_PERCENTS) {
    const url = item && thumbUrl(item.id, pct);
    show(filmImgs[pct], item && (cached(url) ? { src: cached(url) } : failed.has(url) ? { failed: true } : null));
  }
  const upItems = item ? items.slice(sel, sel + UPNEXT_SLOTS) : [];
  upSlots.forEach((t, slot) => {
    const it = upItems[slot];
    t.hidden = !it;
    t.dataset.id = it ? it.id : '';
    t.title = it ? it.filename : '';
    const url = it && thumbUrl(it.id, UPNEXT_PERCENT);
    show(t, it && (cached(url) ? { src: cached(url) } : failed.has(url) ? { failed: true } : null));
  });
  if (!item) return;

  // Then fetch the rest in priority order: the selected file's filmstrip,
  // the Up Next frames, then the next file's filmstrip (so arrowing down is
  // instant). Debounced so fast scrolling doesn't queue work on the server.
  const ac = new AbortController();
  controller = ac;
  const tasks = [];
  for (const pct of FILM_PERCENTS) tasks.push({ id: item.id, pct, el: filmImgs[pct] });
  upItems.forEach((it, slot) => tasks.push({ id: it.id, pct: UPNEXT_PERCENT, el: upSlots[slot] }));
  const next = items[sel + 1];
  if (next) for (const pct of FILM_PERCENTS) tasks.push({ id: next.id, pct, el: null });

  timer = setTimeout(async () => {
    let pos = 0;
    const worker = async () => {
      while (pos < tasks.length && !ac.signal.aborted) {
        const t = tasks[pos++];
        try {
          const r = await fetchThumb(t.id, t.pct, ac.signal);
          if (!ac.signal.aborted && t.el) show(t.el, r);
        } catch { /* aborted */ }
      }
    };
    await Promise.all(Array.from({ length: CONCURRENCY }, worker));
  }, DEBOUNCE_MS);
}

