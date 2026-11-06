'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  POINTER_MOVE_PX,
  distanceFrom,
  classifyPointerMove,
  shouldReopenInspection,
  shouldResetFocus,
  captureHidesLens,
  shouldSuppressLensForCapture,
  markInspectionComplete,
  scheduleCaptureRetry,
  screenPermissionCard,
  shouldCancelPendingWord,
  shouldReuseCapture,
  missLimit,
  acceptWordResult,
  acceptSelectionResult,
  remoteErrorMessage,
  remoteErrorCard
} = require('../electron/app/focus-session');

const wordKey = 'meeting\nwe are in a meeting now';
const otherKey = 'calendar\nopen the calendar now';
const result = { chinese: '会议', basis: '语境翻译' };

test('a micro-move keeps the same-key response and its cache entry', () => {
  assert.equal(classifyPointerMove(4), 'micro-move');
  assert.equal(shouldResetFocus(4), false);

  const outcome = acceptWordResult({
    cache: new Map(),
    visible: true,
    pendingKey: wordKey,
    key: wordKey,
    currentAnchor: 'meeting',
    anchor: 'meeting',
    result
  });
  assert.equal(outcome.display, true);
  assert.deepEqual(outcome.cache.get(wordKey), result);
});

test('an obvious word change keeps the cache but does not show the stale card', () => {
  assert.equal(classifyPointerMove(20), 'focus-change');
  assert.equal(shouldResetFocus(20), true);

  const cache = new Map();
  const outcome = acceptWordResult({
    cache,
    visible: true,
    pendingKey: otherKey,
    key: wordKey,
    currentAnchor: 'calendar',
    anchor: 'meeting',
    result
  });
  assert.equal(outcome.display, false);
  assert.deepEqual(outcome.cache.get(wordKey), result);
  assert.equal(cache.size, 0, 'the input cache must not be mutated directly');
});

test('selection results are cached before display and ignore stale text', () => {
  const shown = acceptSelectionResult({
    cache: new Map(),
    visible: true,
    pendingText: 'hello world',
    text: 'hello world',
    activeSelectionHint: 'hello world',
    result: '你好世界'
  });
  assert.equal(shown.display, true);
  assert.equal(shown.cache.get('hello world'), '你好世界');

  const stale = acceptSelectionResult({
    cache: shown.cache,
    visible: true,
    pendingText: 'another paragraph',
    text: 'hello world',
    activeSelectionHint: 'another paragraph',
    result: '你好世界'
  });
  assert.equal(stale.display, false);
  assert.equal(stale.cache.get('hello world'), '你好世界');
});

test('remote failures map to visible, short card text', () => {
  assert.equal(remoteErrorMessage({ code: 'timeout' }), 'DeepSeek 连接超时');
  assert.equal(remoteErrorMessage({ code: 'network' }), 'DeepSeek 连接失败');
  assert.equal(remoteErrorMessage({ code: 'http', status: 401 }),
    'DeepSeek 请求失败（HTTP 401）');
  assert.equal(remoteErrorMessage({ code: 'missing-key' }), 'DeepSeek 未配置 API Key');
  assert.equal(remoteErrorMessage({ code: 'key-storage' }), '无法读取 DeepSeek API Key');
  assert.equal(remoteErrorMessage(new Error('boom')), 'DeepSeek 请求失败');

  const wordCard = remoteErrorCard({ kind: 'word', anchor: 'meeting', error: { code: 'timeout' } });
  assert.equal(wordCard.kind, 'word');
  assert.match(wordCard.title, /meeting/);
  assert.equal(wordCard.text, 'DeepSeek 连接超时');

  const selectionCard = remoteErrorCard({ kind: 'selection', error: { code: 'network' } });
  assert.equal(selectionCard.kind, 'selection');
  assert.equal(selectionCard.text, 'DeepSeek 连接失败');
});

test('pending remote requests tolerate more OCR misses before cancellation', () => {
  assert.equal(missLimit(false), 2);
  assert.equal(missLimit(true), 4);
});

test('capture gate skips repeated frames at the same spot and anchor', () => {
  const lastCapturePointer = { x: 100, y: 100 };
  assert.equal(shouldReuseCapture({
    now: 10.1,
    lastCaptureAt: 10,
    pointer: { x: 103, y: 102 },
    lastCapturePointer,
    anchor: 'meeting',
    lastCaptureAnchor: 'meeting'
  }), true);
  assert.equal(shouldReuseCapture({
    now: 11,
    lastCaptureAt: 10,
    pointer: { x: 103, y: 102 },
    lastCapturePointer,
    anchor: 'meeting',
    lastCaptureAnchor: 'meeting'
  }), false);
  assert.equal(shouldReuseCapture({
    now: 10.1,
    lastCaptureAt: 10,
    pointer: { x: 140, y: 100 },
    lastCapturePointer,
    anchor: 'meeting',
    lastCaptureAnchor: 'meeting'
  }), false);
});

test('only Linux needs to hide the real lens window during capture', () => {
  assert.equal(captureHidesLens('linux'), true);
  assert.equal(captureHidesLens('darwin'), false);
  assert.equal(captureHidesLens('win32'), false);
});

test('only Linux suppresses lens paint around a capture', () => {
  assert.equal(shouldSuppressLensForCapture('linux'), true);
  assert.equal(shouldSuppressLensForCapture('darwin'), false);
  assert.equal(shouldSuppressLensForCapture('win32'), false);
});

test('a completed hit, miss, error or reuse scan does not schedule another capture', () => {
  for (const generation of [1, 7, 42]) {
    const state = { generation, inspectedGeneration: -1, nextInspectionAt: 0 };
    markInspectionComplete(state);
    assert.equal(state.inspectedGeneration, state.generation);
    assert.equal(state.inspectedGeneration !== state.generation, false,
      'tick must not inspect the same stationary spot again');
  }

  const state = { generation: 9, inspectedGeneration: -1, nextInspectionAt: 0 };
  markInspectionComplete(state);
  assert.equal(state.inspectedGeneration, state.generation);

  // A stationary pointer keeps the completed scan closed.
  assert.equal(classifyPointerMove(0), 'stationary');
  assert.equal(classifyPointerMove(2.9), 'stationary');
  assert.equal(state.inspectedGeneration, state.generation);

  // Any real move (>=3px) reopens inspection; only >=16px breaks the focus.
  assert.equal(classifyPointerMove(3), 'micro-move');
  state.inspectedGeneration = -1;
  assert.equal(state.inspectedGeneration !== state.generation, true);
  assert.equal(shouldResetFocus(15.9), false);
  assert.equal(shouldResetFocus(16), true);
});

test('sentence jitter keeps a pending DeepSeek word request alive', () => {
  assert.equal(shouldCancelPendingWord({
    currentAnchor: 'meeting',
    nextAnchor: 'meeting',
    distance: 0
  }), false);
  assert.equal(shouldCancelPendingWord({
    currentAnchor: 'meeting',
    nextAnchor: 'meeting',
    distance: 15.9
  }), false);
  assert.equal(shouldCancelPendingWord({
    currentAnchor: 'meeting',
    nextAnchor: 'meeting',
    distance: 16
  }), true);
  assert.equal(shouldCancelPendingWord({
    currentAnchor: 'meeting',
    nextAnchor: 'calendar',
    distance: 0
  }), true);
  assert.equal(shouldCancelPendingWord({
    currentAnchor: null,
    nextAnchor: 'meeting',
    distance: 0
  }), true);
});

test('a stale successful word result still lands in the cache', () => {
  const outcome = acceptWordResult({
    cache: new Map(),
    visible: true,
    pendingKey: null,
    key: wordKey,
    currentAnchor: 'calendar',
    anchor: 'meeting',
    result
  });
  assert.equal(outcome.display, false);
  assert.deepEqual(outcome.cache.get(wordKey), result);
});

test('slow accumulated movement reopens inspection from the last successful scan', () => {
  assert.equal(POINTER_MOVE_PX, 3);
  const lastInspectedPointer = { x: 100, y: 100 };

  // Four ticks of a slow 1px move: the per-frame delta is always 1px, but the
  // scan-anchor distance accumulates to 4px and must reopen.
  const afterFourPixels = distanceFrom({ x: 104, y: 100 }, lastInspectedPointer);
  assert.equal(afterFourPixels, 4);
  assert.equal(shouldReopenInspection(afterFourPixels), true);

  const belowThreshold = distanceFrom({ x: 102.9, y: 100 }, lastInspectedPointer);
  assert.equal(shouldReopenInspection(belowThreshold), false);
  assert.equal(shouldReopenInspection(2.9), false);
  assert.equal(shouldReopenInspection(3), true);
});

test('marking a completed scan advances the scan anchor and generation', () => {
  const state = {
    generation: 12,
    inspectedGeneration: -1,
    lastInspectedPointer: { x: 10, y: 10 }
  };
  markInspectionComplete(state, { x: 44, y: 55 });
  assert.equal(state.inspectedGeneration, 12);
  assert.deepEqual(state.lastInspectedPointer, { x: 44, y: 55 });

  // A capture failure must not move the anchor; the caller simply never calls
  // markInspectionComplete with the failed scan pointer.
  const failed = {
    generation: 12,
    inspectedGeneration: -1,
    lastInspectedPointer: { x: 10, y: 10 }
  };
  scheduleCaptureRetry(failed, 20);
  assert.deepEqual(failed.lastInspectedPointer, { x: 10, y: 10 });
  assert.equal(failed.inspectedGeneration, -1);
  assert.equal(failed.nextInspectionAt, 20.8);
});

test('capture failure retries in 800ms instead of completing the spot', () => {
  const state = {
    generation: 3,
    inspectedGeneration: 3,
    nextInspectionAt: 0,
    lastCaptureAt: 9,
    lastCapturePointer: { x: 5, y: 5 },
    lastCaptureAnchor: 'meeting'
  };
  scheduleCaptureRetry(state, 10);
  assert.equal(state.inspectedGeneration, -1,
    'the same spot must be reopened without requiring a pointer move');
  assert.equal(state.nextInspectionAt, 10.8);
  assert.equal(state.lastCaptureAt, 0);
  assert.equal(state.lastCapturePointer, null);
  assert.equal(state.lastCaptureAnchor, null);

  // In contrast, a successful OCR miss marks the generation complete and does
  // not schedule a blank-text recapture loop.
  const missed = { generation: 3, inspectedGeneration: -1, nextInspectionAt: 0 };
  markInspectionComplete(missed, { x: 7, y: 8 });
  assert.equal(missed.inspectedGeneration, 3);
  assert.equal(missed.nextInspectionAt, 0);
});

test('screen permission card uses the visible word card shape', () => {
  const card = screenPermissionCard();
  assert.equal(card.kind, 'word');
  assert.equal(card.title, '需要屏幕录制权限');
  assert.equal(card.text, '请在系统设置中允许 EasyLens 录屏，以便识别光标下的英文单词。');
});
