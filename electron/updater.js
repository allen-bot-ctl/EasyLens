'use strict';

const {
  buildFeedUrl,
  interpretFeedProbe,
  interpretLatestRelease,
  LATEST_RELEASE_PAGE,
  RELEASES_LATEST_URL
} = require('./update-feed');
const {
  deriveDmgUrl,
  deriveReleasePageUrl,
  classifyFailure,
  extractVersion
} = require('./mac-self-update');

// The first check runs shortly after launch; later checks are deliberately
// infrequent so the app does not hammer GitHub.
const FIRST_CHECK_DELAY_MS = 10 * 1000;
const CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000;
const FEED_TIMEOUT_MS = 15 * 1000;

const FINAL_STATES = new Set(['up-to-date', 'manual', 'checksum', 'arch', 'available', 'error']);

function timeoutSignal(ms) {
  if (typeof AbortSignal !== 'undefined' &&
      typeof AbortSignal.timeout === 'function') {
    return AbortSignal.timeout(ms);
  }
  return undefined;
}

function errorMessage(error) {
  return error && error.message ? error.message : String(error);
}

function noop() {}

// Probes the official update.electronjs.org feed directly and, when a newer
// release exists, hands the release zip to the in-app self-updater. Squirrel.Mac
// is not used: the ad-hoc signed macOS builds cannot pass Squirrel.Mac's code
// signature check, so macOS always runs in probe-only mode instead of ever
// calling autoUpdater.setFeedURL.
function setupAutoUpdate(options) {
  const {
    app,
    net,
    onReady = noop,
    onManual = noop,
    onStatus,
    isNotified = () => false,
    markNotified = noop,
    selfUpdate = null,
    logger
  } = options;

  const platform = options.platform || process.platform;
  const arch = options.arch || process.arch;
  const schedule = options.schedule !== false;
  const setTimeoutFn = options.setTimeout || setTimeout;
  const clearTimeoutFn = options.clearTimeout || clearTimeout;
  const setIntervalFn = options.setInterval || setInterval;
  const clearIntervalFn = options.clearInterval || clearInterval;
  const probeTimeoutMs = Number.isFinite(options.probeTimeoutMs)
    ? options.probeTimeoutMs
    : FEED_TIMEOUT_MS;

  const log = (message) => {
    if (typeof logger === 'function') logger(message);
  };

  let stopped = false;

  function emitStatus(state, extra) {
    if (stopped) return;
    const manual = Boolean(extra && extra.manual === true);
    if (manual && FINAL_STATES.has(state)) {
      log(`manual check result: ${state}`);
    }
    if (typeof onStatus !== 'function') return;
    try {
      onStatus({ state, ...extra });
    } catch (error) {
      log(`status callback failed: ${errorMessage(error)}`);
    }
  }

  const disabled = {
    mode: 'disabled',
    setupError: null,
    feedUrl: null,
    checkNow(flags) {
      if (flags && flags.manual === true) {
        emitStatus('disabled', { manual: true });
      }
      return { state: 'disabled' };
    },
    stop: () => {}
  };

  // Development runs must stay completely quiet.
  if (app.isPackaged !== true) {
    return disabled;
  }

  const version = app.getVersion();
  const headers = {
    'User-Agent': `EasyLens/${version} (${platform}: ${arch})`
  };

  // Windows / Linux：只检查，有新版时托盘出「下载新版本 X…」，点了打开 Release 页。
  if (platform !== 'darwin') {
    return setupCheckOnly({
      net,
      version,
      headers,
      emitStatus,
      isStopped: () => stopped,
      setStopped: () => { stopped = true; },
      log,
      schedule,
      probeTimeoutMs,
      setTimeoutFn,
      clearTimeoutFn,
      setIntervalFn,
      clearIntervalFn
    });
  }

  const feedUrl = buildFeedUrl({ platform, arch, version });

  let probePromise = null;
  let firstCheckTimer = null;
  let checkTimer = null;

  function announceManual(name, url) {
    const key = `manual:${name || version}`;
    if (isNotified(key)) {
      log(`manual notice already shown for ${key}`);
      return;
    }
    markNotified(key);
    log(`manual update notice for ${name || version}`);
    try {
      onManual({ name, url });
    } catch (error) {
      log(`manual callback failed: ${errorMessage(error)}`);
    }
  }

  // The release page is only the last resort. When a version can be derived we
  // point "下载新版" directly at the DMG asset instead.
  function fallbackManualUrl(...candidates) {
    for (const candidate of candidates) {
      const parsed = extractVersion(candidate);
      if (parsed) {
        const dmgUrl = deriveDmgUrl(parsed, arch);
        if (dmgUrl) return dmgUrl;
        return deriveReleasePageUrl(parsed);
      }
    }
    return RELEASES_LATEST_URL;
  }

  function releasePageUrl(...candidates) {
    for (const candidate of candidates) {
      const parsed = extractVersion(candidate);
      if (parsed) return deriveReleasePageUrl(parsed);
    }
    return RELEASES_LATEST_URL;
  }

  async function runSelfUpdate(result, manual) {
    const name = result.name;
    emitStatus('downloading', { manual, name });

    let outcome;
    try {
      outcome = await selfUpdate.start({ name, url: result.url });
    } catch (error) {
      outcome = {
        ok: false,
        reason: errorMessage(error),
        version: extractVersion(name) || extractVersion(result.url)
      };
    }
    if (stopped) return;

    if (outcome && outcome.ok) {
      const readyName = outcome.name || name;
      log(`self-update ready: ${readyName}`);
      // Keep the normal ready notice so the renderer's existing 「新版本已就绪
      // / 重启更新」 path is reused; the extra flag only switches the install
      // mechanism in the main process.
      try {
        onReady({ name: readyName, mode: 'ready-self' });
      } catch (error) {
        log(`ready callback failed: ${errorMessage(error)}`);
      }
      emitStatus('ready', {
        manual,
        name: readyName,
        selfUpdate: true
      });
      return;
    }

    const reason = outcome && outcome.reason ? outcome.reason : 'unknown';
    log(`self-update failed: ${reason}`);
    const kind = classifyFailure(reason);
    if (kind === 'offline') {
      // 下载中断：半截文件已经删掉，托盘回到「检查更新…」，下一次定时检查再试。
      emitStatus('error', { manual, name, reason });
      return;
    }
    const url = kind === 'arch'
      ? releasePageUrl(outcome && outcome.version, name, result.url)
      : fallbackManualUrl(outcome && outcome.version, name, result.url);
    announceManual(name, url);
    emitStatus(kind, { manual, name, url, reason });
  }

  async function probeFeed() {
    if (!net || typeof net.fetch !== 'function') return { state: 'error' };
    try {
      const response = await net.fetch(feedUrl, {
        headers,
        cache: 'no-store',
        signal: timeoutSignal(probeTimeoutMs)
      });

      let payload = null;
      if (response.status === 200) {
        try {
          payload = await response.json();
        } catch (error) {
          log(`feed probe JSON parse failed: ${errorMessage(error)}`);
          return { state: 'error' };
        }
      } else if (response.status !== 204) {
        log(`feed probe status ${response.status}`);
      }

      return interpretFeedProbe(response.status, payload);
    } catch (error) {
      log(`feed probe failed: ${errorMessage(error)}`);
      return { state: 'error' };
    }
  }

  // Concurrent manual clicks (and an automatic timer firing at the same time)
  // share one in-flight fetch. Each caller still emits its own final state.
  function startProbe() {
    if (!probePromise) {
      probePromise = probeFeed().then(
        (result) => {
          probePromise = null;
          return result;
        },
        (error) => {
          probePromise = null;
          log(`feed probe rejected: ${errorMessage(error)}`);
          return { state: 'error' };
        }
      );
    }
    return probePromise;
  }

  function applyProbeResult(result, manual) {
    if (stopped) return;

    if (result && result.state === 'up-to-date') {
      log('feed probe indicates up-to-date');
      emitStatus('up-to-date', { manual });
      return;
    }

    if (result && result.state === 'manual' && result.name) {
      // Probe-only mode can apply the release zip itself. Preparation is async;
      // 'downloading' gives the manual check immediate feedback while automatic
      // checks stay silent in main.js.
      if (result.url && selfUpdate && selfUpdate.available) {
        void runSelfUpdate(result, manual);
        return;
      }

      const url = fallbackManualUrl(result.name, result.url);
      announceManual(result.name, url);
      emitStatus('manual', { manual, name: result.name, url });
      return;
    }

    log('feed probe did not determine update status');
    emitStatus('error', { manual });
  }

  async function runProbeCheck(manual) {
    const result = await startProbe();
    applyProbeResult(result, manual);
  }

  log(`feed ${feedUrl}`);

  // macOS runs in probe-only mode unconditionally: the ad-hoc signature cannot
  // pass Squirrel.Mac's verification, so setFeedURL is never called.
  log('macOS 未正式签名，使用 probe-only');

  function checkNow(flags) {
    const manual = Boolean(flags && flags.manual === true);
    if (stopped) return { state: 'error', stopped: true };

    log(`${manual ? 'manual' : 'automatic'} check start`);
    if (manual) emitStatus('checking', { manual: true });
    void runProbeCheck(manual);
    return { state: 'checking', mode: 'probe-only' };
  }

  if (schedule) {
    firstCheckTimer = setTimeoutFn(checkNow, FIRST_CHECK_DELAY_MS);
    checkTimer = setIntervalFn(checkNow, CHECK_INTERVAL_MS);
  }

  return {
    mode: 'probe-only',
    setupError: null,
    feedUrl,
    checkNow,
    stop() {
      stopped = true;
      if (firstCheckTimer) clearTimeoutFn(firstCheckTimer);
      if (checkTimer) clearIntervalFn(checkTimer);
      firstCheckTimer = null;
      checkTimer = null;
    }
  };
}

// Windows / Linux check-only mode. Reads GitHub's latest release and reports
// 'available' (with the Release page URL) when the tag is newer.
function setupCheckOnly(ctx) {
  const {
    net,
    version,
    headers,
    emitStatus,
    isStopped,
    setStopped,
    log,
    schedule,
    probeTimeoutMs,
    setTimeoutFn,
    clearTimeoutFn,
    setIntervalFn,
    clearIntervalFn
  } = ctx;

  let probePromise = null;
  let firstCheckTimer = null;
  let checkTimer = null;

  // Electron 31 的 net.fetch 跟随跳转后拿不到最终 URL，redirect:'manual' 又会直接抛错，
  // 所以用 net.request 的 redirect 事件读出 /releases/latest 跳到的 tag 地址。
  function resolveLatestByRequest() {
    return new Promise((resolve) => {
      let settled = false;
      const finish = (value) => {
        if (settled) return;
        settled = true;
        clearTimeoutFn(timer);
        resolve(value);
      };
      let request;
      const timer = setTimeoutFn(() => {
        try { request && request.abort(); } catch { /* ignore */ }
        finish({ status: 0, url: '', error: 'timeout' });
      }, probeTimeoutMs);
      try {
        request = net.request({ url: LATEST_RELEASE_PAGE, redirect: 'manual', cache: 'no-store' });
        for (const [key, value] of Object.entries(headers)) request.setHeader(key, value);
        request.on('redirect', (statusCode, method, redirectUrl) => {
          try { request.abort(); } catch { /* ignore */ }
          finish({ status: 200, url: redirectUrl });
        });
        request.on('response', (response) => {
          finish({ status: response.statusCode, url: '' });
          try { request.abort(); } catch { /* ignore */ }
        });
        request.on('error', (error) => finish({ status: 0, url: '', error: errorMessage(error) }));
        request.end();
      } catch (error) {
        finish({ status: 0, url: '', error: errorMessage(error) });
      }
    });
  }

  async function probe() {
    try {
      let landed;
      if (net && typeof net.request === 'function') {
        landed = await resolveLatestByRequest();
      } else if (net && typeof net.fetch === 'function') {
        const response = await net.fetch(LATEST_RELEASE_PAGE, {
          headers,
          redirect: 'follow',
          cache: 'no-store',
          signal: timeoutSignal(probeTimeoutMs)
        });
        landed = { status: response.status, url: typeof response.url === 'string' ? response.url : '' };
      } else {
        return { state: 'error' };
      }
      if (landed.error) log(`release probe failed: ${landed.error}`);
      const result = interpretLatestRelease(landed.status, landed.url, version);
      if (result.state === 'error') {
        log(`release probe status ${landed.status} landed on ${landed.url || '(none)'}`);
      }
      return result;
    } catch (error) {
      log(`release probe failed: ${errorMessage(error)}`);
      return { state: 'error' };
    }
  }

  function startProbe() {
    if (!probePromise) {
      probePromise = probe().then((result) => {
        probePromise = null;
        return result;
      }, () => {
        probePromise = null;
        return { state: 'error' };
      });
    }
    return probePromise;
  }

  function checkNow(flags) {
    const manual = Boolean(flags && flags.manual === true);
    if (isStopped()) return { state: 'error', stopped: true };
    log(`${manual ? 'manual' : 'automatic'} check start (check-only)`);
    if (manual) emitStatus('checking', { manual: true });
    void startProbe().then((result) => {
      if (isStopped()) return;
      if (result.state === 'available') {
        emitStatus('available', { manual, name: result.name, url: result.url });
      } else if (result.state === 'up-to-date') {
        emitStatus('up-to-date', { manual });
      } else {
        emitStatus('error', { manual });
      }
    });
    return { state: 'checking', mode: 'check-only' };
  }

  log(`check-only feed ${LATEST_RELEASE_PAGE}`);
  if (schedule) {
    firstCheckTimer = setTimeoutFn(checkNow, FIRST_CHECK_DELAY_MS);
    checkTimer = setIntervalFn(checkNow, CHECK_INTERVAL_MS);
  }

  return {
    mode: 'check-only',
    setupError: null,
    feedUrl: LATEST_RELEASE_PAGE,
    checkNow,
    stop() {
      setStopped();
      if (firstCheckTimer) clearTimeoutFn(firstCheckTimer);
      if (checkTimer) clearIntervalFn(checkTimer);
      firstCheckTimer = null;
      checkTimer = null;
    }
  };
}

module.exports = {
  FIRST_CHECK_DELAY_MS,
  CHECK_INTERVAL_MS,
  FEED_TIMEOUT_MS,
  setupAutoUpdate
};
