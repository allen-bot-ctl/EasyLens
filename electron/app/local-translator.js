'use strict';

const { normalizeSourceSelectionParagraphs, clipboardWords } = require('./focus-text');
const { glossFor, lookup } = require('./local-dictionary');

// The Linux build has no macOS Translation framework. This is a deliberately
// modest offline fallback: exact phrase lookup first, then a dictionary gloss
// for each word. It is understandable but not a grammatical machine translation.
function translateWord(anchor) {
  const found = glossFor(anchor, 64);
  if (!found || !found.text) return null;
  return { chinese: found.text, basis: found.form === 'inflection' ? '本地词形' : '本地词典' };
}

function translateExactPhrase(line) {
  const key = line.trim();
  if (!key || key.length > 80) return null;
  const found = lookup(key);
  if (!found) return null;
  const gloss = glossFor(key, 160);
  if (!gloss || !gloss.text) return null;
  return gloss.text;
}

function translateLine(line) {
  const exact = translateExactPhrase(line);
  if (exact) return exact;

  const parts = line.split(/([A-Za-z]+(?:['’][A-Za-z]+)?)/g);
  let translatedWords = 0;
  let totalWords = 0;
  const output = parts.map((part) => {
    if (!/^[A-Za-z]/.test(part)) return part;
    totalWords += 1;
    const found = glossFor(part, 28);
    if (!found || !found.text) return part;
    translatedWords += 1;
    return found.text;
  });
  if (translatedWords === 0) return null;
  // If nearly everything is unknown, exposing the raw English is more honest
  // than presenting a two-word gloss as a translation of the paragraph.
  if (totalWords >= 4 && translatedWords / totalWords < 0.34) return null;
  return output.join('').replace(/\s+/g, ' ').trim();
}

function translateSelection(source) {
  const normalized = normalizeSourceSelectionParagraphs(source);
  if (!normalized) return null;
  const lines = normalized.split('\n').map((line) => line.trim()).filter(Boolean);
  const translated = [];
  for (const line of lines) {
    const value = translateLine(line);
    if (value) translated.push(value);
  }
  if (translated.length === 0) return null;
  return {
    chinese: translated.join('\n'),
    basis: '本地词典逐词',
    quality: 'fallback'
  };
}

function coverage(text) {
  const words = clipboardWords(text);
  if (words.length === 0) return 0;
  const known = words.filter((word) => lookup(word)).length;
  return known / words.length;
}

module.exports = {
  translateWord,
  translateSelection,
  coverage
};
