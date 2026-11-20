'use strict';

// Preprocess cropped BGRA screen captures for Tesseract.js.
// Tesseract's LSTM model expects dark glyphs on a light background; on dark-mode
// UIs — especially with semi-bright blue selection highlights (luma ~80-95) —
// raw captures collapse into garbage or empty results. When a crop is dark
// overall (average luminance < 128), invert luminance and push both the dark
// background and blue selection highlight (> 155 after inversion) to pure white,
// stretching the remaining glyph range into crisp black-on-white.

function preprocessDarkBitmap(bgra, width, height) {
  const pixelCount = width * height;
  if (!bgra || pixelCount <= 0 || bgra.length < pixelCount * 4) return null;

  let sum = 0;
  for (let i = 0; i < pixelCount * 4; i += 4) {
    // Electron nativeImage.toBitmap() uses BGRA byte order.
    sum += 0.114 * bgra[i] + 0.587 * bgra[i + 1] + 0.299 * bgra[i + 2];
  }
  const avg = sum / pixelCount;
  if (avg >= 128) return null;

  const out = Buffer.allocUnsafe(pixelCount * 4);
  for (let i = 0; i < pixelCount * 4; i += 4) {
    const luma = 0.114 * bgra[i] + 0.587 * bgra[i + 1] + 0.299 * bgra[i + 2];
    const inv = 255 - luma;
    const v = inv > 155
      ? 255
      : Math.max(0, Math.min(255, Math.round(((inv - 40) * 255) / 115)));
    out[i] = v;
    out[i + 1] = v;
    out[i + 2] = v;
    out[i + 3] = 255;
  }
  return out;
}

module.exports = { preprocessDarkBitmap };
