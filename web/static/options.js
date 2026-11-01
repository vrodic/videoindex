// Player options (the old MPV menu), saved per browser.
import { store } from './util.js';

export const DEFAULT_OPTIONS = {
  volume: 33,        // percent; up to 1000 with boost (mpv --volume-max=1000)
  boost: true,
  mute: false,
  noAudio: false,
  loop: false,
  keepOpen: false,   // stay open at the end instead of closing
  autoNext: false,   // play the next row when a video ends
  windowSize: 75,    // player window size, % of the screen
  inline: false,     // play in the list window instead of a pop-up
  speed: 1,
};

export function playerOptions() {
  return { ...DEFAULT_OPTIONS, ...(store('player') || {}) };
}

export function savePlayerOptions(o) { store('player', o); }
