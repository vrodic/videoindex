// How a file gets to the browser, shared by the list (to flag files that
// need server-side work) and the player (to pick a playback chain).
//
// The server's `play` field says what the container/codec need in general;
// whether this browser can decode HEVC is only known here.

let hevcOk = null;
export function hevcSupported() {
  if (hevcOk == null) {
    hevcOk = document.createElement('video').canPlayType('video/mp4; codecs="hvc1.1.6.L93.B0"') !== '';
  }
  return hevcOk;
}

const isHevc = (it) => (it.codec || '').toLowerCase() === 'hevc';

// Playback modes to try, best first; the player falls back along the chain.
export function playbackChain(it) {
  const ok = !isHevc(it) || hevcSupported();
  const chain = [];
  if (it.play === 'direct' && ok) chain.push('direct');
  if ((it.play === 'direct' || it.play === 'remux') && ok) chain.push('remux');
  chain.push('transcode');
  return chain;
}

// What playing the file will cost, for the list's "Play" column:
//   direct    — served as-is, seeks are free
//   remux     — container rewritten on the fly, seeks restart at a keyframe
//   seek      — remuxed from the start, but every seek is transcoded
//               (open-GOP HEVC can't restart a stream copy mid-file)
//   transcode — re-encoded the whole time
export function playNeed(it) {
  const first = playbackChain(it)[0];
  if (first === 'direct') return 'direct';
  if (first === 'transcode') return 'transcode';
  return isHevc(it) ? 'seek' : 'remux';
}

export const PLAY_NEED_LABEL = {
  direct: '',
  remux: 'remux',
  seek: 'tc on seek',
  transcode: 'transcode',
};

export const PLAY_NEED_TITLE = {
  direct: 'Plays directly',
  remux: 'Remuxed on the fly (no re-encode); seeking restarts the stream at a keyframe',
  seek: 'Remuxed from the start; seeking re-encodes from the seek point (HEVC)',
  transcode: 'Re-encoded on the fly to H.264 for the whole playback',
};

// Order for sorting the column: cheapest first.
export const PLAY_NEED_RANK = { direct: 0, remux: 1, seek: 2, transcode: 3 };
