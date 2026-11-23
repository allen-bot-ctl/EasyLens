'use strict';

// Small, DOM-free animation scheduler shared by the lens renderer and its
// unit tests. Keeping the requestAnimationFrame loop alive while the lens is
// suppressed avoids the "eye disappears forever after the first capture" bug.
(function attach(globalScope) {
  function createLensScheduler(options) {
    const settings = options || {};
    const drawFrame = settings.drawFrame;
    const requestFrame = settings.requestFrame
      || ((callback) => globalScope.requestAnimationFrame(callback));
    const cancelFrame = settings.cancelFrame
      || ((id) => globalScope.cancelAnimationFrame(id));

    if (typeof drawFrame !== 'function') {
      throw new TypeError('createLensScheduler requires a drawFrame function');
    }

    let suppressed = false;
    let rendering = false;
    // Asleep means the lens window is hidden: no frame may be drawn or
    // scheduled until the main process explicitly wakes the lens again.
    let asleep = Boolean(settings.startAsleep);
    let rafId = null;

    function requestNextFrame() {
      if (asleep || !rendering || rafId !== null) return false;
      rafId = requestFrame(tick);
      return true;
    }

    function tick() {
      rafId = null;
      if (asleep || !rendering) return;
      try {
        if (!suppressed) drawFrame();
      } finally {
        // Re-arm even when drawing throws or the lens is suppressed. This is
        // the invariant the old implementation broke by returning early.
        requestNextFrame();
      }
    }

    function ensureRendering() {
      if (asleep) return false;
      rendering = true;
      return requestNextFrame();
    }

    function stop() {
      rendering = false;
      if (rafId !== null) {
        cancelFrame(rafId);
        rafId = null;
      }
    }

    function redraw() {
      if (asleep || suppressed) return false;
      drawFrame();
      return true;
    }

    function setSuppressed(value) {
      suppressed = Boolean(value);
      if (!suppressed) {
        // A false event is also the main process wake signal. Always ensure
        // the loop is armed and paint one complete frame immediately.
        ensureRendering();
        redraw();
      }
    }

    function sleep() {
      asleep = true;
      suppressed = false;
      stop();
    }

    function wake() {
      asleep = false;
      ensureRendering();
      return redraw();
    }

    return {
      ensureRendering,
      stop,
      sleep,
      wake,
      isAsleep: () => asleep,
      redraw,
      setSuppressed,
      isRendering: () => rendering,
      isSuppressed: () => suppressed,
      hasPendingFrame: () => rafId !== null
    };
  }

  const api = { createLensScheduler };
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  } else {
    globalScope.EasyLensLensScheduler = api;
  }
})(typeof window !== 'undefined' ? window : globalThis);
