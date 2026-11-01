// One shared modal dialog; each feature fills its body.
import { $ } from './util.js';

let onClose = null;

export const modalOpen = () => !$('modal').hidden;

export function openModal(title, { small = false, onClose: cb = null } = {}) {
  if (modalOpen()) closeModal();
  $('modal-title').textContent = title;
  $('modal').querySelector('.modal-box').classList.toggle('small', small);
  // A fresh element per dialog, so listeners and observers attached by one
  // dialog die with it instead of firing inside the next one.
  const outer = $('modal-body');
  outer.scrollTop = 0;
  const body = document.createElement('div');
  body.className = 'modal-content';
  outer.replaceChildren(body);
  $('modal').hidden = false;
  onClose = cb;
  return body;
}

export function closeModal() {
  if (!modalOpen()) return;
  $('modal').hidden = true;
  $('modal-body').innerHTML = '';
  const cb = onClose;
  onClose = null;
  cb?.();
  $('table').focus({ preventScroll: true });
}

document.addEventListener('DOMContentLoaded', () => {
  $('modal-close').addEventListener('click', closeModal);
  $('modal').addEventListener('mousedown', (e) => { if (e.target.id === 'modal') closeModal(); });
});
