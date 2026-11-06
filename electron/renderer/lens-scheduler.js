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
    let rafId = null;

    function requestNextFrame() {
      if (!rendering || rafId !== null) return false;
      rafId = requestFrame(tick);
      return true;
    }

    function tick() {
      rafId = null;
      if (!rendering) return;
      try {
        if (!suppressed) drawFrame();
      } finally {
        // Re-arm even when drawing throws or the lens is suppressed. This is
        // the invariant the old implementation broke by returning early.
        requestNextFrame();
      }
    }

    function ensureRendering() {
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
      if (suppressed) return false;
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

    return {
      ensureRendering,
      stop,
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
