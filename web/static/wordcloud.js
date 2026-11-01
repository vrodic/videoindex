// Word cloud of filename words (or adjacent word pairs, which tend to be
// first_last names). Clicking a word searches for it.
import { esc, api } from './util.js';
import { openModal, closeModal } from './modal.js';

const PAGE = 200;

function colorFor(r) {
  if (r > 0.8) return 'var(--c-purple)';
  if (r > 0.6) return 'var(--c-red)';
  if (r > 0.4) return 'var(--c-orange)';
  if (r > 0.25) return 'var(--c-teal)';
  if (r > 0.12) return 'var(--c-blue)';
  if (r > 0.05) return 'var(--c-green)';
  return 'var(--text)';
}

export async function openWordCloud(ctx) {
  const body = openModal('Word Cloud Search');
  body.innerHTML = '<div class="toolbar"><span>Loading…</span></div>';
  let data;
  try {
    data = await api('/api/words');
  } catch (e) {
    body.textContent = 'Failed: ' + e.message;
    return;
  }
  let mode = 'words';
  let page = 0;

  body.innerHTML = `
    <div class="toolbar">
      <div class="seg"><button data-m="words" class="on">All Words</button><button data-m="names">Full Names (first_last)</button></div>
    </div>
    <div class="cloud"></div>
    <div class="pager"><button data-p="-1">← Previous</button><span class="pl"></span><button data-p="1">Next →</button></div>`;
  const cloud = body.querySelector('.cloud');

  const render = () => {
    const list = data[mode];
    const pages = Math.max(1, Math.ceil(list.length / PAGE));
    page = Math.max(0, Math.min(page, pages - 1));
    const words = list.slice(page * PAGE, page * PAGE + PAGE);
    const max = words[0]?.count ?? 1;
    const min = words[words.length - 1]?.count ?? 1;
    cloud.innerHTML = words.map(({ word, count }) => {
      const r = max > min ? (count - min) / (max - min) : 0.5;
      const size = max > min ? 14 + r * 30 : 20;
      return `<a data-w="${esc(word)}" title="${esc(word)} appears in ${count} files" style="font-size:${size.toFixed(1)}px;font-weight:${r >= 0.5 ? 700 : 400};color:${colorFor(r)}">${esc(word)} (${count})</a>`;
    }).join('');
    body.querySelector('.pl').textContent = list.length ? `Page ${page + 1} of ${pages} (${list.length} total)` : 'No words found';
    body.querySelector('[data-p="-1"]').disabled = page === 0;
    body.querySelector('[data-p="1"]').disabled = page >= pages - 1;
    body.parentElement.scrollTop = 0;
  };

  body.addEventListener('click', (e) => {
    const m = e.target.closest('[data-m]');
    if (m) {
      mode = m.dataset.m;
      page = 0;
      body.querySelectorAll('[data-m]').forEach((b) => b.classList.toggle('on', b === m));
      render();
      return;
    }
    const p = e.target.closest('[data-p]');
    if (p) { page += +p.dataset.p; render(); return; }
    const w = e.target.closest('[data-w]');
    if (w) {
      closeModal();
      ctx.setSearch(w.dataset.w);
    }
  });
  render();
}
