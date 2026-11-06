'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  LOG_MAX_BYTES,
  formatLogLine,
  createFileLogger
} = require('../electron/app/file-log');

function silentConsole() {
  const calls = { log: [], warn: [], error: [] };
  return {
    calls,
    log: (...values) => calls.log.push(values),
    warn: (...values) => calls.warn.push(values),
    error: (...values) => calls.error.push(values)
  };
}

function withTempDir(callback) {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'easylens-file-log-'));
  try {
    return callback(scratch);
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

test('log lines use ISO time, level and the formatted message', () => {
  const date = new Date('2026-11-06T14:30:00.123Z');
  assert.equal(
    formatLogLine('INFO', ['FOCUS_TRANSLATION', 'anchor=hello'], date),
    '[2026-11-06T14:30:00.123Z] [INFO] FOCUS_TRANSLATION anchor=hello\n'
  );
  assert.equal(
    formatLogLine('error', ['CAPTURE_ERROR=Failed to get sources.'], date),
    '[2026-11-06T14:30:00.123Z] [ERROR] CAPTURE_ERROR=Failed to get sources.\n'
  );
  assert.equal(LOG_MAX_BYTES, 5 * 1024 * 1024);
});

test('logger writes INFO and ERROR to the injected directory and console', () => {
  withTempDir((logDir) => {
    const output = silentConsole();
    const logger = createFileLogger({
      logDir,
      console: output,
      now: () => new Date('2026-11-06T14:30:00.123Z')
    });

    logger.info('FOCUS_TRANSLATION', 'anchor=hello');
    logger.error('CAPTURE_ERROR=Failed to get sources.');

    assert.equal(
      fs.readFileSync(logger.logFile, 'utf8'),
      '[2026-11-06T14:30:00.123Z] [INFO] FOCUS_TRANSLATION anchor=hello\n' +
      '[2026-11-06T14:30:00.123Z] [ERROR] CAPTURE_ERROR=Failed to get sources.\n'
    );
    assert.deepEqual(output.calls.log, [['FOCUS_TRANSLATION', 'anchor=hello']]);
    assert.deepEqual(output.calls.error, [['CAPTURE_ERROR=Failed to get sources.']]);
    assert.equal(fs.existsSync(path.join(logDir, 'easylens.log')), true);
  });
});

test('logger rotates to easylens.log.1 when the next write exceeds the cap', () => {
  withTempDir((logDir) => {
    const logger = createFileLogger({
      logDir,
      maxBytes: 60,
      console: silentConsole(),
      now: () => new Date('2026-11-06T14:30:00.123Z')
    });

    logger.info('first-line');
    logger.info('second-line');
    assert.match(fs.readFileSync(logger.rotatedFile, 'utf8'), /first-line/);
    assert.doesNotMatch(fs.readFileSync(logger.rotatedFile, 'utf8'), /second-line/);
    assert.match(fs.readFileSync(logger.logFile, 'utf8'), /second-line/);
    assert.doesNotMatch(fs.readFileSync(logger.logFile, 'utf8'), /first-line/);

    // The previous .1 is overwritten rather than accumulating old rotations.
    logger.info('third-line');
    assert.match(fs.readFileSync(logger.rotatedFile, 'utf8'), /second-line/);
    assert.doesNotMatch(fs.readFileSync(logger.rotatedFile, 'utf8'), /first-line/);
    assert.match(fs.readFileSync(logger.logFile, 'utf8'), /third-line/);
  });
});

test('logging failures never escape from the logger', () => {
  withTempDir((logDir) => {
    const output = silentConsole();
    const logger = createFileLogger({
      logDir,
      // Use a directory path as the log file to force a write error.
      logFile: logDir,
      console: output
    });
    assert.doesNotThrow(() => logger.info('cannot write'));
    assert.equal(output.calls.error.length, 1);
  });
});
