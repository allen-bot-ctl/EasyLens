'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createLensScheduler } = require('../electron/renderer/lens-scheduler');

function createHarness(drawFrame) {
  let nextFrameId = 1;
  let draws = 0;
  const pendingFrames = new Map();
  const scheduler = createLensScheduler({
    drawFrame: drawFrame || (() => { draws += 1; }),
    requestFrame(callback) {
      const id = nextFrameId;
      nextFrameId += 1;
      pendingFrames.set(id, callback);
      return id;
    },
    cancelFrame(id) {
      pendingFrames.delete(id);
    }
  });
  return {
    scheduler,
    get draws() { return draws; },
    pending() { return pendingFrames.size; },
    flush() {
      const callbacks = [...pendingFrames.values()];
      pendingFrames.clear();
      callbacks.forEach((callback) => callback());
    }
  };
}

test('lens loop keeps scheduling across suppress and redraws after resume', () => {
  const harness = createHarness();

  harness.scheduler.ensureRendering();
  assert.equal(harness.pending(), 1);
  harness.flush();
  assert.equal(harness.draws, 1);
  assert.equal(harness.pending(), 1);

  harness.scheduler.setSuppressed(true);
  harness.flush();
  assert.equal(harness.draws, 1, 'suppressed frames must not paint');
  assert.equal(harness.pending(), 1, 'suppressed frames must keep the loop armed');

  harness.scheduler.setSuppressed(false);
  assert.equal(harness.draws, 2, 'resume paints one complete frame immediately');
  assert.equal(harness.pending(), 1);

  harness.flush();
  assert.equal(harness.draws, 3);
  assert.equal(harness.pending(), 1);
  harness.flush();
  assert.equal(harness.draws, 4);
  assert.equal(harness.pending(), 1);
});

test('a stopped loop is restarted by a suppress false wake event', () => {
  const harness = createHarness();
  harness.scheduler.ensureRendering();
  harness.flush();
  assert.equal(harness.draws, 1);

  harness.scheduler.stop();
  assert.equal(harness.pending(), 0);
  assert.equal(harness.scheduler.isRendering(), false);

  harness.scheduler.setSuppressed(true);
  harness.scheduler.setSuppressed(false);
  assert.equal(harness.scheduler.isRendering(), true);
  assert.equal(harness.draws, 2, 'wake redraws without waiting for a frame');
  assert.equal(harness.pending(), 1);

  harness.flush();
  assert.equal(harness.draws, 3);
  assert.equal(harness.pending(), 1);
});

test('a paint error does not break the animation loop', () => {
  let calls = 0;
  const harness = createHarness(() => {
    calls += 1;
    if (calls === 1) throw new Error('paint failed');
  });

  harness.scheduler.ensureRendering();
  assert.throws(() => harness.flush(), /paint failed/);
  assert.equal(harness.pending(), 1, 'next frame is armed in finally');

  harness.flush();
  assert.equal(calls, 2);
  assert.equal(harness.pending(), 1);
});

test('redraw is a no-op while suppressed', () => {
  const harness = createHarness();
  harness.scheduler.setSuppressed(true);
  assert.equal(harness.scheduler.redraw(), false);
  assert.equal(harness.draws, 0);
  assert.equal(harness.pending(), 0);
});
