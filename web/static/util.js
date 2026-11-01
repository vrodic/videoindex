// Small helpers shared by the list page and the player window.

export const $ = (id) => document.getElementById(id);
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Per-browser settings in localStorage (shared by every window of the app).
export function store(key, value) {
  try {
    if (value === undefined) return JSON.parse(localStorage.getItem('videoindex.' + key));
    localStorage.setItem('videoindex.' + key, JSON.stringify(value));
  } catch { return null; }
}

export async function api(path, { method = 'GET', body, signal } = {}) {
  const res = await fetch(path, {
    method, signal,
    headers: body !== undefined ? { 'Content-Type': 'application/json' } : undefined,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}
