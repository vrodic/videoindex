// Actors section: filter the list by one or more actors, and view / edit /
// assign the actors of the selected file.
import { $, esc, api } from './util.js';

let ctx;
let allActors = [];
let mediaActors = [];
let selectedActorRow = -1;
const searchActors = []; // actors picked for "media featuring all of these"

export async function refreshAllActors() {
  allActors = await api('/api/actors').catch(() => []);
  $('actor-names').innerHTML = allActors.map((a) => `<option value="${esc(a.name)}">`).join('');
}

let seq = 0;
export async function refreshMediaActors() {
  const item = ctx.current();
  const mySeq = ++seq;
  const list = item ? await api(`/api/media/${item.id}/actors`).catch(() => []) : [];
  if (mySeq !== seq) return;
  mediaActors = list;
  selectedActorRow = -1;
  renderMediaActors();
}

function renderMediaActors() {
  const tbody = $('actor-rows');
  if (!mediaActors.length) {
    tbody.innerHTML = `<tr><td colspan="6" class="empty">${ctx.current() ? 'No actors for this file' : ''}</td></tr>`;
    return;
  }
  tbody.innerHTML = mediaActors.map((a, i) => `
    <tr data-i="${i}"${i === selectedActorRow ? ' class="sel"' : ''}>
      <td><input data-f="name" value="${esc(a.name)}" title="Edit and press Enter"></td>
      <td><input data-f="altNames" value="${esc(a.altNames)}" placeholder="comma separated" title="Edit and press Enter"></td>
      <td class="num">${a.mediaCount}</td>
      <td class="icon"><button data-act="assign" title="Assign to checked media">✓</button></td>
      <td class="icon"><button data-act="filter" title="Filter media by this actor">⏚</button></td>
      <td class="icon"><button data-act="search" title="Search filenames for this actor's names">🔍</button></td>
    </tr>`).join('');
}

function setCond(sql) {
  ctx.setCondition(sql, { fromHistory: false });
}

// Media tagged with *all* of the picked actors.
function applySearchActorsFilter() {
  if (!searchActors.length) {
    if (ctx.state.cond.includes('FROM media_actors')) setCond('');
    return;
  }
  const ids = searchActors.map((a) => a.id);
  setCond(`AND id IN (SELECT media_id FROM media_actors WHERE actor_id IN (${ids.join(', ')}) GROUP BY media_id HAVING COUNT(DISTINCT actor_id) = ${ids.length})`);
}

function renderPills() {
  $('actor-pills').innerHTML = searchActors.map((a, i) =>
    `<span class="pill">${esc(a.name)}<button data-i="${i}" title="Remove">✕</button></span>`).join('');
}

function toggleSearchActor(actor) {
  const i = searchActors.findIndex((a) => a.id === actor.id);
  if (i >= 0) searchActors.splice(i, 1);
  else searchActors.push(actor);
  renderPills();
  renderPopoverList();
  applySearchActorsFilter();
}

async function filterByTyped() {
  const text = $('actor-filter').value.trim();
  if (!text) {
    if (searchActors.length) applySearchActorsFilter();
    return;
  }
  for (const name of text.split(',').map((s) => s.trim()).filter(Boolean)) {
    let actor = allActors.find((a) => a.name.toLowerCase() === name.toLowerCase());
    if (!actor) actor = await api('/api/actors', { method: 'POST', body: { name } }).catch(() => null);
    if (actor && !searchActors.some((a) => a.id === actor.id)) searchActors.push(actor);
  }
  $('actor-filter').value = '';
  await refreshAllActors();
  renderPills();
  applySearchActorsFilter();
}

async function addActor() {
  const name = $('actor-add').value.trim();
  const item = ctx.current();
  if (!name || !item) return;
  await api(`/api/media/${item.id}/actors`, { method: 'POST', body: { name } });
  $('actor-add').value = '';
  await refreshAllActors();
  await refreshMediaActors();
}

async function removeActor() {
  const item = ctx.current();
  const actor = mediaActors[selectedActorRow];
  if (!item || !actor) return;
  await api(`/api/media/${item.id}/actors/${actor.id}`, { method: 'DELETE' });
  await refreshMediaActors();
}

// Condition matching filenames that contain any of the actor's names, with
// spaces turned into underscores or removed.
function filenameSearchCondition(actor) {
  const variants = new Set();
  for (const raw of [actor.name, ...actor.altNames.split(',')]) {
    const n = raw.trim();
    if (!n) continue;
    variants.add(n.replaceAll(' ', '_'));
    variants.add(n.replaceAll(' ', ''));
  }
  const likes = [...variants].map((v) => `filename LIKE '%${v.replaceAll("'", "''")}%'`).join(' OR ');
  return `AND (${likes})`;
}

async function onRowAction(act, actor) {
  if (act === 'assign') {
    const ids = [...ctx.state.checked];
    if (!ids.length) { alert('Tick some files in the ✓ column first.'); return; }
    await api(`/api/actors/${actor.id}/assign`, { method: 'POST', body: { mediaIds: ids } });
    await refreshMediaActors();
  } else if (act === 'filter') {
    setCond(`AND id IN (SELECT media_id FROM media_actors WHERE actor_id = ${actor.id})`);
  } else if (act === 'search') {
    setCond(filenameSearchCondition(actor));
  }
}

async function commitEdit(input) {
  const actor = mediaActors[+input.closest('tr').dataset.i];
  const field = input.dataset.f;
  const value = input.value.trim();
  if (!actor || value === actor[field]) return;
  if (field === 'name' && !value) { input.value = actor.name; return; }
  await api(`/api/actors/${actor.id}`, { method: 'PATCH', body: { [field]: value } });
  actor[field] = value;
  if (field === 'name') await refreshAllActors();
}

// --- "Select Actors…" popover ---

function sortedActors() {
  return [...allActors].sort((a, b) => b.mediaCount - a.mediaCount || a.name.localeCompare(b.name, undefined, { numeric: true }));
}

function renderPopoverList() {
  const f = $('actor-popover-search').value.toLowerCase();
  const list = sortedActors().filter((a) => !f || a.name.toLowerCase().includes(f) || a.altNames.toLowerCase().includes(f));
  $('actor-popover-list').innerHTML = list.map((a) =>
    `<li><label><input type="checkbox" data-id="${a.id}"${searchActors.some((s) => s.id === a.id) ? ' checked' : ''}>${esc(a.name)} (${a.mediaCount})</label></li>`).join('');
}

export function initActors(c) {
  ctx = c;
  refreshAllActors();

  $('actor-filter').addEventListener('keydown', (e) => { if (e.key === 'Enter') filterByTyped(); });
  $('actor-filter-btn').addEventListener('click', filterByTyped);
  $('actor-add').addEventListener('keydown', (e) => { if (e.key === 'Enter') addActor(); });
  $('actor-add-btn').addEventListener('click', addActor);
  $('actor-remove-btn').addEventListener('click', removeActor);
  $('actor-pills').addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (b) toggleSearchActor(searchActors[+b.dataset.i]);
  });

  const rows = $('actor-rows');
  rows.addEventListener('click', (e) => {
    const tr = e.target.closest('tr[data-i]');
    if (!tr) return;
    selectedActorRow = +tr.dataset.i;
    for (const r of rows.children) r.classList.toggle('sel', r === tr);
    const b = e.target.closest('button[data-act]');
    if (b) onRowAction(b.dataset.act, mediaActors[selectedActorRow]);
  });
  rows.addEventListener('keydown', (e) => {
    if (e.target.tagName !== 'INPUT') return;
    if (e.key === 'Enter') { e.target.blur(); }
    if (e.key === 'Escape') {
      const actor = mediaActors[+e.target.closest('tr').dataset.i];
      e.target.value = actor[e.target.dataset.f];
      e.target.blur();
    }
  });
  rows.addEventListener('focusout', (e) => { if (e.target.tagName === 'INPUT') commitEdit(e.target); });

  const pop = $('actor-popover');
  $('actor-select-btn').addEventListener('click', async () => {
    if (!pop.hidden) { pop.hidden = true; return; }
    await refreshAllActors();
    $('actor-popover-search').value = '';
    renderPopoverList();
    pop.hidden = false;
    $('actor-popover-search').focus();
  });
  $('actor-popover-search').addEventListener('input', renderPopoverList);
  $('actor-popover-list').addEventListener('change', (e) => {
    const a = allActors.find((x) => x.id === +e.target.dataset.id);
    if (a) toggleSearchActor(a);
  });
  document.addEventListener('mousedown', (e) => {
    if (!pop.hidden && !e.target.closest('.popover-anchor')) pop.hidden = true;
  });
}
