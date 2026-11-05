'use strict';

// Pure text logic ported from Sources/EasyLens/FocusText.swift and
// SelectionReader.swift. Keeping it free of Electron makes it unit-testable on
// Linux and usable by the OCR, local translator and DeepSeek paths.

const focusMarker = '⟦X⟧';

const relativeTimeRegex =
  /\b([0-9]+)?\s*(seconds?|minutes?|hours?|days?|weeks?|months?|years?)\s*ago\b/i;

const clipboardWordRegex = /[A-Za-z]+(?:['’][A-Za-z]+)?/g;

const proseCommentPrefix = /^\s*(?:\/\/+|#|\/\*+|\*+)\s*/;
const proseCommentWords = /[A-Za-z]+(?:['’][A-Za-z]+)?/g;

const knownMixedCaseWords = new Set([
  'iphone', 'ipad', 'ipod', 'imac', 'icloud', 'ios', 'macos', 'watchos',
  'tvos', 'visionos', 'ebay', 'email', 'ecommerce', 'youtube', 'deepseek',
  'openai', 'chatgpt', 'github', 'gitlab', 'javascript', 'typescript',
  'wordpress', 'linkedin', 'playstation', 'mastercard', 'paypal', 'tiktok',
  'wechat', 'whatsapp', 'powerpoint', 'onedrive', 'garageband', 'facetime',
  'macbook', 'airpods', 'easylens', 'screencapturekit', 'appkit', 'swiftui',
  'webkit'
]);

const paragraphStarterWords = new Set([
  'we', 'you', 'they', 'he', 'she', 'it', 'the', 'this', 'these', 'that',
  'those', 'in', 'on', 'at', 'for', 'to', 'from', 'with', 'by', 'as', 'if',
  'when', 'while', 'before', 'after', 'besides', 'however', 'therefore',
  'please', 'our', 'your', 'their', 'here', 'there', 'what', 'why', 'how',
  'where', 'who', 'understanding', 'although', 'because', 'since', 'unless',
  'until', 'whether'
]);

function relativeTimeChinese(source) {
  const match = source.match(relativeTimeRegex);
  if (!match || match[0] !== source) return null;
  const count = match[1] || '';
  const unit = match[2].toLowerCase();
  let chinese;
  if (unit.startsWith('second')) chinese = '秒';
  else if (unit.startsWith('minute')) chinese = '分钟';
  else if (unit.startsWith('hour')) chinese = '小时';
  else if (unit.startsWith('day')) chinese = '天';
  else if (unit.startsWith('week')) chinese = '周';
  else if (unit.startsWith('month')) chinese = '个月';
  else chinese = '年';
  return `${count}${chinese}前`;
}

function cleanChineseTerm(text) {
  if (typeof text !== 'string') return null;
  const value = text.trim();
  const scalars = [...value];
  if (scalars.length < 1 || scalars.length > 8) return null;
  if (!scalars.every((ch) => {
    const code = ch.codePointAt(0);
    return code >= 0x3400 && code <= 0x9fff;
  })) return null;
  return value;
}

function clipboardWords(text) {
  if (!text) return [];
  return [...text.matchAll(clipboardWordRegex)].map((match) =>
    match[0].toLowerCase().replaceAll('’', "'")
  );
}

function englishDominant(text) {
  let latin = 0;
  let han = 0;
  for (const ch of text) {
    const code = ch.codePointAt(0);
    if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122)) latin += 1;
    else if (code >= 0x3400 && code <= 0x9fff) han += 1;
  }
  return han === 0 ? latin > 0 : latin >= Math.max(12, han * 3);
}

function proseCommentBodyRange(line) {
  const match = line.match(proseCommentPrefix);
  if (!match) return null;
  const body = line.slice(match[0].length);
  const directive = body.trim().toLowerCase();
  if (match[0].includes('#') &&
      ['include', 'define', 'import', 'pragma', 'endif'].some((word) => directive.startsWith(word))) {
    return null;
  }
  const words = body.match(proseCommentWords) || [];
  if (body.includes('/') || body.includes('\\') || words.length < 2) return null;
  return { start: match[0].length, text: body };
}

function looksLikePathOrCode(line) {
  if (proseCommentBodyRange(line)) return false;
  if (line.includes('/') || line.includes('\\') || line.includes('://')) return true;
  const lower = line.toLowerCase();
  return ['.app', '.swift', '.mjs', '.js', '.json', '.py', '.md', '.png', '.jpg']
    .some((suffix) => lower.includes(suffix));
}

function isWordLike(text) {
  return /^[A-Za-z]{2,24}$/.test(text) ||
    /^[A-Z]$/.test(text) ||
    /^[A-Za-z]{2,20}'[A-Za-z]{1,5}$/.test(text);
}

function splitGluedBlockSeams(line) {
  const afterPunctuation = line.replace(
    /([a-z]{2,}[.?!][”"')]?)(?=[A-Z][a-z]{1,}|[A-Z]\s)/g,
    '$1\n'
  );
  const outputLines = [];
  for (const segment of afterPunctuation.split('\n')) {
    const regex = /\b([A-Za-z][a-z]{1,22})([A-Z][a-z]{1,22})\b(?=\s+[A-Za-z])/g;
    const matches = [...segment.matchAll(regex)];
    if (matches.length === 0) {
      outputLines.push(segment);
      continue;
    }
    let rebuilt = '';
    let cursor = 0;
    for (const match of matches) {
      const fullToken = match[0];
      const left = match[1];
      const right = match[2];
      const lowerFull = fullToken.toLowerCase();
      let shouldSplit;
      if (knownMixedCaseWords.has(lowerFull) ||
          lowerFull.startsWith('mc') || lowerFull.startsWith('mac') ||
          lowerFull.startsWith('fitz')) {
        shouldSplit = false;
      } else if (left[0] === left[0].toLowerCase() && left[0] !== left[0].toUpperCase()) {
        const leftValid = isWordLike(left);
        const rightValid = isWordLike(right) || paragraphStarterWords.has(right.toLowerCase());
        shouldSplit = leftValid && rightValid;
      } else {
        shouldSplit = isWordLike(left) && paragraphStarterWords.has(right.toLowerCase());
      }
      if (shouldSplit) {
        const splitPoint = match.index + left.length;
        rebuilt += segment.slice(cursor, splitPoint);
        rebuilt += '\n';
        cursor = splitPoint;
      }
    }
    rebuilt += segment.slice(cursor);
    outputLines.push(...rebuilt.split('\n'));
  }
  return outputLines;
}

function normalizeSourceSelectionParagraphs(raw) {
  const cleaned = String(raw ?? '')
    .replaceAll('\uFFFC', '')
    .replaceAll('\u00A0', ' ')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .trim();
  if (!cleaned) return '';

  const bulletChars = new Set(['•', '◦', '▪']);
  const paragraphs = [];
  for (const rawLine of cleaned.split('\n')) {
    for (const seamSplitLine of splitGluedBlockSeams(rawLine)) {
      const line = seamSplitLine.trim();
      if (!line) continue;
      const parts = line.split(/[•◦▪]/).map((part) => part.trim()).filter(Boolean);
      const hasBullet = [...line].some((ch) => bulletChars.has(ch));
      if (parts.length >= 2 && hasBullet) {
        const startsWithBullet = bulletChars.has(line[0]);
        const restHavePeriods = parts.slice(1).every((part) => part.endsWith('.'));
        parts.forEach((part, index) => {
          if (index === 0 && !startsWithBullet &&
              (part.endsWith(':') || (part.endsWith('.') && !restHavePeriods))) {
            paragraphs.push(part);
          } else {
            paragraphs.push(`• ${part}`);
          }
        });
      } else {
        paragraphs.push(line);
      }
    }
  }
  return paragraphs.join('\n');
}

function eligibleEnglishText(raw, maxLength = 4000) {
  const text = normalizeSourceSelectionParagraphs(raw);
  if (text.length < 2 || text.length > maxLength) return null;
  if (!/[A-Za-z]/.test(text)) return null;

  const words = clipboardWords(text);
  if (words.length < 4) {
    if (looksLikePathOrCode(text) || text.includes('{') || text.includes('}')) return null;
  } else {
    const lines = text.split('\n').filter(Boolean);
    const codeOrPathLines = lines.filter((line) =>
      looksLikePathOrCode(line) || line.includes('{') || line.includes('}')
    );
    if (codeOrPathLines.length === lines.length && words.length < 8) return null;
  }

  let hasHan = false;
  for (const ch of text) {
    const code = ch.codePointAt(0);
    if (code >= 0x3400 && code <= 0x9fff) { hasHan = true; break; }
  }
  if (hasHan && !(words.length >= 3 && englishDominant(text))) return null;

  if (words.length >= 3) {
    const stopwords = new Set(['the', 'and', 'of', 'to', 'in', 'is', 'are', 'a', 'an',
      'we', 'you', 'it', 'that', 'this', 'for', 'on', 'with', 'as', 'be', 'or', 'by']);
    const hits = words.filter((word) => stopwords.has(word)).length;
    const asciiLetters = (text.match(/[A-Za-z]/g) || []).length;
    const ratio = asciiLetters / Math.max(1, text.length);
    if (words.length >= 6 && ratio < 0.35 && hits === 0) return null;
  }
  return text;
}

function eligibleClipboardHint(raw) {
  return eligibleEnglishText(raw, 400);
}

function formatSelectionTranslation(text, source = null) {
  let raw = String(text ?? '')
    .replaceAll('\uFFFC', '')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .trim();
  if (!raw) return '';

  if ((raw.startsWith('"') && raw.endsWith('"') && raw.length >= 2) ||
      (raw.startsWith('“') && raw.endsWith('”') && raw.length >= 2)) {
    raw = raw.slice(1, -1).trim();
  }

  const sourceBulletCount = source
    ? source.split('\n').filter((line) => /^[•◦▪]/.test(line.trim())).length
    : 0;

  const bulletChars = new Set(['•', '◦', '▪']);
  const paragraphs = [];

  for (const rawLine of raw.split('\n')) {
    let current = rawLine.trim();
    if (!current) continue;
    if (current.startsWith('#')) {
      current = current.replace(/^#+\s*/, '').trim();
    }
    if (!current) continue;

    const bulletParts = current.split(/[•◦▪]/).map((part) => part.trim()).filter(Boolean);
    if (bulletParts.length >= 2) {
      const startsWithBullet = bulletChars.has(current[0]);
      bulletParts.forEach((part, index) => {
        if (index === 0 && !startsWithBullet &&
            (part.endsWith(':') || part.endsWith('：'))) {
          paragraphs.push(part);
        } else if (index === 0 && !startsWithBullet &&
                   bulletParts.length === 2 && sourceBulletCount < 2) {
          paragraphs.push(part);
        } else {
          paragraphs.push(`• ${part}`);
        }
      });
      continue;
    }

    let splitByMiddleDot = false;
    for (const dot of ['・', '·']) {
      if (!current.includes(dot)) continue;
      const parts = current.split(dot).map((part) => part.trim()).filter(Boolean);
      const isClauseList = parts.length >= 2 &&
        parts.every((part) => part.length >= 6) &&
        parts.some((part) => part.length >= 10 || /[，。；——]/.test(part));
      if (isClauseList) {
        for (const part of parts) {
          paragraphs.push(/^[•-]/.test(part) ? part : `• ${part}`);
        }
        splitByMiddleDot = true;
        break;
      }
    }
    if (splitByMiddleDot) continue;

    if (current.startsWith('•') && !current.startsWith('• ')) {
      current = `• ${current.slice(1).trim()}`;
    }
    paragraphs.push(current);
  }

  return paragraphs.join('\n');
}

function oneMissingCharacter(complete, fragment) {
  const letters = [...complete];
  if (letters.length !== fragment.length + 1) return false;
  return letters.some((_, index) => {
    const candidate = letters.slice();
    candidate.splice(index, 1);
    return candidate.join('') === fragment;
  });
}

function hintSupportsFocus(hint, anchor) {
  const targetWords = clipboardWords(anchor);
  return clipboardWords(hint).some((word) => {
    if (word.length < 2) return false;
    if (targetWords.includes(word)) return true;
    return targetWords.some((target) => target.includes(word) || oneMissingCharacter(target, word));
  });
}

function foldedLetters(text) {
  return [...text.toLowerCase()].filter((ch) => /[a-z]/.test(ch));
}

function oneEditCost(first, second) {
  const allowed = Math.min(first.length, second.length) >= 5 ? 1 : 0;
  if (Math.abs(first.length - second.length) > allowed) return null;
  let left = 0;
  let right = 0;
  let edits = 0;
  while (left < first.length && right < second.length) {
    if (first[left] === second[right]) {
      left += 1;
      right += 1;
      continue;
    }
    edits += 1;
    if (edits > allowed) return null;
    if (first.length >= second.length) left += 1;
    if (second.length >= first.length) right += 1;
  }
  edits += (first.length - left) + (second.length - right);
  return edits <= allowed ? edits : null;
}

function selectedTextAtFocus(hint, anchor, focusLine, focusWordIndex, options = {}) {
  const {
    allowShortOCRNoise = false,
    minimumVerifiedWords = 2,
    minimumVerifiedLetters = 0,
    windowRadius = 2
  } = options;
  if (hint.length > 4000) return null;
  const selected = clipboardWords(hint).map(foldedLetters);
  const visible = clipboardWords(focusLine).map(foldedLetters);
  if (selected.length <= 1 || focusWordIndex < 0 || focusWordIndex >= visible.length ||
      visible[focusWordIndex].length === 0) return null;

  const selectedStarts = [];
  let selectedEnd = 0;
  for (const word of selected) {
    selectedStarts.push(selectedEnd);
    selectedEnd += word.length;
  }
  const source = selected.flat();
  const focus = visible[focusWordIndex];
  const firstRow = Math.max(0, focusWordIndex - windowRadius);
  const lastRow = Math.min(visible.length - 1, focusWordIndex + windowRadius);

  for (let first = 0; first < selected.length; first += 1) {
    for (let last = first; last < Math.min(selected.length, first + 4); last += 1) {
      const start = selectedStarts[first];
      const end = selectedStarts[last] + selected[last].length;
      const focusCost = oneEditCost(focus, source.slice(start, end));
      if (focusCost === null) continue;
      let lower = start;
      let upper = end;
      let edits = focusCost;
      let verifiedWords = 1;
      let conflict = false;
      for (let rowIndex = firstRow; rowIndex <= lastRow; rowIndex += 1) {
        if (rowIndex === focusWordIndex) continue;
        const rowWord = visible[rowIndex];
        let mappedStart;
        if (rowIndex < focusWordIndex) {
          let distance = 0;
          for (let i = rowIndex; i < focusWordIndex; i += 1) distance += visible[i].length;
          mappedStart = start - distance;
        } else {
          let distance = 0;
          for (let i = focusWordIndex + 1; i < rowIndex; i += 1) distance += visible[i].length;
          mappedStart = end + distance;
        }
        const mappedEnd = mappedStart + rowWord.length;
        if (mappedEnd <= 0 || mappedStart >= source.length) continue;
        const cost = mappedStart >= 0 && mappedEnd <= source.length
          ? oneEditCost(rowWord, source.slice(mappedStart, mappedEnd))
          : null;
        if (cost === null) {
          if (allowShortOCRNoise && rowWord.length <= 2) continue;
          conflict = true;
          break;
        }
        verifiedWords += 1;
        edits += cost;
        if (edits > 1) { conflict = true; break; }
        lower = Math.min(lower, mappedStart);
        upper = Math.max(upper, mappedEnd);
      }
      if (conflict) continue;
      const matchedWords = selected.filter((_, index) =>
        selectedStarts[index] >= lower &&
        selectedStarts[index] + selected[index].length <= upper
      ).length;
      if (matchedWords >= minimumVerifiedWords &&
          verifiedWords >= minimumVerifiedWords &&
          upper - lower >= minimumVerifiedLetters) {
        return hint;
      }
    }
  }
  return null;
}

function hintedOCRCorrection(raw, hint) {
  if (!hint) return null;
  const rawLower = raw.toLowerCase().replaceAll('’', "'");
  const candidates = clipboardWords(hint).filter((word) =>
    oneMissingCharacter(word, rawLower) && isWordLike(word)
  );
  return candidates.length === 1 ? candidates[0] : null;
}

function focusedWordWithHint(raw, hint) {
  const ordinary = isWordLike(raw) ? raw : null;
  if ((ordinary === null || ordinary.toLowerCase() !== raw.toLowerCase()) && hint) {
    const hinted = hintedOCRCorrection(raw, hint);
    if (hinted) return { word: hinted, usedHint: true };
  }
  return { word: ordinary ?? (raw.length >= 2 ? raw : null), usedHint: false };
}

function matchSelectionInBlocks(raw, blocks) {
  const trimmedRaw = String(raw ?? '')
    .replaceAll('\uFFFC', '')
    .replaceAll('\u00A0', ' ')
    .trim();
  const cleanedBlocks = blocks
    .map((block) => String(block ?? '').replaceAll('\uFFFC', '').replaceAll('\u00A0', ' ').trim())
    .filter(Boolean);
  if (!trimmedRaw || cleanedBlocks.length <= 1) return null;

  let concatenated = '';
  const ranges = [];
  let offset = 0;
  for (const block of cleanedBlocks) {
    ranges.push({ start: offset, length: block.length, block });
    concatenated += block;
    offset += block.length;
  }
  const matchStart = concatenated.indexOf(trimmedRaw);
  if (matchStart !== -1) {
    const matchEnd = matchStart + trimmedRaw.length;
    const selectedParagraphs = [];
    for (const { start, length, block } of ranges) {
      const blockEnd = start + length;
      if (!(blockEnd > matchStart && start < matchEnd)) continue;
      const sliceStart = Math.max(0, matchStart - start);
      const sliceEnd = Math.min(length, matchEnd - start);
      if (sliceEnd <= sliceStart) continue;
      let slice = block.slice(sliceStart, sliceEnd).trim();
      if (sliceStart > 0 && sliceStart <= 3) {
        const prefix = block.slice(0, sliceStart).trim();
        if (['•', '◦', '▪'].includes(prefix)) slice = `${prefix} ${slice}`;
      }
      if (slice) selectedParagraphs.push(slice);
    }
    if (selectedParagraphs.length > 1) return selectedParagraphs.join('\n');
  }

  const splitOffsets = [];
  let searchStart = 0;
  const stripLeadingBullet = (text) => {
    const trimmed = text.trim();
    for (const marker of ['•', '◦', '▪']) {
      if (trimmed.startsWith(marker)) {
        return { bullet: marker, body: trimmed.slice(1).trim() };
      }
    }
    return { bullet: null, body: trimmed };
  };
  const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

  for (let i = 0; i < cleanedBlocks.length - 1; i += 1) {
    const leftBlock = cleanedBlocks[i];
    const rightBlock = cleanedBlocks[i + 1];
    const { bullet: rightBullet, body: rightBody } = stripLeadingBullet(rightBlock);
    if (leftBlock.length < 4 || rightBody.length < 4 || searchStart >= trimmedRaw.length) continue;

    let matchedSplit = null;
    const suffixLengths = [...new Set([28, 16, 8].map((n) => Math.min(n, leftBlock.length)))]
      .filter((n) => n >= 4).sort((a, b) => b - a);
    const prefixLengths = [...new Set([28, 16, 8].map((n) => Math.min(n, rightBody.length)))]
      .filter((n) => n >= 4).sort((a, b) => b - a);

    for (const suffixLen of suffixLengths) {
      const suffix = leftBlock.slice(leftBlock.length - suffixLen).trim();
      if (suffix.length < 4) continue;
      for (const prefixLen of prefixLengths) {
        const prefix = rightBody.slice(0, prefixLen).trim();
        if (prefix.length < 4) continue;
        const pattern = new RegExp(`${escape(suffix)}\\s*([•◦▪]\\s*)?${escape(prefix)}`);
        const match = trimmedRaw.slice(searchStart).match(pattern);
        if (match) {
          const suffixEnd = searchStart + match.index + suffix.length;
          const hasInlineBullet = match[1] !== undefined && match[1].length > 0;
          matchedSplit = {
            splitAt: suffixEnd,
            insertBullet: !hasInlineBullet ? rightBullet : null
          };
          break;
        }
      }
      if (matchedSplit) break;
    }
    if (matchedSplit && matchedSplit.splitAt > searchStart &&
        matchedSplit.splitAt < trimmedRaw.length) {
      splitOffsets.push(matchedSplit);
      searchStart = matchedSplit.splitAt;
    }
  }

  if (splitOffsets.length === 0) return null;
  const paragraphs = [];
  let cursor = 0;
  splitOffsets.forEach((split, index) => {
    if (split.splitAt <= cursor) return;
    let segment = trimmedRaw.slice(cursor, split.splitAt).trim();
    if (index > 0) {
      const previousBullet = splitOffsets[index - 1].insertBullet;
      if (previousBullet && !/^[•◦▪]/.test(segment)) segment = `${previousBullet} ${segment}`;
    }
    if (segment) paragraphs.push(segment);
    cursor = split.splitAt;
  });
  if (cursor < trimmedRaw.length) {
    let tail = trimmedRaw.slice(cursor).trim();
    const lastBullet = splitOffsets.at(-1)?.insertBullet;
    if (lastBullet && !/^[•◦▪]/.test(tail)) tail = `${lastBullet} ${tail}`;
    if (tail) paragraphs.push(tail);
  }
  return paragraphs.length > 1 ? paragraphs.join('\n') : null;
}

module.exports = {
  focusMarker,
  relativeTimeChinese,
  cleanChineseTerm,
  clipboardWords,
  englishDominant,
  proseCommentBodyRange,
  looksLikePathOrCode,
  isWordLike,
  normalizeSourceSelectionParagraphs,
  eligibleEnglishText,
  eligibleClipboardHint,
  formatSelectionTranslation,
  oneMissingCharacter,
  hintSupportsFocus,
  foldedLetters,
  oneEditCost,
  selectedTextAtFocus,
  hintedOCRCorrection,
  focusedWordWithHint,
  matchSelectionInBlocks
};
