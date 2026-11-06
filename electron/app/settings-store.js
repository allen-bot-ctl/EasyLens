'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const DEFAULT_BASE_URL = 'https://api.deepseek.com';
// Official DeepSeek API model names. These are presets only: proxy users may
// type any non-empty custom model name.
const MODELS = ['deepseek-chat', 'deepseek-reasoner'];
const MAX_MODEL_LENGTH = 100;
const PROVIDERS = ['local', 'deepSeek'];

class SettingsError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'SettingsError';
    this.code = code;
  }
}

function defaultRoot() {
  return path.join(os.homedir(), '.easylens');
}

function validatedBaseURL(value) {
  const trimmed = String(value ?? '').trim();
  if (!trimmed) return null;
  let url;
  try {
    url = new URL(trimmed);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' || !url.hostname ||
      url.username || url.password || url.search || url.hash) {
    return null;
  }
  return url;
}

function normalizeBaseURL(value) {
  const url = validatedBaseURL(value);
  if (!url) return null;
  return `${url.origin}${url.pathname}`.replace(/\/+$/, '');
}

function normalizeModel(value) {
  const trimmed = String(value ?? '').trim();
  if (!trimmed || trimmed.length > MAX_MODEL_LENGTH) return null;
  return trimmed;
}

function createSettingsStore(options = {}) {
  const root = options.rootDir || defaultRoot();
  const keyFile = options.keyFileURL || path.join(root, 'deepseek-api-key');
  const settingsFile = options.settingsFile || path.join(root, 'settings.json');
  let state = {
    provider: 'local',
    baseURL: DEFAULT_BASE_URL,
    model: MODELS[0]
  };

  function ensureDirectory(directory, mode) {
    fs.mkdirSync(directory, { recursive: true, mode });
    try { fs.chmodSync(directory, mode); } catch { /* best effort on shared filesystems */ }
  }

  function readAPIKey() {
    try {
      if (!fs.existsSync(keyFile)) return null;
      const value = fs.readFileSync(keyFile, 'utf8').trim();
      return value || null;
    } catch (error) {
      throw new SettingsError('key-storage', `无法访问本地密钥文件（${error.message}）。`);
    }
  }

  function storeAPIKey(key) {
    try {
      ensureDirectory(path.dirname(keyFile), 0o700);
      const temp = `${keyFile}.${process.pid}.tmp`;
      fs.writeFileSync(temp, key, { encoding: 'utf8', mode: 0o600 });
      fs.chmodSync(temp, 0o600);
      fs.renameSync(temp, keyFile);
      fs.chmodSync(keyFile, 0o600);
    } catch (error) {
      throw new SettingsError('key-storage', `无法保存本地密钥文件（${error.message}）。`);
    }
  }

  function removeAPIKeyFile() {
    try {
      if (fs.existsSync(keyFile)) fs.unlinkSync(keyFile);
    } catch (error) {
      throw new SettingsError('key-storage', `无法删除本地密钥文件（${error.message}）。`);
    }
  }

  function load() {
    try {
      if (fs.existsSync(settingsFile)) {
        const stored = JSON.parse(fs.readFileSync(settingsFile, 'utf8'));
        if (PROVIDERS.includes(stored.provider)) state.provider = stored.provider;
        const base = normalizeBaseURL(stored.baseURL);
        if (base) state.baseURL = base;
        // Preserve any previously saved model, including unofficial proxy
        // names; only reject empty/oversized values.
        const storedModel = normalizeModel(stored.model);
        if (storedModel) state.model = storedModel;
      }
    } catch (error) {
      console.error('EASYLENS_SETTINGS_READ_ERROR', error.message);
    }
    if (!readAPIKey() && state.provider === 'deepSeek') state.provider = 'local';
    return getPublic();
  }

  function persist() {
    try {
      ensureDirectory(root, 0o700);
      const temp = `${settingsFile}.${process.pid}.tmp`;
      fs.writeFileSync(temp, `${JSON.stringify(state, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
      fs.renameSync(temp, settingsFile);
    } catch (error) {
      throw new SettingsError('settings-storage', `无法保存设置（${error.message}）。`);
    }
  }

  function getPublic() {
    return {
      provider: state.provider,
      baseURL: state.baseURL,
      model: state.model,
      models: MODELS.slice(),
      providers: PROVIDERS.slice(),
      hasAPIKey: Boolean(readAPIKey())
    };
  }

  function save({ provider, baseURL, model, newAPIKey }) {
    if (!PROVIDERS.includes(provider)) {
      throw new SettingsError('invalid-provider', '翻译来源不可用。');
    }
    const normalizedBaseURL = normalizeBaseURL(baseURL);
    if (!normalizedBaseURL) {
      throw new SettingsError('invalid-url', '接口地址需为有效的 HTTPS 地址。');
    }
    const normalizedModel = normalizeModel(model);
    if (!normalizedModel) {
      throw new SettingsError('invalid-model', '请填写 DeepSeek 模型名称。');
    }
    const key = String(newAPIKey ?? '').trim();
    if (key) storeAPIKey(key);
    const available = Boolean(readAPIKey());
    if (provider === 'deepSeek' && !available) {
      throw new SettingsError('missing-key', '请先保存 DeepSeek API Key。');
    }
    state = { provider, baseURL: normalizedBaseURL, model: normalizedModel };
    persist();
    return getPublic();
  }

  function removeAPIKey() {
    removeAPIKeyFile();
    if (state.provider === 'deepSeek') {
      state.provider = 'local';
      persist();
    }
    return getPublic();
  }

  function deepSeekConfiguration() {
    const baseURL = validatedBaseURL(state.baseURL);
    if (!baseURL) {
      throw new SettingsError('invalid-url', '接口地址需为有效的 HTTPS 地址。');
    }
    const apiKey = readAPIKey();
    if (!apiKey) throw new SettingsError('missing-key', '请先保存 DeepSeek API Key。');
    return {
      baseURL: `${baseURL.origin}${baseURL.pathname}`.replace(/\/+$/, ''),
      model: state.model,
      apiKey
    };
  }

  return {
    root,
    keyFile,
    settingsFile,
    load,
    getPublic,
    save,
    removeAPIKey,
    deepSeekConfiguration,
    readAPIKey
  };
}

module.exports = {
  DEFAULT_BASE_URL,
  MODELS,
  MAX_MODEL_LENGTH,
  PROVIDERS,
  SettingsError,
  validatedBaseURL,
  normalizeBaseURL,
  normalizeModel,
  createSettingsStore
};
