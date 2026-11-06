'use strict';

// Pure focus/request lifecycle helpers. Electron's main process keeps the
// mutable state, but these decisions are isolated here so the macOS trackpad
// jitter and DeepSeek in-flight behaviour can be unit tested without a display.

const POINTER_MOVE_PX = 3;
const FOCUS_BREAK_PX = 16;
const CAPTURE_MIN_INTERVAL_SECONDS = 0.4;
const CAPTURE_SAME_SPOT_PX = 8;
const MISS_LIMIT_IDLE = 2;
const MISS_LIMIT_PENDING = 4;

function classifyPointerMove(distance) {
  if (!Number.isFinite(distance) || distance < POINTER_MOVE_PX) return 'stationary';
  return distance >= FOCUS_BREAK_PX ? 'focus-change' : 'micro-move';
}

function shouldResetFocus(distance) {
  return classifyPointerMove(distance) === 'focus-change';
}

// Linux transparent always-on-top windows still occlude a root-window capture,
// so only that platform briefly hides the real window. Hiding/re-showing on
// macOS/Windows causes WindowServer churn and the visible eye flicker.
function captureHidesLens(platform) {
  return platform === 'linux';
}

// Suppressing paint exists only to make the Linux root-window capture clean.
// macOS/Windows keep the eye painted; the lens already has a transparent hole
// over the word, so there is no need to dim the whole window around each shot.
function shouldSuppressLensForCapture(platform) {
  return platform === 'linux';
}

// The current pointer position has been scanned (hit, miss, error or reuse).
// Keeping inspectedGeneration equal to generation is the invariant that stops
// tick() from recapturing the same stationary spot. Only a real pointer move
// can reset it and reopen inspection.
function markInspectionComplete(state) {
  if (!state) return state;
  state.inspectedGeneration = state.generation;
  return state;
}

// OCR sentence punctuation can jitter while the anchor stays the same. Keep
// the in-flight DeepSeek request alive unless the word changed or the pointer
// made a real focus-break move.
function shouldCancelPendingWord({ currentAnchor, nextAnchor, distance }) {
  const current = currentAnchor || null;
  const next = nextAnchor || null;
  if (current !== next) return true;
  return Number.isFinite(distance) && distance >= FOCUS_BREAK_PX;
}

function shouldReuseCapture({
  now,
  lastCaptureAt,
  pointer,
  lastCapturePointer,
  anchor,
  lastCaptureAnchor
}) {
  if (!(lastCaptureAt > 0) || !lastCapturePointer || !pointer) return false;
  const elapsed = now - lastCaptureAt;
  if (elapsed < 0 || elapsed >= CAPTURE_MIN_INTERVAL_SECONDS) return false;
  const distance = Math.hypot(
    pointer.x - lastCapturePointer.x,
    pointer.y - lastCapturePointer.y
  );
  if (distance > CAPTURE_SAME_SPOT_PX) return false;
  return (anchor || null) === (lastCaptureAnchor || null);
}

function missLimit(hasPendingRemote) {
  return hasPendingRemote ? MISS_LIMIT_PENDING : MISS_LIMIT_IDLE;
}

function isCurrentWordRequest({ pendingKey, key, remoteLoading }) {
  return Boolean(
    pendingKey === key &&
    remoteLoading &&
    remoteLoading.type === 'word' &&
    remoteLoading.key === key
  );
}

function isCurrentSelectionRequest({ pendingText, requestId, text, remoteLoading }) {
  return Boolean(
    pendingText === text &&
    remoteLoading &&
    remoteLoading.type === 'selection' &&
    remoteLoading.requestId === requestId &&
    remoteLoading.text === text
  );
}

// Cache first, then decide whether this result still belongs to the visible
// focus. A micro-move keeps the same pending key, so a successful DeepSeek
// response is shown; an obvious word change keeps the cache but skips the card.
function acceptWordResult({
  cache,
  visible,
  pendingKey,
  key,
  currentAnchor,
  anchor,
  result
}) {
  const nextCache = new Map(cache || []);
  if (result && result.chinese) nextCache.set(key, result);
  const display = Boolean(
    visible &&
    result &&
    result.chinese &&
    pendingKey === key &&
    currentAnchor &&
    currentAnchor === anchor
  );
  return { cache: nextCache, display };
}

function acceptSelectionResult({
  cache,
  visible,
  pendingText,
  text,
  activeSelectionHint,
  result
}) {
  const nextCache = new Map(cache || []);
  if (typeof result === 'string' && result) nextCache.set(text, result);
  const display = Boolean(
    visible &&
    typeof result === 'string' &&
    result &&
    pendingText === text &&
    activeSelectionHint === text
  );
  return { cache: nextCache, display };
}

function remoteErrorMessage(error) {
  const code = error && error.code;
  if (code === 'timeout') return 'DeepSeek 连接超时';
  if (code === 'network') return 'DeepSeek 连接失败';
  if (code === 'http') {
    return error.status
      ? `DeepSeek 请求失败（HTTP ${error.status}）`
      : 'DeepSeek 请求失败';
  }
  if (code === 'empty') return 'DeepSeek 未返回译文';
  if (code === 'bad-response') return 'DeepSeek 返回异常';
  if (code === 'missing-key') return 'DeepSeek 未配置 API Key';
  if (code === 'key-storage') return '无法读取 DeepSeek API Key';
  if (code === 'invalid-url') return 'DeepSeek 接口地址无效';
  if (code === 'invalid-model') return 'DeepSeek 模型不可用';
  if (code === 'configuration' || code === 'invalid-provider') return 'DeepSeek 配置不可用';
  return 'DeepSeek 请求失败';
}

function remoteErrorCard({ kind, anchor, error }) {
  const text = remoteErrorMessage(error);
  if (kind === 'selection') {
    return { kind: 'selection', title: '选区翻译 · DeepSeek', text };
  }
  return {
    kind: 'word',
    title: anchor ? `${anchor} · DeepSeek` : 'DeepSeek',
    text
  };
}

module.exports = {
  POINTER_MOVE_PX,
  FOCUS_BREAK_PX,
  CAPTURE_MIN_INTERVAL_SECONDS,
  CAPTURE_SAME_SPOT_PX,
  classifyPointerMove,
  shouldResetFocus,
  captureHidesLens,
  shouldSuppressLensForCapture,
  markInspectionComplete,
  shouldCancelPendingWord,
  shouldReuseCapture,
  missLimit,
  isCurrentWordRequest,
  isCurrentSelectionRequest,
  acceptWordResult,
  acceptSelectionResult,
  remoteErrorMessage,
  remoteErrorCard
};
