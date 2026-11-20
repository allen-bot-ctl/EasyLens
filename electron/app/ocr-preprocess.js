'use strict';

// Preprocess cropped BGRA screen captures for Tesseract.js.
// Tesseract's LSTM model expects dark glyphs on a clean white background:
// - Dark mode (avg luma < 128): invert luminance and push both the dark
//   background and blue selection highlight (> 155 after inversion) to white.
// - Light mode (avg luma >= 128): push light-blue selection highlights and the
//   semi-transparent gray eye overlay (> 125) to pure white while stretching
//   dark glyphs (30..125) to crisp black-on-white.

function preprocessCaptureBitmap(bgra, width, height) {
  const pixelCount = width * height;
  if (!bgra || pixelCount <= 0 || bgra.length < pixelCount * 4) return null;

  let sum = 0;
  for (let i = 0; i < pixelCount * 4; i += 4) {
    // Electron nativeImage.toBitmap() uses BGRA byte order.
    sum += 0.114 * bgra[i] + 0.587 * bgra[i + 1] + 0.299 * bgra[i + 2];
  }
  const avg = sum / pixelCount;
  const isDark = avg < 128;

  const out = Buffer.allocUnsafe(pixelCount * 4);
  for (let i = 0; i < pixelCount * 4; i += 4) {
    const luma = 0.114 * bgra[i] + 0.587 * bgra[i + 1] + 0.299 * bgra[i + 2];
    let v;
    if (isDark) {
      const inv = 255 - luma;
      v = inv > 155
        ? 255
        : Math.max(0, Math.min(255, Math.round(((inv - 40) * 255) / 115)));
    } else {
      v = luma > 125
        ? 255
        : Math.max(0, Math.min(255, Math.round(((luma - 30) * 255) / 95)));
    }
    out[i] = v;
    out[i + 1] = v;
    out[i + 2] = v;
    out[i + 3] = 255;
  }
  return out;
}

module.exports = {
  preprocessCaptureBitmap,
  preprocessDarkBitmap: preprocessCaptureBitmap
};
