'use strict';

// Persistent application log. Packaged macOS apps launched from Finder do not
// have a terminal, so stdout alone is invisible. Keep the existing console
// output for development while mirroring every line to ~/.easylens/easylens.log.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const util = require('node:util');

const LOG_MAX_BYTES = 5 * 1024 * 1024;

function defaultLogDir() {
  return path.join(os.homedir(), '.easylens');
}

function asDate(value) {
  const date = value instanceof Date ? value : new Date(value ?? Date.now());
  return Number.isNaN(date.getTime()) ? new Date() : date;
}

function formatLogLine(level, values, date = new Date()) {
  const normalizedLevel = String(level || 'INFO').toUpperCase();
  const items = Array.isArray(values) ? values : [values];
  const message = util.format(...items);
  return `[${asDate(date).toISOString()}] [${normalizedLevel}] ${message}\n`;
}

function createFileLogger(options = {}) {
  const logDir = options.logDir || defaultLogDir();
  const logFile = options.logFile || path.join(logDir, 'easylens.log');
  const rotatedFile = options.rotatedFile || `${logFile}.1`;
  const maxBytes = Number.isFinite(options.maxBytes) && options.maxBytes > 0
    ? options.maxBytes
    : LOG_MAX_BYTES;
  const consoleImpl = options.console || console;
  const clock = typeof options.now === 'function' ? options.now : () => new Date();
  let directoryReady = false;

  function ensureDirectory() {
    if (directoryReady) return;
    fs.mkdirSync(logDir, { recursive: true, mode: 0o700 });
    try { fs.chmodSync(logDir, 0o700); } catch { /* best effort on shared filesystems */ }
    directoryReady = true;
  }

  function currentSize() {
    try { return fs.statSync(logFile).size; } catch { return 0; }
  }

  function rotate() {
    try {
      if (fs.existsSync(rotatedFile)) fs.unlinkSync(rotatedFile);
      if (fs.existsSync(logFile)) fs.renameSync(logFile, rotatedFile);
    } catch {
      // A failed rename (for example a locked file on Windows) should not
      // stop logging. Truncating the active file still keeps it bounded.
      try { fs.writeFileSync(logFile, ''); } catch { /* logging is best effort */ }
    }
  }

  function writeLine(line) {
    try {
      ensureDirectory();
      const size = currentSize();
      const nextSize = size + Buffer.byteLength(line, 'utf8');
      if (size > 0 && nextSize > maxBytes) rotate();
      fs.appendFileSync(logFile, line, { encoding: 'utf8', mode: 0o600 });
      try { fs.chmodSync(logFile, 0o600); } catch { /* best effort */ }
    } catch (error) {
      // Never let a logging problem crash or interrupt capture/translation.
      try { consoleImpl.error('EASYLENS_LOG_WRITE_ERROR', error.message); } catch { /* ignore */ }
    }
  }

  function emit(level, values, consoleMethod) {
    const line = formatLogLine(level, values, clock());
    writeLine(line);
    try {
      const method = consoleImpl[consoleMethod] || consoleImpl.log;
      if (typeof method === 'function') method.apply(consoleImpl, values);
    } catch { /* console may be unavailable in a packaged app */ }
  }

  function touch() {
    try {
      ensureDirectory();
      fs.closeSync(fs.openSync(logFile, 'a', 0o600));
      try { fs.chmodSync(logFile, 0o600); } catch { /* best effort */ }
      return logFile;
    } catch {
      return null;
    }
  }

  return {
    logDir,
    logFile,
    rotatedFile,
    maxBytes,
    touch,
    rotate,
    info: (...values) => emit('INFO', values, 'log'),
    warn: (...values) => emit('WARN', values, 'warn'),
    error: (...values) => emit('ERROR', values, 'error')
  };
}

module.exports = {
  LOG_MAX_BYTES,
  defaultLogDir,
  formatLogLine,
  createFileLogger
};
