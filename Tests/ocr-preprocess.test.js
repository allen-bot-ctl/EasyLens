'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { preprocessDarkBitmap } = require('../electron/app/ocr-preprocess');

test('light-mode bitmaps are left untouched', () => {
  // 2x1 white background (BGRA: 245, 245, 245, 255)
  const bgra = Buffer.from([245, 245, 245, 255, 245, 245, 245, 255]);
  assert.equal(preprocessDarkBitmap(bgra, 2, 1), null);
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
  const out = preprocessDarkBitmap(bgra, 3, 1);
  assert.ok(out);
  assert.equal(out[0], 255); // dark bg -> white
  assert.equal(out[4], 255); // blue highlight -> white
  assert.equal(out[8], 0);   // bright glyph -> black
  assert.equal(out[11], 255);
});
