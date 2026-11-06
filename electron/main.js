'use strict';

const {
  app, BrowserWindow, Tray, Menu, globalShortcut, screen, desktopCapturer,
  ipcMain, nativeImage, clipboard, dialog, shell, systemPreferences
} = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

const execFileAsync = promisify(execFile);

const { createSettingsStore } = require('./app/settings-store');
const { createFileLogger } = require('./app/file-log');
const { createOcrService, findFocus } = require('./app/ocr');
const { translateWord: deepSeekWord, translateSelection: deepSeekSelection } = require('./app/deepseek');
const localTranslator = require('./app/local-translator');
const {
  eligibleEnglishText,
  eligibleClipboardHint,
  hintSupportsFocus,
  clipboardWords,
  relativeTimeRegex,
  relativeTimeChinese
} = require('./app/focus-text');
const {
  distanceFrom,
  classifyPointerMove,
  shouldResetFocus,
  captureHidesLens,
  shouldSuppressLensForCapture,
  markInspectionComplete,
  scheduleCaptureRetry,
  screenPermissionCard,
  shouldCancelPendingWord,
  shouldReuseCapture,
  missLimit,
  isCurrentWordRequest,
  isCurrentSelectionRequest,
  acceptWordResult,
  acceptSelectionResult,
  remoteErrorCard
} = require('./app/focus-session');

const LENS_WIDTH = 190;
const LENS_HEIGHT = 114;
const SHOW_ON_LAUNCH = process.argv.includes('--show-on-launch');
const SMOKE_TEST = process.argv.includes('--smoke-test');
const FIXED_POINT = parseFixedPoint();

function parseFixedPoint() {
  const index = process.argv.indexOf('--fixed-point');
  if (index === -1 || index + 2 >= process.argv.length) return null;
  const x = Number(process.argv[index + 1]);
  const y = Number(process.argv[index + 2]);
  return Number.isFinite(x) && Number.isFinite(y) ? { x, y } : null;
}

function pointerPosition() {
  return FIXED_POINT || screen.getCursorScreenPoint();
}

if (process.platform === 'linux') {
  app.commandLine.appendSwitch('enable-transparent-visuals');
  if (!process.env.EASYLENS_ENABLE_GPU) app.disableHardwareAcceleration();
}
if (process.platform === 'linux' && typeof process.getuid === 'function' && process.getuid() === 0) {
  app.commandLine.appendSwitch('no-sandbox');
}

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const uptime = () => performance.now() / 1000;
const clamp = (value, low, high) => Math.max(low, Math.min(high, value));

let tray = null;
let lensWindow = null;
let cardWindow = null;
let settingsWindow = null;
let settingsStore = null;
let ocrService = null;
let tickTimer = null;
let loadingTimer = null;
let quitting = false;

const state = {
  visible: false,
  pointer: { x: 0, y: 0 },
  lastMoveAt: 0,
  lastMoveDistance: 0,
  generation: 0,
  inspectedGeneration: -1,
  nextInspectionAt: 0,
  scanning: false,
  misses: 0,
  currentAnchor: null,
  currentSentence: null,
  pendingWordKey: null,
  activeSelectionHint: null,
  pendingSelectionText: null,
  selectionRequestId: 0,
  wordCache: new Map(),
  selectionCache: new Map(),
  remoteLoading: null,
  loadingShown: false,
  cardSize: { width: 420, height: 120 },
  clipboardHint: null,
  clipboardHintExpiresAt: 0,
  lastClipboardText: '',
  nextClipboardPollAt: 0,
  lastCaptureAt: 0,
  lastCapturePointer: null,
  lastCaptureAnchor: null,
  lastInspectedPointer: null,
  lastDiagnostic: ''
};

const fileLogger = createFileLogger();
function log(...values) {
  fileLogger.info(...values);
}
log.warn = (...values) => fileLogger.warn(...values);
log.error = (...values) => fileLogger.error(...values);

function screenAccessStatus() {
  if (process.platform !== 'darwin') return 'granted';
  try {
    return systemPreferences.getMediaAccessStatus('screen');
  } catch {
    return 'unknown';
  }
}

async function openScreenPermissionSettings() {
  if (process.platform !== 'darwin') return;
  try {
    await shell.openExternal(
      'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'
    );
  } catch (error) {
    log.error('SCREEN_PERMISSION_OPEN_ERROR=' + (error?.message || error));
  }
  updateTrayMenu();
}

async function openLogLocation() {
  fileLogger.touch();
  try {
    const error = await shell.openPath(fileLogger.logFile);
    if (!error) return;
  } catch (error) {
    log.warn('LOG_OPEN_ERROR=' + (error?.message || error));
  }
  try {
    const error = await shell.openPath(fileLogger.logDir);
    if (error) log.warn('LOG_DIR_OPEN_ERROR=' + error);
  } catch (error) {
    log.warn('LOG_DIR_OPEN_ERROR=' + (error?.message || error));
  }
}

function preloadPath() {
  return path.join(__dirname, 'preload.js');
}

function createLensWindow() {
  lensWindow = new BrowserWindow({
    width: LENS_WIDTH,
    height: LENS_HEIGHT,
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    closable: false,
    focusable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    hasShadow: false,
    show: false,
    roundedCorners: false,
    webPreferences: {
      preload: preloadPath(),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: false
    }
  });
  lensWindow.setAlwaysOnTop(true, 'screen-saver');
  lensWindow.setIgnoreMouseEvents(true, { forward: true });
  lensWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  lensWindow.loadFile(path.join(__dirname, 'renderer', 'lens.html'));
  lensWindow.on('closed', () => { lensWindow = null; });
}

function createCardWindow() {
  cardWindow = new BrowserWindow({
    width: state.cardSize.width,
    height: state.cardSize.height,
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    closable: false,
    focusable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    hasShadow: false,
    show: false,
    roundedCorners: false,
    webPreferences: {
      preload: preloadPath(),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: false
    }
  });
  cardWindow.setAlwaysOnTop(true, 'screen-saver');
  cardWindow.setIgnoreMouseEvents(true, { forward: true });
  cardWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  cardWindow.loadFile(path.join(__dirname, 'renderer', 'card.html'));
  cardWindow.on('closed', () => { cardWindow = null; });
}

function createSettingsWindow() {
  settingsWindow = new BrowserWindow({
    width: 580,
    height: 560,
    minWidth: 520,
    minHeight: 500,
    title: 'EasyLens · 设置',
    show: false,
    autoHideMenuBar: true,
    backgroundColor: '#16181d',
    webPreferences: {
      preload: preloadPath(),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });
  settingsWindow.loadFile(path.join(__dirname, 'renderer', 'settings.html'));
  settingsWindow.on('close', (event) => {
    if (!quitting) {
      event.preventDefault();
      settingsWindow.hide();
    }
  });
  settingsWindow.on('closed', () => { settingsWindow = null; });
}

function lensFrame(pointer) {
  const display = screen.getDisplayNearestPoint(pointer);
  const area = display.workArea;
  return {
    x: Math.round(clamp(pointer.x - LENS_WIDTH / 2, area.x, area.x + area.width - LENS_WIDTH)),
    y: Math.round(clamp(pointer.y - LENS_HEIGHT / 2, area.y, area.y + area.height - LENS_HEIGHT))
  };
}

function updateLensPosition(pointer) {
  if (!lensWindow || lensWindow.isDestroyed()) return;
  const frame = lensFrame(pointer);
  const current = lensWindow.getBounds();
  if (current.x !== frame.x || current.y !== frame.y) {
    lensWindow.setBounds({ x: frame.x, y: frame.y, width: LENS_WIDTH, height: LENS_HEIGHT });
  }
}

function sendLens(payload) {
  if (lensWindow && !lensWindow.isDestroyed()) {
    lensWindow.webContents.send('lens:state', payload);
  }
}

function suppressLens(suppress) {
  if (lensWindow && !lensWindow.isDestroyed()) {
    lensWindow.webContents.send('lens:suppress', Boolean(suppress));
  }
}

function sendLensResume() {
  if (lensWindow && !lensWindow.isDestroyed()) {
    lensWindow.webContents.send('lens:resume');
  }
}

function resumeLensRenderer() {
  // `lens:suppress false` restores opacity and re-arms the scheduler; the
  // explicit resume event also recovers a renderer whose rAF loop went idle.
  suppressLens(false);
  sendLensResume();
}

function hideCard() {
  if (cardWindow && !cardWindow.isDestroyed() && cardWindow.isVisible()) {
    cardWindow.hide();
  }
  sendLens({ translated: false });
}

function positionCard() {
  if (!cardWindow || cardWindow.isDestroyed() || !lensWindow) return;
  const lens = lensFrame(state.pointer);
  const display = screen.getDisplayNearestPoint(state.pointer);
  const area = display.workArea;
  const width = state.cardSize.width;
  const height = state.cardSize.height;
  const x = Math.round(clamp(
    lens.x + (LENS_WIDTH - width) / 2,
    area.x + 6,
    area.x + area.width - width - 6
  ));
  let y = lens.y + LENS_HEIGHT + 8;
  if (y + height > area.y + area.height - 6) {
    y = lens.y - height - 8;
  }
  y = Math.round(clamp(y, area.y + 6, area.y + area.height - height - 6));
  cardWindow.setBounds({ x, y, width, height });
}

function showCard(payload) {
  if (!cardWindow || cardWindow.isDestroyed()) return;
  cardWindow.webContents.send('card:show', payload);
  positionCard();
  cardWindow.showInactive();
  cardWindow.setAlwaysOnTop(true, 'screen-saver');
  cardWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  cardWindow.moveTop();
  if (payload.kind !== 'loading') {
    sendLens({ translated: true, reading: false });
  } else {
    sendLens({ translated: false });
  }
}

function finishRemoteLoading() {
  if (loadingTimer) {
    clearTimeout(loadingTimer);
    loadingTimer = null;
  }
  if (state.loadingShown) {
    hideCard();
  }
  state.remoteLoading = null;
  state.loadingShown = false;
}

function beginRemoteLoading(descriptor, title, stillValid) {
  finishRemoteLoading();
  hideCard();
  state.remoteLoading = descriptor;
  loadingTimer = setTimeout(() => {
    loadingTimer = null;
    if (!state.visible || !stillValid()) {
      state.remoteLoading = null;
      return;
    }
    state.loadingShown = true;
    showCard({ kind: 'loading', title });
  }, 180);
}

function resetFocusState() {
  finishRemoteLoading();
  state.currentAnchor = null;
  state.currentSentence = null;
  state.pendingWordKey = null;
  state.activeSelectionHint = null;
  state.pendingSelectionText = null;
  state.selectionRequestId += 1;
  state.misses = 0;
  state.inspectedGeneration = -1;
  state.nextInspectionAt = 0;
  state.lastCaptureAt = 0;
  state.lastCapturePointer = null;
  state.lastCaptureAnchor = null;
  hideCard();
}

function showLens() {
  if (!lensWindow || lensWindow.isDestroyed()) return;
  const pointer = pointerPosition();
  state.pointer = pointer;
  state.lastInspectedPointer = { x: pointer.x, y: pointer.y };
  state.visible = true;
  state.lastMoveAt = uptime();
  state.generation += 1;
  state.inspectedGeneration = -1;
  state.nextInspectionAt = uptime() + 0.12;
  state.misses = 0;
  resetFocusState();
  const frame = lensFrame(pointer);
  lensWindow.setBounds({ x: frame.x, y: frame.y, width: LENS_WIDTH, height: LENS_HEIGHT });
  lensWindow.showInactive();
  lensWindow.setAlwaysOnTop(true, 'screen-saver');
  lensWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  lensWindow.moveTop();
  // The renderer treats a false suppression value as a wake signal and
  // re-arms its animation loop immediately. The explicit resume event also
  // covers macOS when WindowServer briefly detaches the transparent window.
  resumeLensRenderer();
  registerEscape();
  startTick();
  rememberClipboard(pointer, true);
  updateTrayMenu();
  log('LENS_SHOWN provider=' + settingsStore.getPublic().provider);
  if (SMOKE_TEST) {
    setTimeout(() => {
      showCard({
        kind: 'word',
        title: 'EasyLens · 本地词典',
        text: '眼睛已就绪。把鼠标停在英文单词上即可查看中文。'
      });
    }, 350);
  }
}

function hideLens() {
  if (!state.visible) return;
  state.visible = false;
  state.generation += 1;
  state.inspectedGeneration = -1;
  resetFocusState();
  suppressLens(false);
  if (lensWindow && !lensWindow.isDestroyed()) lensWindow.hide();
  stopTick();
  unregisterEscape();
  updateTrayMenu();
  log('LENS_HIDDEN');
}

function toggleLens() {
  // While a Linux capture hides the real window, state.visible is still true.
  // Treat that as "show" so the hotkey/tray restores the eye instead of trying
  // to hide an already hidden window.
  const windowVisible = Boolean(
    lensWindow && !lensWindow.isDestroyed() && lensWindow.isVisible()
  );
  if (state.visible && windowVisible) hideLens();
  else showLens();
}

let escapeRegistered = false;
function registerEscape() {
  if (escapeRegistered) return;
  try {
    escapeRegistered = globalShortcut.register('Escape', hideLens);
    if (!escapeRegistered) log('ERROR escape hotkey unavailable');
  } catch (error) {
    log('ERROR escape hotkey', error.message);
  }
}

function unregisterEscape() {
  if (!escapeRegistered) return;
  globalShortcut.unregister('Escape');
  escapeRegistered = false;
}

function startTick() {
  stopTick();
  tickTimer = setInterval(tick, 16);
}

function stopTick() {
  if (tickTimer) {
    clearInterval(tickTimer);
    tickTimer = null;
  }
}

function tick() {
  if (!state.visible) return;
  const pointer = pointerPosition();
  pollClipboard();
  updateLensPosition(pointer);
  const now = uptime();
  if (!state.lastInspectedPointer) {
    state.lastInspectedPointer = { x: pointer.x, y: pointer.y };
  }
  // Measure from the last successfully inspected spot, not from the previous
  // 16ms frame. Slow steady moves accumulate 3px and must reopen inspection.
  const distance = distanceFrom(pointer, state.lastInspectedPointer);
  const movement = classifyPointerMove(distance);
  state.pointer = pointer;
  state.lastMoveDistance = distance;
  if (movement !== 'stationary') {
    state.lastMoveAt = now;
    // Re-inspect after the pointer settles, but do not burn a new generation
    // for trackpad jitter: that used to drop in-flight DeepSeek responses.
    state.inspectedGeneration = -1;
    state.nextInspectionAt = 0;
    state.misses = 0;
    if (shouldResetFocus(distance)) {
      state.generation += 1;
      finishRemoteLoading();
      state.currentAnchor = null;
      state.currentSentence = null;
      state.pendingWordKey = null;
      state.activeSelectionHint = null;
      state.pendingSelectionText = null;
      state.selectionRequestId += 1;
      hideCard();
      sendLens({ reading: false });
    }
  }
  if (state.loadingShown) positionCard();
  if (!state.scanning && now - state.lastMoveAt >= 0.10 &&
      state.inspectedGeneration !== state.generation && now >= state.nextInspectionAt) {
    inspectFocus();
  }
}

function rememberClipboard(pointer, initial = false) {
  const text = clipboard.readText();
  if (text !== state.lastClipboardText || initial) {
    state.lastClipboardText = text;
    const eligible = eligibleClipboardHint(text);
    if (eligible && clipboardWords(eligible).length > 1) {
      state.clipboardHint = eligible;
      state.clipboardHintExpiresAt = uptime() + 5;
      log(`CLIPBOARD_HINT accepted length=${eligible.length}`);
    } else if (!initial) {
      state.clipboardHint = null;
      state.clipboardHintExpiresAt = 0;
    }
  }
}

function pollClipboard() {
  const now = uptime();
  if (now < state.nextClipboardPollAt) return;
  state.nextClipboardPollAt = now + 0.25;
  rememberClipboard(state.pointer);
  if (state.clipboardHint && now >= state.clipboardHintExpiresAt) {
    state.clipboardHint = null;
    state.clipboardHintExpiresAt = 0;
  }
}

async function readPrimarySelection() {
  if (process.platform !== 'linux') return null;
  // Electron can read the X11 PRIMARY selection directly. This works on
  // desktops that do not ship xclip/xsel, which are only fallbacks below.
  try {
    const selection = clipboard.readText('selection');
    if (selection && selection.trim()) return selection;
  } catch { /* selection type unavailable on this display server */ }
  const commands = [
    ['wl-paste', ['--primary', '--no-newline']],
    ['xclip', ['-selection', 'primary', '-o']],
    ['xsel', ['--primary', '--output']]
  ];
  for (const [command, args] of commands) {
    try {
      const { stdout } = await execFileAsync(command, args, {
        timeout: 250,
        maxBuffer: 64 * 1024,
        encoding: 'utf8'
      });
      if (stdout && stdout.trim()) return stdout;
    } catch { /* command unavailable or no primary selection */ }
  }
  return null;
}

async function currentSelectionHint() {
  const primary = await readPrimarySelection();
  if (primary) {
    const eligible = eligibleEnglishText(primary, 4000);
    if (eligible) return { text: eligible, source: 'primary' };
  }
  if (state.clipboardHint && uptime() < state.clipboardHintExpiresAt) {
    return { text: state.clipboardHint, source: 'clipboard' };
  }
  return null;
}

async function captureAroundCursor(pointer) {
  const display = screen.getDisplayNearestPoint(pointer);
  const bounds = display.bounds;
  const scale = display.scaleFactor || 1;
  const cropWidth = Math.max(360, Math.min(900, bounds.width));
  const cropHeight = Math.max(140, Math.min(240, bounds.height));
  const cropX = clamp(pointer.x - cropWidth / 2, bounds.x, bounds.x + bounds.width - cropWidth);
  const cropY = clamp(pointer.y - cropHeight / 2, bounds.y, bounds.y + bounds.height - cropHeight);

  if (cardWindow && !cardWindow.isDestroyed()) cardWindow.hide();
  // The eye sits exactly over the word being read. On Linux a transparent
  // always-on-top window still occludes the root-window capture, so hide the
  // real window briefly while taking the frame. On macOS/Windows hiding or
  // dimming the window makes WindowServer rebuild the transparent layer and
  // causes the visible eye flicker; the lens already has a transparent hole
  // over the word, so those platforms capture without any opacity dance.
  const restoreLens = state.visible && lensWindow && !lensWindow.isDestroyed();
  const hideRealWindow = captureHidesLens(process.platform);
  const suppressForCapture = shouldSuppressLensForCapture(process.platform);
  if (restoreLens && suppressForCapture) {
    if (hideRealWindow) lensWindow.hide();
    suppressLens(true);
    // Give the compositor a moment to apply the Linux hide before asking
    // desktopCapturer for the root frame.
    await delay(45);
  }

  let thumbnail;
  try {
    const sources = await desktopCapturer.getSources({
      types: ['screen'],
      thumbnailSize: {
        width: Math.max(1, Math.round(bounds.width * scale)),
        height: Math.max(1, Math.round(bounds.height * scale))
      },
      fetchWindowIcons: false
    });
    const source = sources.find((item) => String(item.display_id) === String(display.id)) || sources[0];
    if (!source) throw new Error('no screen source');
    thumbnail = source.thumbnail;
  } finally {
    if (restoreLens && state.visible && lensWindow && !lensWindow.isDestroyed()) {
      if (hideRealWindow) {
        updateLensPosition(pointer);
        lensWindow.showInactive();
        // Sent after showInactive so it both restores opacity and wakes the
        // renderer loop after the Linux capture hide.
        resumeLensRenderer();
      }
    } else {
      // Keep the renderer's suppression state clean for the next show.
      suppressLens(false);
    }
  }

  const size = thumbnail.getSize();
  if (!size.width || !size.height) throw new Error('empty screen capture');
  const scaleX = size.width / bounds.width;
  const scaleY = size.height / bounds.height;
  const cropped = thumbnail.crop({
    x: Math.round((cropX - bounds.x) * scaleX),
    y: Math.round((cropY - bounds.y) * scaleY),
    width: Math.max(1, Math.round(cropWidth * scaleX)),
    height: Math.max(1, Math.round(cropHeight * scaleY))
  });
  const image = cropped.toPNG();
  if (process.env.EASYLENS_DEBUG_CAPTURE === '1') {
    const output = path.join(os.tmpdir(), 'easylens-capture.png');
    try { fs.writeFileSync(output, image); } catch { /* debug only */ }
    log(`CAPTURE_DEBUG path=${output} crop=${cropX},${cropY},${cropWidth},${cropHeight} focus=${(pointer.x - cropX) * scaleX},${(pointer.y - cropY) * scaleY}`);
  }
  return {
    image,
    width: cropped.getSize().width,
    height: cropped.getSize().height,
    focusX: (pointer.x - cropX) * scaleX,
    focusY: (pointer.y - cropY) * scaleY,
    crop: { x: cropX, y: cropY, width: cropWidth, height: cropHeight }
  };
}

function selectionDiagnostic(text, source) {
  const value = `${source || 'none'}|${text ? text.length : 0}`;
  if (value === state.lastDiagnostic) return;
  state.lastDiagnostic = value;
  log(`SELECTION_HINT source=${source || 'none'} length=${text ? text.length : 0}`);
}

async function inspectFocus() {
  if (state.scanning || !state.visible) return;
  const now = uptime();
  if (shouldReuseCapture({
    now,
    lastCaptureAt: state.lastCaptureAt,
    pointer: state.pointer,
    lastCapturePointer: state.lastCapturePointer,
    anchor: state.currentAnchor,
    lastCaptureAnchor: state.lastCaptureAnchor
  })) {
    // Same spot, same anchor: avoid another capture during trackpad jitter.
    // The spot is already inspected; only a real pointer move may reopen it.
    markInspectionComplete(state, state.pointer);
    return;
  }
  state.scanning = true;
  const generation = state.generation;
  const pointer = { x: state.pointer.x, y: state.pointer.y };
  state.inspectedGeneration = generation;
  sendLens({ reading: true, translated: false });
  let captureSucceeded = false;
  try {
    // Never pre-check the screen permission to skip capture. macOS only shows
    // the TCC prompt and adds the app to System Settings → Screen Recording
    // after desktopCapturer.getSources actually tries to capture. A denied or
    // unknown status falls through to the catch below, which shows the
    // permission card and schedules the 800ms retry.
    const [shot, hint] = await Promise.all([
      captureAroundCursor(pointer),
      currentSelectionHint()
    ]);
    captureSucceeded = true;
    // Only a successful capture may feed the reuse gate. Stamping these before
    // getSources lets a permission failure block its own 800ms retry.
    state.lastCaptureAt = now;
    state.lastCapturePointer = { x: pointer.x, y: pointer.y };
    state.lastCaptureAnchor = state.currentAnchor;
    const words = await ocrService.recognize(shot.image);
    if (process.env.EASYLENS_DEBUG_OCR === '1') {
      log('OCR_WORDS=' + words.map((word) => word.text).join(' | '));
    }
    if (!state.visible || generation !== state.generation) return;
    const passage = findFocus(
      words,
      { x: shot.focusX, y: shot.focusY },
      { width: shot.width, height: shot.height },
      hint?.text || null
    );
    if (!passage) {
      handleMiss(pointer);
      return;
    }
    state.misses = 0;
    if (hint && hintSupportsFocus(hint.text, passage.anchor)) {
      selectionDiagnostic(hint.text, hint.source);
      translateSelection(hint.text, pointer);
    } else {
      selectionDiagnostic(null, null);
      state.activeSelectionHint = null;
      translateWordFocus(passage, pointer);
    }
    log(`SENTENCE_FOCUS anchor=${passage.anchor} sentenceLength=${passage.sentence.length} distance=${passage.distance.toFixed(3)} confidence=${passage.confidence}`);
  } catch (error) {
    const message = error?.message || String(error);
    const accessStatus = screenAccessStatus();
    if (captureSucceeded) {
      // OCR/runtime failure after a real capture: behave like a completed
      // scan, not like a retry loop (blank-text recapture caused 0.1.4 flicker).
      log.error(`FOCUS_SCAN_ERROR=${message} stage=ocr mediaAccess=${accessStatus}`);
      if (state.visible && generation === state.generation) {
        markInspectionComplete(state, pointer);
      }
    } else {
      // A permission failure used to reach markInspectionComplete and stop
      // scanning this spot forever. Show the permission card and retry after
      // 800ms without advancing the last inspected pointer.
      log.error(`CAPTURE_ERROR=${message} mediaAccess=${accessStatus} platform=${process.platform}`);
      if (state.visible && generation === state.generation) {
        showCard(screenPermissionCard());
        scheduleCaptureRetry(state, uptime());
        updateTrayMenu();
      }
    }
  } finally {
    state.scanning = false;
    if (state.visible) sendLens({ reading: false });
  }
}

function handleMiss(pointer) {
  state.misses += 1;
  const pendingRemote = Boolean(state.pendingWordKey || state.pendingSelectionText);
  // OCR can miss a frame under the eye. Do not kill an in-flight DeepSeek
  // request unless the target has really disappeared for several scans.
  if (state.currentSentence !== null && state.misses >= missLimit(pendingRemote)) {
    finishRemoteLoading();
    state.generation += 1;
    state.currentAnchor = null;
    state.currentSentence = null;
    state.pendingWordKey = null;
    state.activeSelectionHint = null;
    state.pendingSelectionText = null;
    state.selectionRequestId += 1;
    hideCard();
    log('FOCUS_CONTENT_CHANGED target=none');
  }
  // A miss is a completed scan too. Do not schedule a recapture loop on blank
  // text; tick() only inspects again after a real pointer move.
  markInspectionComplete(state, pointer);
  log('SENTENCE_FOCUS none');
}

function translateWordFocus(passage, pointer) {
  const settings = settingsStore.getPublic();
  // Sentence punctuation can jitter between OCR frames. Keep an in-flight
  // DeepSeek request alive as long as the anchor is unchanged and the pointer
  // has not made a real focus-break move.
  const resetTranslation = shouldCancelPendingWord({
    currentAnchor: state.currentAnchor,
    nextAnchor: passage.anchor,
    distance: state.lastMoveDistance
  });
  if (resetTranslation) {
    finishRemoteLoading();
    hideCard();
    state.generation += 1;
    state.pendingWordKey = null;
    state.pendingSelectionText = null;
    state.selectionRequestId += 1;
  }
  state.currentAnchor = passage.anchor;
  state.currentSentence = passage.sentence;
  // A hit is a completed scan of this spot. Only a new pointer move reopens it.
  markInspectionComplete(state, pointer);

  const key = passage.anchor.toLowerCase() + '\n' + passage.sentence;
  if (settings.provider === 'local') {
    const timeMatch = passage.focusLine.match(relativeTimeRegex);
    const literal = timeMatch && timeMatch[0].toLowerCase()
      .includes(passage.anchor.toLowerCase())
      ? relativeTimeChinese(timeMatch[0])
      : null;
    if (literal) {
      const result = { chinese: literal, basis: '时间表达' };
      state.wordCache.set(key, result);
      state.pendingWordKey = null;
      showCard({
        kind: 'word',
        title: `${passage.anchor} · ${result.basis}`,
        text: result.chinese
      });
      log('FOCUS_TRANSLATION resolved=yes basis=时间表达 provider=local');
      return;
    }
  }
  const cached = state.wordCache.get(key);
  if (cached) {
    if (cached.chinese) {
      showCard({
        kind: 'word',
        title: `${passage.anchor} · ${cached.basis}`,
        text: cached.chinese
      });
    }
    log('FOCUS_TRANSLATION cacheHit=true provider=' + settings.provider);
    return;
  }
  // An in-flight request for the same anchor stays authoritative even if OCR
  // retyped the surrounding sentence. Do not replace its pending key.
  const pendingAnchor = state.pendingWordKey
    ? state.pendingWordKey.split('\n', 1)[0]
    : null;
  if (state.pendingWordKey === key ||
      pendingAnchor === passage.anchor.toLowerCase()) return;
  state.pendingWordKey = key;

  if (settings.provider === 'deepSeek') {
    let configuration;
    try {
      configuration = settingsStore.deepSeekConfiguration();
    } catch (error) {
      log('FOCUS_TRANSLATION_ERROR=' + error.message);
      state.pendingWordKey = null;
      showCard(remoteErrorCard({ kind: 'word', anchor: passage.anchor, error }));
      return;
    }
    beginRemoteLoading(
      { type: 'word', key, anchor: passage.anchor },
      passage.anchor,
      () => state.visible && state.pendingWordKey === key &&
        state.currentAnchor === passage.anchor
    );
    deepSeekWord({ anchor: passage.anchor, sentence: passage.sentence, configuration })
      .then((result) => receiveWord(key, passage.anchor, result))
      .catch((error) => receiveWordError(key, passage.anchor, error));
  } else {
    const result = localTranslator.translateWord(passage.anchor);
    state.pendingWordKey = null;
    if (result && result.chinese) {
      state.wordCache.set(key, result);
      showCard({
        kind: 'word',
        title: `${passage.anchor} · ${result.basis}`,
        text: result.chinese
      });
      log('FOCUS_TRANSLATION resolved=yes basis=' + result.basis + ' provider=local');
    } else {
      hideCard();
      log('FOCUS_TRANSLATION resolved=no provider=local');
    }
  }
}

function receiveWord(key, anchor, result) {
  // Cache first: a successful request is useful even if the focus moved on.
  const outcome = acceptWordResult({
    cache: state.wordCache,
    visible: state.visible,
    pendingKey: state.pendingWordKey,
    key,
    currentAnchor: state.currentAnchor,
    anchor,
    result
  });
  state.wordCache = outcome.cache;
  const current = isCurrentWordRequest({
    pendingKey: state.pendingWordKey,
    key,
    remoteLoading: state.remoteLoading
  });
  if (current) {
    state.pendingWordKey = null;
    finishRemoteLoading();
  }
  if (!outcome.display) {
    log('FOCUS_TRANSLATION stale=true cache=yes display=no provider=deepSeek');
    return;
  }
  showCard({
    kind: 'word',
    title: `${anchor} · ${result.basis}`,
    text: result.chinese
  });
  log(`FOCUS_TRANSLATION resolved=yes basis=${result.basis} provider=deepSeek`);
}

function receiveWordError(key, anchor, error) {
  log('SENTENCE_TRANSLATION_ERROR=' + (error?.message || error));
  // A stale request may fail after the user has already moved to a new target.
  // Do not let it clear the newer loading card or its pending key.
  const current = state.visible &&
    state.currentAnchor === anchor &&
    isCurrentWordRequest({
      pendingKey: state.pendingWordKey,
      key,
      remoteLoading: state.remoteLoading
    });
  if (!current) {
    log('FOCUS_TRANSLATION stale=true error_ignored=true provider=deepSeek');
    return;
  }
  state.pendingWordKey = null;
  finishRemoteLoading();
  const card = remoteErrorCard({ kind: 'word', anchor, error });
  showCard(card);
  log('FOCUS_TRANSLATION error_shown text=' + card.text);
}

function translateSelection(text, pointer) {
  const settings = settingsStore.getPublic();
  const selectionChanged = state.activeSelectionHint !== text;
  state.activeSelectionHint = text;
  state.currentAnchor = null;
  state.currentSentence = null;

  // A visible selection takes precedence over any word request in flight.
  if (state.pendingWordKey) {
    state.pendingWordKey = null;
    if (state.remoteLoading?.type === 'word') finishRemoteLoading();
  }
  if (selectionChanged && state.pendingSelectionText) {
    state.pendingSelectionText = null;
    state.selectionRequestId += 1;
    if (state.remoteLoading?.type === 'selection') finishRemoteLoading();
  }

  const cached = state.selectionCache.get(text);
  if (cached) {
    if (state.pendingSelectionText === text) {
      state.pendingSelectionText = null;
      if (state.remoteLoading?.type === 'selection') finishRemoteLoading();
    }
    markInspectionComplete(state, pointer);
    showCard({ kind: 'selection', title: '选区翻译', text: cached });
    return;
  }
  if (state.pendingSelectionText === text) {
    markInspectionComplete(state, pointer);
    return;
  }
  const requestId = ++state.selectionRequestId;
  state.pendingSelectionText = text;
  // A selection hit is a completed scan of this spot; stop recapturing until
  // the pointer makes a real move.
  markInspectionComplete(state, pointer);
  hideCard();
  log(`SELECTION_TRANSLATION requested length=${text.length} provider=${settings.provider}`);

  if (settings.provider === 'deepSeek') {
    let configuration;
    try {
      configuration = settingsStore.deepSeekConfiguration();
    } catch (error) {
      state.pendingSelectionText = null;
      log('SELECTION_TRANSLATION_ERROR=' + error.message);
      showCard(remoteErrorCard({ kind: 'selection', error }));
      return;
    }
    beginRemoteLoading(
      { type: 'selection', requestId, text },
      '完整选区',
      () => state.visible && state.selectionRequestId === requestId &&
        state.pendingSelectionText === text && state.activeSelectionHint === text
    );
    deepSeekSelection({ text, configuration })
      .then((chinese) => receiveSelection(requestId, text, chinese))
      .catch((error) => receiveSelectionError(requestId, text, error));
  } else {
    const result = localTranslator.translateSelection(text);
    state.pendingSelectionText = null;
    if (result && result.chinese) {
      state.selectionCache.set(text, result.chinese);
      showCard({ kind: 'selection', title: '选区翻译 · 本地词典', text: result.chinese });
      log('SELECTION_TRANSLATION resolved=yes provider=local fallback=true');
    } else {
      hideCard();
      log('SELECTION_TRANSLATION resolved=no provider=local');
    }
  }
}

function receiveSelection(requestId, text, chinese) {
  // Cache first, then decide whether the selection is still on screen/current.
  const outcome = acceptSelectionResult({
    cache: state.selectionCache,
    visible: state.visible,
    pendingText: state.pendingSelectionText,
    text,
    activeSelectionHint: state.activeSelectionHint,
    result: chinese
  });
  state.selectionCache = outcome.cache;
  const current = isCurrentSelectionRequest({
    pendingText: state.pendingSelectionText,
    requestId,
    text,
    remoteLoading: state.remoteLoading
  });
  if (current) {
    state.pendingSelectionText = null;
    finishRemoteLoading();
  }
  if (!outcome.display) {
    log('SELECTION_TRANSLATION stale=true cache=yes display=no provider=deepSeek');
    return;
  }
  if (!chinese) {
    hideCard();
    return;
  }
  showCard({ kind: 'selection', title: '选区翻译', text: chinese });
  log('SELECTION_TRANSLATION resolved=yes provider=deepSeek');
}

function receiveSelectionError(requestId, text, error) {
  log('SELECTION_TRANSLATION_ERROR=' + (error?.message || error));
  const current = state.visible &&
    isCurrentSelectionRequest({
      pendingText: state.pendingSelectionText,
      requestId,
      text,
      remoteLoading: state.remoteLoading
    }) &&
    state.activeSelectionHint === text;
  if (!current) {
    log('SELECTION_TRANSLATION stale=true error_ignored=true provider=deepSeek');
    return;
  }
  state.pendingSelectionText = null;
  finishRemoteLoading();
  const card = remoteErrorCard({ kind: 'selection', error });
  showCard(card);
  log('SELECTION_TRANSLATION error_shown text=' + card.text);
}

function updateTrayMenu() {
  if (!tray) return;
  const settings = settingsStore ? settingsStore.getPublic() : { provider: 'local' };
  const wakeShortcut = process.platform === 'darwin' ? '⌃⌥L' : 'Ctrl+Alt+L';
  const template = [
    {
      label: state.visible ? '隐藏眼睛 (Esc)' : `显示眼睛 (${wakeShortcut})`,
      click: toggleLens
    },
    { type: 'separator' }
  ];
  if (process.platform === 'darwin') {
    if (screenAccessStatus() === 'granted') {
      template.push({ label: '屏幕录制：已授权', enabled: false });
    } else {
      template.push({
        label: '屏幕录制：未授权 (点击授权)',
        click: openScreenPermissionSettings
      });
    }
    template.push({ type: 'separator' });
  }
  template.push(
    {
      label: '设置…',
      accelerator: 'CommandOrControl+,',
      click: showSettings
    },
    {
      label: '查看运行日志…',
      click: openLogLocation
    },
    { type: 'separator' },
    {
      label: `翻译来源：${settings.provider === 'deepSeek' ? 'DeepSeek' : '本地词典'}`,
      enabled: false
    },
    {
      label: '屏幕读取：Electron desktopCapturer',
      enabled: false
    },
    {
      label: '完整选区：PRIMARY / 剪贴板回退',
      enabled: false
    },
    { type: 'separator' },
    {
      label: '关于 EasyLens',
      click: () => {
        dialog.showMessageBox({
          type: 'info',
          title: 'EasyLens',
          message: 'EasyLens · Electron',
          detail: '按住鼠标停在英文上查看中文。\n' +
            `${wakeShortcut} 显示/隐藏眼睛，Esc 隐藏。\n\n` +
            'Linux 版使用 desktopCapturer 与 Tesseract 识别屏幕文字；' +
            '本地翻译是内置英汉词典，DeepSeek 可在设置中配置。'
        });
      }
    },
    {
      label: '退出 EasyLens',
      accelerator: 'CommandOrControl+Q',
      click: () => app.quit()
    }
  );
  const menu = Menu.buildFromTemplate(template);
  tray.setContextMenu(menu);
  tray.setToolTip(state.visible ? 'EasyLens · 眼睛已显示' : 'EasyLens');
}

function showSettings() {
  if (!settingsWindow || settingsWindow.isDestroyed()) createSettingsWindow();
  settingsWindow.show();
  settingsWindow.focus();
}

function handleSettingsChanged() {
  finishRemoteLoading();
  state.wordCache.clear();
  state.selectionCache.clear();
  state.generation += 1;
  state.inspectedGeneration = -1;
  state.nextInspectionAt = 0;
  state.currentAnchor = null;
  state.currentSentence = null;
  state.pendingWordKey = null;
  state.activeSelectionHint = null;
  state.pendingSelectionText = null;
  state.selectionRequestId += 1;
  hideCard();
  updateTrayMenu();
}

function registerIpc() {
  ipcMain.handle('settings:get', () => settingsStore.getPublic());

  ipcMain.handle('settings:save', (_event, payload) => {
    try {
      const settings = settingsStore.save(payload || {});
      handleSettingsChanged();
      return { ok: true, settings };
    } catch (error) {
      return { ok: false, error: error.message, code: error.code };
    }
  });

  ipcMain.handle('settings:remove-key', () => {
    try {
      const settings = settingsStore.removeAPIKey();
      handleSettingsChanged();
      return { ok: true, settings };
    } catch (error) {
      return { ok: false, error: error.message, code: error.code };
    }
  });

  ipcMain.handle('settings:test', async () => {
    try {
      const configuration = settingsStore.deepSeekConfiguration();
      const result = await deepSeekWord({
        anchor: 'hello',
        sentence: 'Hello!',
        configuration
      });
      return { ok: true, text: result.chinese };
    } catch (error) {
      return { ok: false, error: error.message, code: error.code };
    }
  });

  ipcMain.handle('settings:open-log', async () => {
    await openLogLocation();
    return { ok: true, path: fileLogger.logFile };
  });

  ipcMain.handle('settings:close', () => {
    if (settingsWindow && !settingsWindow.isDestroyed()) settingsWindow.hide();
    return { ok: true };
  });

  ipcMain.on('card:resize', (event, size) => {
    if (!cardWindow || event.sender !== cardWindow.webContents) return;
    const width = clamp(Math.round(Number(size?.width) || 420), 240, 500);
    const height = clamp(Math.round(Number(size?.height) || 120), 70, 420);
    state.cardSize = { width, height };
    if (cardWindow.isVisible()) positionCard();
  });

  ipcMain.on('lens:ready', () => {
    sendLens({ translated: false, reading: false });
    suppressLens(false);
  });
}

function createTray() {
  const iconPath = path.join(__dirname, 'assets', 'tray.png');
  let image = nativeImage.createFromPath(iconPath);
  if (image.isEmpty()) {
    image = nativeImage.createEmpty();
  } else if (process.platform === 'darwin') {
    image = image.resize({ width: 18, height: 18 });
    image.setTemplateImage(false);
  }
  tray = new Tray(image);
  updateTrayMenu();
  tray.on('click', toggleLens);
}

async function bootstrap() {
  if (process.platform === 'darwin') {
    try { app.dock.hide(); } catch { /* app may not be ready */ }
  }
  settingsStore = createSettingsStore();
  settingsStore.load();
  ocrService = createOcrService({ debug: process.env.EASYLENS_DEBUG_OCR === '1' });

  registerIpc();
  createLensWindow();
  createCardWindow();
  createTray();

  // On macOS Option is also called Alt. Register both spellings so users can
  // use either; if Electron resolves them to the same accelerator the second
  // registration fails and the first remains active.
  const wakeAccelerators = process.platform === 'darwin'
    ? ['Control+Alt+L', 'Control+Option+L']
    : ['Control+Alt+L'];
  for (const accelerator of wakeAccelerators) {
    try {
      const registered = globalShortcut.register(accelerator, toggleLens);
      log(registered
        ? `WAKE_HOTKEY_REGISTERED=${accelerator}`
        : `ERROR wake hotkey unavailable: ${accelerator}`);
    } catch (error) {
      log(`ERROR wake hotkey ${accelerator}`, error.message);
    }
  }
  log('EASYLENS_READY platform=' + process.platform + ' electron=' + process.versions.electron);
  log('TRANSLATION_PROVIDER=' + settingsStore.getPublic().provider + ' screenshots_saved=0');

  if (SHOW_ON_LAUNCH || SMOKE_TEST) {
    showLens();
  }
  if (SMOKE_TEST) {
    setTimeout(() => {
      log('SMOKE_TEST_OK visible=' + state.visible +
        ' lens=' + Boolean(lensWindow && !lensWindow.isDestroyed()) +
        ' card=' + Boolean(cardWindow && !cardWindow.isDestroyed()));
      app.quit();
    }, 2600);
  }
}

const lock = app.requestSingleInstanceLock();
if (!lock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (settingsWindow && settingsWindow.isVisible()) settingsWindow.focus();
    else showLens();
  });

  app.whenReady().then(bootstrap).catch((error) => {
    log.error('EASYLENS_START_ERROR', error);
    app.quit();
  });

  app.on('activate', () => {
    if (!state.visible) showLens();
  });

  app.on('window-all-closed', () => {
    // Tray application: keep running when all helper windows are hidden.
  });

  app.on('before-quit', async () => {
    quitting = true;
    stopTick();
    unregisterEscape();
    try { globalShortcut.unregisterAll(); } catch { /* ignore */ }
    if (ocrService) {
      try { await ocrService.terminate(); } catch { /* ignore */ }
    }
  });
}

process.on('uncaughtException', (error) => {
  log.error('EASYLENS_UNCAUGHT', error);
});
process.on('unhandledRejection', (error) => {
  log.error('EASYLENS_UNHANDLED_REJECTION', error);
});
