// Run the library scanner (ffprobe new files into the index) from the UI.
import { esc, api } from './app.js';
import { openModal } from './modal.js';

export async function openScan(ctx) {
  let timer = 0;
  let wasRunning = false;
  const body = openModal('Scan Library', { small: true, onClose: () => clearTimeout(timer) });
  body.innerHTML = `
    <p style="margin:0">Walks the media root, probes files that aren't in the index yet with <code>ffprobe</code> and adds them.
    Files that fail are remembered and skipped next time.</p>
    <div class="toolbar">
      <label><input type="checkbox" id="scan-rescan"> Rescan previously skipped files</label>
      <label>Workers <input type="number" id="scan-workers" value="8" min="1" max="32" style="width:60px"></label>
      <button id="scan-start" class="on">Start scan</button>
    </div>
    <progress id="scan-progress" value="0" max="1" hidden></progress>
    <div id="scan-state"></div>
    <pre class="scan-log" id="scan-log"></pre>`;
  const $q = (s) => body.querySelector(s);

  const poll = async () => {
    let s;
    try { s = await api('/api/scan'); } catch { return; }
    if (!body.isConnected) return;
    $q('#scan-start').disabled = s.running;
    const prog = $q('#scan-progress');
    prog.hidden = !s.total && !s.running;
    prog.max = s.total || 1;
    prog.value = s.done || 0;
    $q('#scan-state').innerHTML = s.running
      ? `Probing… ${s.done ?? 0} / ${s.total ?? '?'}`
      : s.error ? `<span style="color:var(--c-red)">Scan failed: ${esc(s.error)}</span>`
      : s.log ? 'Finished.' : 'No scan has run since the server started.';
    const log = $q('#scan-log');
    const atBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 4;
    log.textContent = s.log || '';
    if (atBottom) log.scrollTop = log.scrollHeight;
    if (wasRunning && !s.running) ctx.reload();
    wasRunning = s.running;
    if (s.running) timer = setTimeout(poll, 1000);
  };

  $q('#scan-start').addEventListener('click', async () => {
    try {
      await api('/api/scan', { method: 'POST', body: { rescanSkipped: $q('#scan-rescan').checked, workers: +$q('#scan-workers').value } });
    } catch (e) {
      $q('#scan-state').textContent = e.message;
    }
    poll();
  });
  poll();
}
