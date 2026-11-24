'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { preprocessCaptureBitmap } = require('../electron/app/ocr-preprocess');

test('light-mode bitmaps erase light-blue highlights and eye tint to white while keeping black text crisp', () => {
  // 4x1 pixels (BGRA):
  // 0: white background (245, 245, 245) -> luma 245 -> 255 (white)
  // 1: light-blue selection (250, 210, 175) -> luma ~204 -> 255 (white)
  // 2: eye gray overlay over blue highlight (160, 140, 125) -> luma ~138 -> 255 (white)
  // 3: black glyph under eye overlay (40, 35, 30) -> luma ~34 -> near 0 (black)
  const bgra = Buffer.from([
    245, 245, 245, 255,
    250, 210, 175, 255,
    160, 140, 125, 255,
    40, 35, 30, 255
  ]);
  const out = preprocessCaptureBitmap(bgra, 4, 1);
  assert.ok(out);
  assert.equal(out[0], 255); // white bg -> white
  assert.equal(out[4], 255); // light-blue selection -> white
  assert.equal(out[8], 255); // eye gray overlay -> white
  assert.ok(out[12] < 20, 'dark glyph should stay near black');
  assert.equal(out[15], 255);
});

test('dark-mode bitmaps invert text to black and erase dark & blue-highlight backgrounds to white', () => {
  // 3x1 pixels (BGRA):
  // 0: dark background #1a1b1e (B=30, G=27, R=26) -> luma ~27 -> inv ~228 -> 255 (white)
  // 1: blue selection highlight #3c5a7a (B=122, G=90, R=60) -> luma ~85 -> inv ~170 -> 255 (white)
  // 2: light text #e8eaed (B=237, G=234, R=232) -> luma ~234 -> inv ~21 -> 0 (black)
  const bgra = Buffer.from([
    30, 27, 26, 255,
    122, 90, 60, 255,
    237, 234, 232, 255
  ]);
  const out = preprocessCaptureBitmap(bgra, 3, 1);
  assert.ok(out);
  assert.equal(out[0], 255); // dark bg -> white
  assert.equal(out[4], 255); // blue highlight -> white
  assert.equal(out[8], 0);   // bright glyph -> black
  assert.equal(out[11], 255);
});
