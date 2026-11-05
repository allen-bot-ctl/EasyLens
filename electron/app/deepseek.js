'use strict';

const { normalizeSourceSelectionParagraphs, formatSelectionTranslation } = require('./focus-text');

class DeepSeekTranslationError extends Error {
  constructor(code, message, status = null) {
    super(message);
    this.name = 'DeepSeekTranslationError';
    this.code = code;
    this.status = status;
  }
}

function endpointFor(baseURL) {
  return new URL(`${String(baseURL).replace(/\/+$/, '')}/chat/completions`);
}

async function complete({ system, user, configuration, fetchImpl = globalThis.fetch }) {
  const endpoint = endpointFor(configuration.baseURL);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 30_000);
  let response;
  try {
    response = await fetchImpl(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${configuration.apiKey}`
      },
      body: JSON.stringify({
        model: configuration.model,
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: user }
        ],
        thinking: { type: 'disabled' },
        stream: false
      }),
      signal: controller.signal
    });
  } catch (error) {
    if (error.name === 'AbortError') {
      throw new DeepSeekTranslationError('timeout', 'DeepSeek 请求超时（30 秒）。');
    }
    throw new DeepSeekTranslationError('network', `无法连接 DeepSeek：${error.message}`);
  } finally {
    clearTimeout(timer);
  }

  if (!response.ok) {
    throw new DeepSeekTranslationError(
      'http',
      `DeepSeek 请求失败（HTTP ${response.status}）。请检查接口地址、模型和 API Key。`,
      response.status
    );
  }

  let payload;
  try {
    payload = await response.json();
  } catch {
    throw new DeepSeekTranslationError('bad-response', 'DeepSeek 返回了无法读取的响应。');
  }
  const content = payload?.choices?.[0]?.message?.content;
  if (typeof content !== 'string') {
    throw new DeepSeekTranslationError('bad-response', 'DeepSeek 返回了无法读取的响应。');
  }
  const trimmed = content.trim();
  if (!trimmed) {
    throw new DeepSeekTranslationError('empty', 'DeepSeek 未返回译文。');
  }
  return trimmed;
}

async function translateWord({ anchor, sentence, configuration, fetchImpl }) {
  const instruction =
    '你是英译中词典。仅翻译目标英文词在给定句子中的含义。' +
    '只返回一个简短、自然的简体中文词义，不要解释、引号或 Markdown。句子只用于消歧。';
  const input = `目标词：${anchor}\n句子：${sentence}`;
  const chinese = await complete({
    system: instruction,
    user: input,
    configuration,
    fetchImpl
  });
  return { chinese, basis: '语境翻译' };
}

async function translateSelection({ text, configuration, fetchImpl }) {
  const normalized = normalizeSourceSelectionParagraphs(text);
  const instruction = [
    '你是专业英译中翻译器。将用户提供的英文选区准确翻译为简体中文。',
    '要求：',
    '1. 严格保留原文的段落结构、列表结构与换行：若原文包含多个段落、列表项或换行，译文必须在对应位置保留分段与换行，严禁将多段或列表内容合并堆叠为单一行或单一段落；',
    '2. 保持列表项标记（如原样保留项目符号 • 或数字编号），每个列表项单独成行；',
    '3. 只返回纯文本译文，不要添加任何解释、前缀、引号、Markdown 标题或代码块。'
  ].join('\n');
  const raw = await complete({
    system: instruction,
    user: normalized || text,
    configuration,
    fetchImpl
  });
  return formatSelectionTranslation(raw, normalized);
}

module.exports = {
  DeepSeekTranslationError,
  endpointFor,
  translateWord,
  translateSelection
};
