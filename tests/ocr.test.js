'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { extractWords, buildLines, findFocus, joinLine } = require('../electron/app/ocr');

function word(text, x0, y0, x1, y1, confidence = 90) {
  return { text, confidence, bbox: { x0, y0, x1, y1 } };
}

test('extractWords walks Tesseract block output without duplicates', () => {
  const data = {
    blocks: [{
      paragraphs: [{
        lines: [{
          text: 'hello world',
          words: [word('hello', 10, 20, 60, 40), word('world', 70, 20, 120, 40)]
        }]
      }]
    }]
  };
  const words = extractWords(data);
  assert.equal(words.length, 2);
  assert.deepEqual(words.map((item) => item.text), ['hello', 'world']);
});

test('buildLines groups words on the same visual row', () => {
  const lines = buildLines([
    word('hello', 10, 20, 60, 40),
    word('world', 70, 20, 120, 40),
    word('next', 10, 60, 50, 80)
  ]);
  assert.equal(lines.length, 2);
  assert.equal(lines[0].text, 'hello world');
  assert.equal(lines[1].text, 'next');
});

test('findFocus chooses the word under the centre and keeps sentence context', () => {
  const words = [
    word('It', 20, 20, 42, 44),
    word('is', 50, 20, 70, 44),
    word('afternoon', 78, 20, 170, 44),
    word('in', 178, 20, 198, 44),
    word('Shanghai.', 206, 20, 300, 44),
    word('Next', 20, 58, 70, 82),
    word('line.', 78, 58, 130, 82)
  ];
  const result = findFocus(words, { x: 120, y: 32 }, { width: 900, height: 240 });
  assert.equal(result.anchor, 'afternoon');
  assert.match(result.sentence, /afternoon/);
  assert.ok(result.distance <= 1);
});

test('findFocus returns nothing when the pointer is far from text', () => {
  const result = findFocus(
    [word('hello', 20, 20, 80, 44)],
    { x: 600, y: 200 },
    { width: 900, height: 240 }
  );
  assert.equal(result, null);
});

test('joinLine keeps punctuation attached', () => {
  assert.equal(joinLine([
    word('Hello', 0, 0, 40, 20),
    word(',', 40, 0, 46, 20),
    word('world', 52, 0, 100, 20),
    word('!', 100, 0, 106, 20)
  ]), 'Hello, world!');
});
