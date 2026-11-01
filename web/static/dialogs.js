// Player options (the old MPV menu) and the keyboard help.
import { openModal } from './modal.js';
import { playerOptions, savePlayerOptions, DEFAULT_OPTIONS } from './player.js';

export function openOptions() {
  const body = openModal('Player Options', { small: true });
  const o = playerOptions();
  const sel = (id, values, cur) => `<select id="${id}">${values.map(([v, l]) => `<option value="${v}"${String(v) === String(cur) ? ' selected' : ''}>${l}</option>`).join('')}</select>`;
  const chk = (id, label) => `<label><input type="checkbox" id="${id}"${o[id] ? ' checked' : ''}> ${label}</label>`;
  body.innerHTML = `
    <div class="form-grid">
      <label for="volume">Default volume</label>
      ${sel('volume', [[10, '10%'], [25, '25%'], [33, '33% (default)'], [50, '50%'], [75, '75%'], [100, '100%']], o.volume)}
      <span></span>${chk('boost', 'Allow volume above 100% (up to 1000%, like mpv --volume-max=1000)')}
      <label for="fit">Player size</label>
      ${sel('fit', [['50', '50% of window'], ['75', '75% of window (default)'], ['100', '100% of window'], ['fullscreen', 'Fullscreen']], o.fit)}
      <label for="speed">Playback speed</label>
      ${sel('speed', [[1, '1.0× (normal)'], [1.25, '1.25×'], [1.5, '1.5×'], [2, '2.0×']], o.speed)}
      <span></span>${chk('mute', 'Start muted')}
      <span></span>${chk('noAudio', 'No audio')}
      <span></span>${chk('loop', 'Loop video')}
      <span></span>${chk('keepOpen', 'Keep player open when the video ends')}
      <span></span>${chk('autoNext', 'Play the next row when the video ends')}
    </div>
    <div class="toolbar"><button id="opt-reset">Reset to defaults</button></div>
    <p style="margin:0;color:var(--muted);font-size:12px">Saved in this browser.</p>`;
  const save = () => {
    const q = (id) => body.querySelector('#' + id);
    savePlayerOptions({
      ...o,
      volume: +q('volume').value, boost: q('boost').checked, fit: q('fit').value, speed: +q('speed').value,
      mute: q('mute').checked, noAudio: q('noAudio').checked, loop: q('loop').checked,
      keepOpen: q('keepOpen').checked, autoNext: q('autoNext').checked,
    });
  };
  body.addEventListener('change', save);
  body.querySelector('#opt-reset').addEventListener('click', () => { savePlayerOptions({ ...DEFAULT_OPTIONS }); openOptions(); });
}

export function openHelp() {
  const body = openModal('Keyboard Shortcuts', { small: true });
  const rows = (list) => list.map(([k, d]) => `<tr><td>${k.split(' ').map((x) => `<kbd>${x}</kbd>`).join(' ')}</td><td>${d}</td></tr>`).join('');
  body.innerHTML = `
    <table class="keys">
      <tr><td colspan="2"><h4>List</h4></td></tr>
      ${rows([
        ['↑ ↓ PgUp PgDn', 'Move selection'],
        ['Home End', 'First / last row'],
        ['Enter', 'Play selected (double-click works too)'],
        ['+ = Insert', 'Like (+1) and move down'],
        ['Delete Backspace', 'Dislike; a second dislike deletes the file'],
        ['Space', 'Tick / untick the row (for assigning actors)'],
        ['/ ⌘F', 'Search filename'],
        ['c ⌘L', 'Edit SQL condition'],
        ['r', 'Reload query (clears column sort)'],
        ['w ⌘K', 'Word cloud'],
        ['d', 'Dashboard'],
        ['o', 'Player options'],
        ['Esc', 'Leave a text field / close a dialog'],
      ])}
      <tr><td colspan="2"><h4>Player</h4></td></tr>
      ${rows([
        ['Space k p', 'Pause / play'],
        ['← →', 'Seek ∓5 s (Shift: 1 s)'],
        ['↑ ↓', 'Seek ±60 s'],
        ['PgUp PgDn', 'Seek ±10%'],
        ['9 0', 'Volume down / up'],
        ['m', 'Mute'],
        ['[ ] { }', 'Speed ÷1.1 ×1.1 ÷2 ×2'],
        ['Backspace', 'Reset speed'],
        ['l', 'Toggle loop'],
        ['f', 'Fullscreen (double-click works too)'],
        [', .', 'Frame step back / forward'],
        ['n Enter', 'Play next row'],
        ['N', 'Play previous row'],
        ['o', 'Show position'],
        ['q Esc', 'Close player'],
      ])}
    </table>`;
}
