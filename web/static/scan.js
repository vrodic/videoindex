// Run the library scanner (ffprobe new files into the index) from the UI.
import { esc, api } from './util.js';
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
    <pre class="scan-log" id="scan-log"></pre>
    <h3 style="margin:4px 0 0;font-size:13px">New-file watcher</h3>
    <div id="watch-state"></div>
    <pre class="scan-log" id="watch-log" style="height:20vh"></pre>`;
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

    const w = s.watch;
    $q('#watch-state').textContent = w
      ? `Watching ${w.dirs} directories · ${w.pending} new file${w.pending === 1 ? '' : 's'} waiting to finish downloading`
      : 'Off. Start the server on Linux with -watch to index new files automatically.';
    $q('#watch-log').hidden = !w;
    if (w) {
      const wl = $q('#watch-log');
      const bottom = wl.scrollTop + wl.clientHeight >= wl.scrollHeight - 4;
      wl.textContent = w.log || 'No activity yet.';
      if (bottom) wl.scrollTop = wl.scrollHeight;
    }
    timer = setTimeout(poll, s.running ? 1000 : 3000);
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
