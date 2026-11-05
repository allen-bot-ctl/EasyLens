'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { createWorker } = require('tesseract.js');
const { clipboardWords, focusedWordWithHint } = require('./focus-text');

let workerPromise = null;

function languageData() {
  try {
    return require('@tesseract.js-data/eng');
  } catch {
    return { code: 'eng', gzip: true };
  }
}

function createOcrService(options = {}) {
  const data = languageData();
  const cachePath = options.cachePath || path.join(require('node:os').tmpdir(), 'easylens-ocr-cache');
  const langPath = options.langPath || data.langPath;
  const gzip = options.gzip ?? data.gzip ?? true;

  async function getWorker() {
    if (workerPromise) return workerPromise;
    workerPromise = (async () => {
      try { fs.mkdirSync(cachePath, { recursive: true }); } catch { /* best effort */ }
      return createWorker('eng', 1, {
        langPath,
        gzip,
        cachePath,
        logger: (message) => {
          if (options.debug && message.status === 'recognizing text' && message.progress === 1) {
            console.log('EASYLENS_OCR_PROGRESS complete');
          }
        },
        errorHandler: (error) => console.error('EASYLENS_OCR_WORKER_ERROR', error)
      });
    })();
    return workerPromise;
  }

  async function recognize(image) {
    const worker = await getWorker();
    const result = await worker.recognize(image, {}, { text: true, blocks: true });
    return extractWords(result.data);
  }

  async function terminate() {
    if (!workerPromise) return;
    try {
      const worker = await workerPromise;
      await worker.terminate();
    } catch { /* already gone */ }
    workerPromise = null;
  }

  return { recognize, terminate, getWorker };
}

function extractWords(data) {
  const words = [];
  const seen = new Set();
  function addWord(node) {
    if (!node || typeof node.text !== 'string' || !node.bbox) return;
    const text = node.text.trim();
    if (!text || !/[A-Za-z]/.test(text)) return;
    const { x0, y0, x1, y1 } = node.bbox;
    if (![x0, y0, x1, y1].every(Number.isFinite) || x1 <= x0 || y1 <= y0) return;
    const key = `${text}|${Math.round(x0)}|${Math.round(y0)}|${Math.round(x1)}|${Math.round(y1)}`;
    if (seen.has(key)) return;
    seen.add(key);
    words.push({
      text,
      confidence: Number(node.confidence ?? 0),
      bbox: { x0, y0, x1, y1 }
    });
  }
  function walk(node, depth = 0) {
    if (!node || typeof node !== 'object' || depth > 8) return;
    if (Array.isArray(node)) {
      for (const item of node) walk(item, depth + 1);
      return;
    }
    if (Array.isArray(node.words)) {
      for (const word of node.words) addWord(word);
      return;
    }
    if (node.bbox && typeof node.text === 'string' &&
        !Array.isArray(node.lines) && !Array.isArray(node.paragraphs) &&
        !Array.isArray(node.blocks)) {
      addWord(node);
      return;
    }
    for (const key of ['blocks', 'paragraphs', 'lines', 'words']) {
      if (node[key]) walk(node[key], depth + 1);
    }
  }
  walk(data);
  return words;
}

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value));
}

function coreWord(text) {
  const matches = text.match(/[A-Za-z]+(?:['’][A-Za-z]+)?/g) || [];
  if (matches.length === 0) return null;
  return matches.sort((a, b) => b.length - a.length)[0];
}

function buildLines(words) {
  const sorted = words.slice().sort((a, b) => {
    const ay = (a.bbox.y0 + a.bbox.y1) / 2;
    const by = (b.bbox.y0 + b.bbox.y1) / 2;
    if (Math.abs(ay - by) > 3) return ay - by;
    return a.bbox.x0 - b.bbox.x0;
  });
  const lines = [];
  for (const word of sorted) {
    const height = word.bbox.y1 - word.bbox.y0;
    const center = (word.bbox.y0 + word.bbox.y1) / 2;
    let line = lines.find((candidate) => {
      const distance = Math.abs(candidate.center - center);
      return distance <= Math.max(3, Math.min(candidate.height, height) * 0.5);
    });
    if (!line) {
      line = { words: [], center, height };
      lines.push(line);
    }
    line.words.push(word);
    line.center = (line.center * (line.words.length - 1) + center) / line.words.length;
    line.height = Math.max(line.height, height);
  }
  for (const line of lines) {
    line.words.sort((a, b) => a.bbox.x0 - b.bbox.x0);
    line.text = joinLine(line.words);
    line.bbox = line.words.reduce((box, word) => ({
      x0: Math.min(box.x0, word.bbox.x0),
      y0: Math.min(box.y0, word.bbox.y0),
      x1: Math.max(box.x1, word.bbox.x1),
      y1: Math.max(box.y1, word.bbox.y1)
    }), { x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity });
  }
  return lines.sort((a, b) => a.center - b.center);
}

function joinLine(words) {
  let text = '';
  let previous = null;
  for (const word of words) {
    if (previous) {
      const gap = word.bbox.x0 - previous.bbox.x1;
      const height = Math.min(
        previous.bbox.y1 - previous.bbox.y0,
        word.bbox.y1 - word.bbox.y0
      );
      if (gap > Math.max(2, height * 0.12)) text += ' ';
    }
    text += word.text;
    previous = word;
  }
  return text.replace(/\s+([,.;:!?，。；：！？])/g, '$1').trim();
}

function findFocus(words, focus, imageSize, hint = null) {
  if (!Array.isArray(words) || words.length === 0) return null;
  const width = Math.max(1, imageSize?.width || 1);
  const height = Math.max(1, imageSize?.height || 1);
  const lines = buildLines(words);
  const candidates = [];
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    line.words.forEach((word, wordIndex) => {
      const anchor = coreWord(word.text);
      if (!anchor) return;
      const { x0, y0, x1, y1 } = word.bbox;
      const dx = Math.max(x0 - focus.x, 0, focus.x - x1);
      const dy = Math.max(y0 - focus.y, 0, focus.y - y1);
      const distance = Math.hypot(dx / Math.max(1, width * 0.04), dy / Math.max(1, height * 0.055));
      if (distance > 1.15) return;
      if (anchor.length <= 2 && distance > 0.35) return;
      const centerDistance = Math.hypot(
        ((x0 + x1) / 2 - focus.x) / Math.max(1, width * 0.04),
        ((y0 + y1) / 2 - focus.y) / Math.max(1, height * 0.055)
      );
      const contained = focus.x >= x0 && focus.x <= x1 && focus.y >= y0 && focus.y <= y1;
      candidates.push({ line, lineIndex, word, wordIndex, anchor, distance, centerDistance, contained });
    });
  }
  if (candidates.length === 0) return null;
  candidates.sort((a, b) => {
    if (a.contained !== b.contained) return a.contained ? -1 : 1;
    if (a.distance !== b.distance) return a.distance - b.distance;
    return a.centerDistance - b.centerDistance;
  });
  const best = candidates[0];
  const focusLine = best.line.text;
  const hinted = focusedWordWithHint(best.anchor, hint);
  const anchor = hinted.word || best.anchor;

  // Keep a compact sentence around the focus row. A few neighbouring OCR rows
  // give DeepSeek enough context without sending the rest of the screen.
  const selectedLines = [best.lineIndex];
  for (const direction of [-1, 1]) {
    let cursor = best.lineIndex + direction;
    while (cursor >= 0 && cursor < lines.length && selectedLines.length < 5) {
      const current = lines[cursor];
      const adjacent = lines[cursor - direction];
      const gap = Math.min(
        Math.abs(current.bbox.y1 - adjacent.bbox.y0),
        Math.abs(current.bbox.y0 - adjacent.bbox.y1)
      );
      if (gap > Math.max(current.height, adjacent.height) * 1.8) break;
      selectedLines.push(cursor);
      if (/[.!?。！？]$/.test(current.text) && direction === 1) break;
      cursor += direction;
    }
  }
  selectedLines.sort((a, b) => a - b);
  let sentence = selectedLines.map((index) => lines[index].text).join(' ')
    .replace(/\s+/g, ' ').trim();
  if (sentence.length > 320) {
    const position = sentence.toLowerCase().indexOf(anchor.toLowerCase());
    const start = clamp(position < 0 ? 0 : position - 150, 0, Math.max(0, sentence.length - 320));
    sentence = sentence.slice(start, start + 320).trim();
  }
  return {
    anchor,
    focusLine,
    sentence: sentence || focusLine,
    focusWordIndex: clamp(best.wordIndex, 0, Math.max(0, clipboardWords(focusLine).length - 1)),
    distance: best.distance,
    rowBox: best.line.bbox,
    confidence: best.word.confidence,
    usedHint: hinted.usedHint,
    rows: lines.map((line) => line.text)
  };
}

module.exports = {
  createOcrService,
  extractWords,
  buildLines,
  findFocus,
  joinLine
};
