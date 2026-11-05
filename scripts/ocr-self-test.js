'use strict';

// Verifies the bundled Tesseract language data and the focus geometry without
// launching Electron. Usage: node scripts/ocr-self-test.js [image.png]
const fs = require('node:fs');
const path = require('node:path');
const { createOcrService, findFocus } = require('../electron/app/ocr');

async function main() {
  const imagePath = process.argv[2] || path.join(__dirname, '..', 'electron', 'assets', 'ocr-sample.png');
  const image = fs.readFileSync(imagePath);
  const service = createOcrService({ cachePath: path.join(require('node:os').tmpdir(), 'easylens-ocr-cache') });
  try {
    const words = await service.recognize(image);
    if (words.length === 0) throw new Error('OCR returned no words');
    const target = words.find((word) => /world/i.test(word.text)) || words[0];
    const focus = {
      x: (target.bbox.x0 + target.bbox.x1) / 2,
      y: (target.bbox.y0 + target.bbox.y1) / 2
    };
    // PNG IHDR stores width/height at byte offsets 16 and 20.
    const size = { width: image.readUInt32BE(16), height: image.readUInt32BE(20) };
    const passage = findFocus(words, focus, size);
    console.log('OCR_WORDS=' + words.map((word) => word.text).join(' | '));
    console.log('OCR_FOCUS=' + JSON.stringify({
      anchor: passage?.anchor,
      focusLine: passage?.focusLine,
      sentence: passage?.sentence,
      distance: passage?.distance
    }));
    if (!passage || passage.anchor.toLowerCase() !== 'world') {
      throw new Error('focus did not resolve to world');
    }
    console.log('OCR_SELF_TEST_OK');
  } finally {
    await service.terminate();
  }
}

main().catch((error) => {
  console.error('OCR_SELF_TEST_FAILED', error);
  process.exitCode = 1;
});
