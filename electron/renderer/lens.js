'use strict';

const canvas = document.getElementById('lens');
const context = canvas.getContext('2d');
const WIDTH = 190;
const HEIGHT = 114;

let reading = false;
let translated = false;

function resize() {
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.round(WIDTH * ratio);
  canvas.height = Math.round(HEIGHT * ratio);
  canvas.style.width = `${WIDTH}px`;
  canvas.style.height = `${HEIGHT}px`;
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  scheduler.ensureRendering();
  scheduler.redraw();
}

function eyePath(rect) {
  const path = new Path2D();
  const left = { x: rect.x, y: rect.y + rect.height / 2 - 2 };
  const right = { x: rect.x + rect.width, y: rect.y + rect.height / 2 + 2 };
  path.moveTo(left.x, left.y);
  path.bezierCurveTo(
    rect.x + rect.width * 0.23, rect.y + rect.height / 2 + rect.height * 0.65,
    rect.x + rect.width * 0.73, rect.y + rect.height / 2 + rect.height * 0.65,
    right.x, right.y
  );
  path.bezierCurveTo(
    rect.x + rect.width * 0.77, rect.y + rect.height / 2 - rect.height * 0.56,
    rect.x + rect.width * 0.27, rect.y + rect.height / 2 - rect.height * 0.56,
    left.x, left.y
  );
  path.closePath();
  return path;
}

function draw() {
  const now = performance.now() / 1000;
  context.clearRect(0, 0, WIDTH, HEIGHT);

  const rect = { x: 3, y: 3, width: WIDTH - 6, height: HEIGHT - 6 };
  const center = { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
  const eye = eyePath(rect);

  // Frosted eye body, with a clear centre so the source text stays readable.
  context.save();
  context.fillStyle = 'rgba(18, 21, 27, 0.46)';
  context.fill(eye);
  context.globalCompositeOperation = 'destination-out';
  context.beginPath();
  context.ellipse(
    center.x, center.y,
    rect.height * 0.60, rect.height * 0.40,
    0, 0, Math.PI * 2
  );
  context.fill();
  context.restore();

  const irisRadiusX = rect.height * 0.75;
  const irisRadiusY = rect.height * 0.50;
  const pupil = {
    x: center.x - irisRadiusX * 0.80,
    y: center.y - irisRadiusY * 0.80,
    width: irisRadiusX * 1.60,
    height: irisRadiusY * 1.60
  };

  context.save();
  context.clip(eye);
  context.beginPath();
  context.ellipse(center.x, center.y, irisRadiusX, irisRadiusY, 0, 0, Math.PI * 2);
  context.ellipse(center.x, center.y, pupil.width / 2, pupil.height / 2, 0, 0, Math.PI * 2);
  context.clip('evenodd');
  context.lineCap = 'round';
  for (let index = 0; index < 96; index += 1) {
    const angle = (index / 96) * Math.PI * 2 + Math.sin(index * 2.11) * 0.027;
    const inner = 0.79 + 0.03 * Math.sin(index * 1.7);
    const outer = 0.94 + 0.045 * Math.sin(index * 1.31);
    const middle = (inner + outer) / 2;
    const bend = angle + 0.06 * Math.sin(index * 0.83);
    context.strokeStyle = index % 4 === 0
      ? 'rgba(204, 204, 204, 0.13)'
      : 'rgba(245, 245, 245, 0.07)';
    context.lineWidth = index % 7 === 0 ? 0.9 : 0.55;
    context.beginPath();
    context.moveTo(center.x + Math.cos(angle) * irisRadiusX * inner,
      center.y + Math.sin(angle) * irisRadiusY * inner);
    context.quadraticCurveTo(
      center.x + Math.cos(bend) * irisRadiusX * middle,
      center.y + Math.sin(bend) * irisRadiusY * middle,
      center.x + Math.cos(angle) * irisRadiusX * outer,
      center.y + Math.sin(angle) * irisRadiusY * outer
    );
    context.stroke();
  }
  context.restore();

  context.beginPath();
  context.ellipse(center.x, center.y, pupil.width / 2, pupil.height / 2, 0, 0, Math.PI * 2);
  context.lineWidth = translated ? 1.2 : 0.8;
  context.strokeStyle = translated
    ? 'rgba(255, 214, 64, 0.72)'
    : 'rgba(235, 235, 235, 0.28)';
  context.stroke();

  const eyeBallRadius = (pupil.height * 0.56) / 2;
  context.save();
  context.beginPath();
  context.arc(center.x, center.y, eyeBallRadius, 0, Math.PI * 2);
  context.clip();
  context.lineCap = 'round';
  for (let index = 0; index < 64; index += 1) {
    const angle = index * 2 * Math.PI / 64 + 0.035 * Math.sin(index * 2.37);
    const inner = eyeBallRadius * (0.32 + 0.06 * Math.sin(index * 1.73));
    const outer = eyeBallRadius * (0.78 + 0.16 * Math.sin(index * 0.91));
    const bend = angle + 0.09 * Math.sin(index * 1.19);
    context.strokeStyle = translated
      ? `rgba(255, 214, 64, ${index % 5 === 0 ? 0.34 : 0.20})`
      : `rgba(168, 196, 214, ${index % 5 === 0 ? 0.19 : 0.10})`;
    context.lineWidth = index % 7 === 0 ? 0.7 : 0.45;
    context.beginPath();
    context.moveTo(center.x + Math.cos(angle) * inner, center.y + Math.sin(angle) * inner);
    context.quadraticCurveTo(
      center.x + Math.cos(bend) * eyeBallRadius * 0.60,
      center.y + Math.sin(bend) * eyeBallRadius * 0.60,
      center.x + Math.cos(angle) * outer,
      center.y + Math.sin(angle) * outer
    );
    context.stroke();
  }
  context.restore();

  context.beginPath();
  context.arc(center.x, center.y, eyeBallRadius * 0.27, 0, Math.PI * 2);
  context.lineWidth = 0.55;
  context.strokeStyle = translated
    ? 'rgba(255, 214, 64, 0.30)'
    : 'rgba(242, 242, 242, 0.16)';
  context.stroke();

  context.beginPath();
  context.arc(center.x, center.y, eyeBallRadius, 0, Math.PI * 2);
  context.lineWidth = 0.7;
  context.strokeStyle = 'rgba(245, 245, 245, 0.16)';
  context.stroke();

  // Fine folds toward the right tip.
  context.save();
  context.clip(eye);
  for (let index = 0; index < 8; index += 1) {
    const progress = index / 7;
    const last = index === 7;
    const endX = rect.x + rect.width - index - (last ? 2 : 0);
    const endY = rect.y + rect.height / 2 + 2 - 0.7 * index;
    const startX = center.x + irisRadiusX * (0.48 + 0.47 * progress);
    const startY = last ? endY + 0.8 : center.y + irisRadiusY * (0.74 - 0.90 * progress);
    const dx = endX - startX;
    const dy = startY - endY;
    context.beginPath();
    context.moveTo(startX, startY);
    context.bezierCurveTo(
      startX + dx * 0.32, startY - dy * 0.08,
      endX - dx * 0.22, endY + dy * 0.23,
      endX, endY
    );
    context.lineWidth = last ? 0.5 : 0.62;
    context.lineCap = 'round';
    context.strokeStyle = `rgba(245, 245, 245, ${last ? 0.06 : 0.22 - 0.013 * index})`;
    context.stroke();
  }
  context.restore();

  context.lineWidth = 1.8;
  context.strokeStyle = 'rgba(5, 5, 5, 0.02)';
  context.stroke(eye);
  context.lineWidth = 0.8;
  context.strokeStyle = 'rgba(245, 245, 245, 0.10)';
  context.stroke(eye);

  // Breathing red lamp on the left wing.
  const breath = (1 + Math.sin(now * Math.PI * 2 / 2.2)) / 2;
  const lampX = rect.x + 13;
  const lampY = rect.y + rect.height / 2 - 2;
  context.beginPath();
  context.arc(lampX, lampY, 7, 0, Math.PI * 2);
  context.fillStyle = `rgba(255, 69, 58, ${0.10 + 0.17 * breath})`;
  context.fill();
  context.beginPath();
  context.arc(lampX, lampY, 2.5, 0, Math.PI * 2);
  context.fillStyle = `rgba(255, 69, 58, ${0.58 + 0.35 * breath})`;
  context.fill();

  if (reading && !translated) {
    context.beginPath();
    context.arc(center.x, center.y, eyeBallRadius * 1.8, 0, Math.PI * 2);
    context.lineWidth = 0.7;
    context.strokeStyle = `rgba(180, 210, 230, ${0.10 + 0.08 * breath})`;
    context.stroke();
  }
}

const scheduler = window.EasyLensLensScheduler.createLensScheduler({ drawFrame: draw });

function wakeRenderer() {
  scheduler.ensureRendering();
  scheduler.redraw();
}

window.easylens.onLensState((payload) => {
  if (!payload) return;
  reading = Boolean(payload.reading);
  translated = Boolean(payload.translated);
  wakeRenderer();
});

window.easylens.onLensSuppress((value) => {
  const next = Boolean(value);
  canvas.style.opacity = next ? '0' : '1';
  scheduler.setSuppressed(next);
});

window.easylens.onLensResume(() => {
  wakeRenderer();
});

document.addEventListener('visibilitychange', () => {
  if (!document.hidden) wakeRenderer();
});
window.addEventListener('pageshow', wakeRenderer);
window.addEventListener('focus', wakeRenderer);

resize();
window.addEventListener('resize', resize);
window.easylens.lensReady();
