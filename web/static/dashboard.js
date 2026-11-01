// Library analytics: totals, a squarified treemap and breakdown tables,
// for the whole library or the current search + condition.
import { esc, api } from './util.js';
import { openModal } from './modal.js';

export function formatBytes(b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (b >= 1000 && i < units.length - 1) { b /= 1000; i++; }
  return (i >= 3 ? b.toFixed(2) : b.toFixed(i ? 1 : 0)) + ' ' + units[i];
}

export function formatDuration(s) {
  if (!(s > 0) || !isFinite(s)) return '0s';
  s = Math.floor(s);
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  if (d) return `${d}d ${h}h ${m}m`;
  if (h) return `${h}h ${m}m`;
  if (m) return `${m}m ${sec}s`;
  return `${sec}s`;
}

const color = (c) => `var(--c-${c})`;
const pct = (a, b) => (b > 0 ? ((a / b) * 100).toFixed(1) + '%' : '0.0%');

// --- squarified treemap (Bruls, Huizing & van Wijk) -------------------------

function squarify(items, rect) {
  const tiles = [];
  const total = items.reduce((s, it) => s + it.value, 0);
  if (!total || rect.w <= 0 || rect.h <= 0) return tiles;
  const scale = (rect.w * rect.h) / total;
  const queue = items.map((it) => ({ it, area: it.value * scale }));
  let r = { ...rect };

  const worst = (row, side) => {
    const sum = row.reduce((s, x) => s + x.area, 0);
    const max = Math.max(...row.map((x) => x.area));
    const min = Math.min(...row.map((x) => x.area));
    return Math.max((side * side * max) / (sum * sum), (sum * sum) / (side * side * min));
  };
  const layout = (row) => {
    const sum = row.reduce((s, x) => s + x.area, 0);
    if (r.w >= r.h) {
      const w = sum / r.h;
      let y = r.y;
      for (const x of row) { const h = x.area / w; tiles.push({ ...x.it, x: r.x, y, w, h }); y += h; }
      r = { x: r.x + w, y: r.y, w: r.w - w, h: r.h };
    } else {
      const h = sum / r.w;
      let x0 = r.x;
      for (const x of row) { const w = x.area / h; tiles.push({ ...x.it, x: x0, y: r.y, w, h }); x0 += w; }
      r = { x: r.x, y: r.y + h, w: r.w, h: r.h - h };
    }
  };

  let row = [];
  while (queue.length) {
    const side = Math.min(r.w, r.h);
    const next = queue[0];
    if (!row.length || worst([...row, next], side) <= worst(row, side)) {
      row.push(queue.shift());
    } else {
      layout(row);
      row = [];
    }
  }
  if (row.length) layout(row);
  return tiles;
}

function renderTreemap(el, items) {
  items = items.filter((i) => i.value > 0).sort((a, b) => b.value - a.value);
  const rect = { x: 0, y: 0, w: el.clientWidth, h: el.clientHeight };
  el.innerHTML = squarify(items, rect).map((t) => {
    const showText = t.w > 70 && t.h > 34;
    return `<div class="tile" style="left:${t.x}px;top:${t.y}px;width:${t.w}px;height:${t.h}px;--tile-c:${color(t.color)}"
      title="${esc(t.title)} (${esc(t.subtitle)}): ${esc(t.formatted)} (${t.pct})">${showText
        ? `<b>${esc(t.title)}</b><span>${esc(t.formatted)} · ${t.pct}</span><br><span>${esc(t.subtitle)}</span>` : ''}</div>`;
  }).join('');
}

// --- tables -------------------------------------------------------------------

function table(title, cols, rows) {
  return `<div class="box"><h3>${esc(title)}</h3><table><thead><tr>${cols.map((c) =>
    `<th class="${c.n ? 'n' : ''}">${esc(c.t)}</th>`).join('')}</tr></thead><tbody>${rows.map((r) =>
    `<tr>${cols.map((c, i) => `<td class="${c.n ? 'n' : ''}">${i === 0 ? `<span class="swatch" style="--sw:${color(r.color)}"></span>` : ''}${esc(c.v(r))}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
}

export async function openDashboard(ctx) {
  let ro = null;
  const body = openModal('Library Analytics Dashboard', { onClose: () => ro?.disconnect() });
  let scope = 'all';
  let metric = 0;
  let data = null;

  body.innerHTML = `
    <div class="toolbar">
      <label>Filter scope:</label><div class="seg" data-g="scope"><button data-v="all" class="on">All Media</button><button data-v="filter">Current Filter</button></div>
      <label>Treemap metric:</label><div class="seg" data-g="metric">
        <button data-v="0" class="on">By Likes</button><button data-v="1">By Resolutions</button><button data-v="2">By Durations</button><button data-v="3">By Views</button><button data-v="4">By Actors</button><button data-v="5">By Last Viewed</button></div>
    </div>
    <div class="cards"></div>
    <div class="treemap-title"></div>
    <div class="treemap"></div>
    <div class="breakdowns"></div>`;
  const $q = (s) => body.querySelector(s);

  const metrics = [
    { title: 'Storage Distribution by Like Rating', list: 'likes', by: 'bytes' },
    { title: 'Video Count by Resolution Class', list: 'resolutions', by: 'count' },
    { title: 'Video Count by Duration Range', list: 'durations', by: 'count' },
    { title: 'Storage Distribution by View Count Tier', list: 'views', by: 'bytes' },
    { title: 'Storage Distribution by Actor', list: 'actors', by: 'bytes' },
    { title: 'Video Count by Last Viewed', list: 'lastViewed', by: 'count' },
  ];

  const drawTreemap = () => {
    if (!data) return;
    const m = metrics[metric];
    $q('.treemap-title').textContent = 'Squarified Treemap: ' + m.title;
    const items = data[m.list].map((s) => m.by === 'bytes'
      ? { title: s.title, color: s.color, value: s.bytes, formatted: formatBytes(s.bytes), subtitle: `${s.count} videos`, pct: pct(s.bytes, data.bytes) }
      : { title: s.title, color: s.color, value: s.count, formatted: `${s.count} videos`,
          subtitle: m.list === 'durations' ? formatDuration(s.duration) : formatBytes(s.bytes), pct: pct(s.count, data.count) });
    renderTreemap($q('.treemap'), items);
  };

  const render = () => {
    const d = data;
    const seg = body.querySelector('[data-g=scope]').children;
    seg[0].textContent = `All Media (${d.allCount})`;
    seg[1].textContent = `Current Filter (${d.filteredCount})`;
    seg[1].title = d.filterError ? 'Filter error: ' + d.filterError : '';
    const avgB = d.count ? d.bytes / d.count : 0;
    const avgD = d.count ? d.duration / d.count : 0;
    $q('.cards').innerHTML = [
      ['Total Videos', d.count, 'Items in library', 'blue'],
      ['Total Storage', formatBytes(d.bytes), `Avg ${formatBytes(avgB)} / video`, 'purple'],
      ['Total Playtime', formatDuration(d.duration), `Avg ${formatDuration(avgD)} / video`, 'orange'],
    ].map(([t, v, s, c]) => `<div class="card" style="--card-c:${color(c)}"><div class="t">${t.toUpperCase()}</div><div class="v">${esc(v)}</div><div class="s">${esc(s)}</div></div>`).join('');

    const size = (r) => formatBytes(r.bytes);
    $q('.breakdowns').innerHTML = [
      table('File Sizes & Storage by Likes', [
        { t: 'Like Tier', v: (r) => r.title }, { t: 'Videos', n: 1, v: (r) => r.count }, { t: 'Total Storage', n: 1, v: size },
        { t: 'Avg Size', n: 1, v: (r) => formatBytes(r.count ? r.bytes / r.count : 0) }, { t: '% Storage', n: 1, v: (r) => pct(r.bytes, d.bytes) }], d.likes),
      table('Actors Breakdown', [
        { t: 'Actor Name', v: (r) => r.title }, { t: 'Total Storage', n: 1, v: size }, { t: 'Videos', n: 1, v: (r) => r.count },
        { t: '% Storage', n: 1, v: (r) => pct(r.bytes, d.bytes) }], d.actors),
      table('Resolutions Breakdown', [
        { t: 'Resolution Class', v: (r) => r.title }, { t: 'Videos', n: 1, v: (r) => r.count }, { t: 'Total Storage', n: 1, v: size },
        { t: '% Videos', n: 1, v: (r) => pct(r.count, d.count) }], d.resolutions),
      table('Durations Breakdown', [
        { t: 'Duration Range', v: (r) => r.title }, { t: 'Videos', n: 1, v: (r) => r.count }, { t: 'Total Duration', n: 1, v: (r) => formatDuration(r.duration) },
        { t: 'Total Storage', n: 1, v: size }, { t: '% Videos', n: 1, v: (r) => pct(r.count, d.count) }], d.durations),
      table('View Counts Breakdown', [
        { t: 'View Tier', v: (r) => r.title }, { t: 'Videos', n: 1, v: (r) => r.count }, { t: 'Total Storage', n: 1, v: size },
        { t: '% Videos', n: 1, v: (r) => pct(r.count, d.count) }], d.views),
      table('Last Viewed Breakdown', [
        { t: 'Last Viewed', v: (r) => r.title }, { t: 'Videos', n: 1, v: (r) => r.count }, { t: 'Total Storage', n: 1, v: size },
        { t: '% Videos', n: 1, v: (r) => pct(r.count, d.count) }], d.lastViewed),
    ].join('');
    drawTreemap();
  };

  const load = async () => {
    const qs = new URLSearchParams({ scope, search: ctx.state.search, cond: ctx.state.cond });
    try {
      data = await api('/api/dashboard?' + qs);
      render();
    } catch (e) {
      $q('.cards').textContent = 'Failed: ' + e.message;
    }
  };

  body.addEventListener('click', (e) => {
    const b = e.target.closest('.seg button');
    if (!b) return;
    const g = b.parentElement.dataset.g;
    b.parentElement.querySelectorAll('button').forEach((x) => x.classList.toggle('on', x === b));
    if (g === 'scope') { scope = b.dataset.v; load(); }
    else { metric = +b.dataset.v; drawTreemap(); }
  });
  ro = new ResizeObserver(() => drawTreemap());
  ro.observe($q('.treemap'));
  await load();
}
