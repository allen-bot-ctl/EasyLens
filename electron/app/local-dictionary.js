'use strict';

const fs = require('node:fs');
const path = require('node:path');

const dictionaryPath = path.join(__dirname, '..', 'data', 'en-zh.json');

let dictionaryCache = null;

// Small additions for product names and software terms that the general
// dictionary does not contain. Values are short glosses, not full entries.
const supplement = {
  app: '应用，应用程序',
  apps: '应用（复数）',
  deepseek: 'DeepSeek（深度求索）',
  easylens: 'EasyLens（本应用）',
  electron: 'Electron（桌面应用框架）',
  github: 'GitHub（代码托管平台）',
  javascript: 'JavaScript（编程语言）',
  typescript: 'TypeScript（编程语言）',
  openclaw: 'OpenClaw（工具名）',
  renderer: '渲染器；渲染进程',
  renderers: '渲染器（复数）',
  screenshot: '截图',
  screenshots: '截图（复数）',
  settings: '设置',
  setting: '设置；环境',
  service: '服务',
  services: '服务（复数）',
  right: '权利；右边；正确的',
  rights: '权利（复数）',
  tray: '托盘；菜单栏图标',
  menu: '菜单',
  overlay: '覆盖层；浮层',
  clipboard: '剪贴板',
  cursor: '光标',
  pointer: '指针；鼠标位置',
  ocr: 'OCR（光学字符识别）',
  api: 'API（程序接口）',
  key: '钥匙；密钥',
  token: '标记；令牌',
  model: '模型',
  provider: '提供方',
  translation: '翻译',
  translator: '翻译器',
  dictionary: '词典',
  local: '本地',
  cloud: '云端',
  permission: '权限',
  accessibility: '辅助功能',
  capture: '捕获；截取',
  shortcut: '快捷键',
  dropdown: '下拉菜单',
  checkbox: '复选框',
  button: '按钮',
  window: '窗口',
  windowed: '窗口模式的',
  browser: '浏览器',
  linux: 'Linux（操作系统）',
  macos: 'macOS（操作系统）',
  swift: 'Swift（编程语言）',
  swiftui: 'SwiftUI（界面框架）',
  vision: '视觉；Vision 框架',
  screencapturekit: 'ScreenCaptureKit（屏幕捕获框架）',
  privacy: '隐私',
  policy: '政策；策略',
  terms: '条款',
  selection: '选择；选区',
  select: '选择',
  selected: '已选中的',
  screenshotting: '截屏',
  runtime: '运行时',
  backend: '后端',
  frontend: '前端',
  build: '构建；版本',
  install: '安装',
  package: '包；软件包',
  module: '模块',
  import: '导入',
  export: '导出',
  config: '配置',
  configuration: '配置',
  environment: '环境',
  variable: '变量',
  function: '函数',
  method: '方法',
  object: '对象',
  class: '类',
  array: '数组',
  string: '字符串',
  number: '数字',
  boolean: '布尔值',
  async: '异步的',
  promise: 'Promise（异步对象）',
  error: '错误',
  warning: '警告',
  debug: '调试',
  release: '发布；版本',
  test: '测试',
  tests: '测试（复数）',
  buildable: '可构建的',
  cross: '跨；交叉',
  platform: '平台',
  desktop: '桌面',
  laptop: '笔记本电脑',
  click: '点击',
  hover: '悬停',
  drag: '拖动',
  scroll: '滚动',
  gesture: '手势',
  hotkey: '热键',
  focus: '焦点；专注',
  focused: '聚焦的',
  anchor: '锚点；目标词',
  context: '上下文；语境',
  sentence: '句子',
  paragraph: '段落',
  line: '行；线路',
  word: '单词；词',
  words: '单词（复数）',
  character: '字符；人物',
  letter: '字母；信',
  language: '语言',
  english: '英语',
  chinese: '中文',
  japanese: '日语',
  detect: '检测',
  detection: '检测',
  recognize: '识别',
  recognition: '识别',
  confidence: '置信度',
  image: '图像',
  pixel: '像素',
  pixels: '像素（复数）',
  crop: '裁剪',
  scale: '缩放；比例',
  opacity: '不透明度',
  transparent: '透明的',
  animation: '动画',
  breathe: '呼吸',
  eye: '眼睛',
  lens: '透镜；镜头',
  pupil: '瞳孔',
  iris: '虹膜',
  eyelid: '眼睑',
  fiber: '纤维',
  fibers: '纤维（复数）',
  yellow: '黄色',
  red: '红色',
  orange: '橙色',
  green: '绿色',
  blue: '蓝色',
  black: '黑色',
  white: '白色',
  dark: '深色；暗的',
  light: '浅色；光',
  card: '卡片',
  loading: '加载中',
  ready: '就绪',
  hidden: '隐藏的',
  visible: '可见的',
  launch: '启动',
  quit: '退出',
  exit: '退出',
  resume: '恢复；简历',
  installable: '可安装的',
  secure: '安全的',
  secret: '密钥；秘密',
  https: 'HTTPS（加密网络协议）',
  endpoint: '接口地址',
  request: '请求',
  response: '响应',
  server: '服务器',
  client: '客户端',
  network: '网络',
  offline: '离线',
  online: '在线',
  cache: '缓存',
  timeout: '超时',
  retry: '重试',
  fallback: '回退方案',
  quality: '质量',
  fluent: '流畅的',
  glossary: '词汇表',
  phrase: '短语',
  meaning: '含义',
  definition: '定义',
  pronunciation: '发音',
  phonetic: '音标',
  noun: '名词',
  verb: '动词',
  adjective: '形容词',
  adverb: '副词',
  preposition: '介词',
  conjunction: '连词',
  pronoun: '代词'
};

function loadDictionary() {
  if (dictionaryCache) return dictionaryCache;
  try {
    dictionaryCache = JSON.parse(fs.readFileSync(dictionaryPath, 'utf8'));
  } catch (error) {
    console.error('EASYLENS_DICTIONARY_ERROR', error.message);
    dictionaryCache = {};
  }
  return dictionaryCache;
}

function normalizeKey(value) {
  return String(value ?? '').trim().toLowerCase().replaceAll('’', "'");
}

function shortGloss(value, maxLength = 48) {
  if (!value) return '';
  let text = String(value)
    .replace(/\[[^\]]*\]/g, '')
    .replace(/^(?:n|v|vt|vi|a|adj|adv|prep|conj|pron|interj|num|art|aux|abbr)\.\s*/i, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (!text) return '';
  const pieces = text.split(/[；;]/).map((piece) => piece.trim()).filter(Boolean);
  text = pieces.slice(0, 2).join('；');
  if (text.length > maxLength) text = `${text.slice(0, maxLength - 1)}…`;
  return text;
}

function directLookup(word) {
  const key = normalizeKey(word);
  if (!key) return null;
  const dictionary = loadDictionary();
  if (Object.hasOwn(dictionary, key)) {
    return { gloss: dictionary[key], matched: key, form: 'exact' };
  }
  if (Object.hasOwn(supplement, key)) {
    return { gloss: supplement[key], matched: key, form: 'exact' };
  }
  return null;
}

function candidateForms(word) {
  const key = normalizeKey(word);
  if (!key || key.length < 2) return [];
  const forms = [];
  const add = (candidate) => {
    if (candidate && candidate !== key && candidate.length >= 2 && !forms.includes(candidate)) {
      forms.push(candidate);
    }
  };

  if (key.endsWith("'s")) add(key.slice(0, -2));
  if (key.endsWith('ies') && key.length > 4) add(`${key.slice(0, -3)}y`);
  if (key.endsWith('ves') && key.length > 4) {
    add(`${key.slice(0, -3)}f`);
    add(`${key.slice(0, -3)}fe`);
  }
  if (key.endsWith('es') && key.length > 3) add(key.slice(0, -2));
  if (key.endsWith('s') && key.length > 3) add(key.slice(0, -1));
  if (key.endsWith('ied') && key.length > 4) add(`${key.slice(0, -3)}y`);
  if (key.endsWith('ed') && key.length > 3) {
    add(key.slice(0, -2));
    add(key.slice(0, -1));
    if (key.length > 4 && key.at(-3) === key.at(-4)) add(key.slice(0, -3));
  }
  if (key.endsWith('ing') && key.length > 4) {
    add(key.slice(0, -3));
    add(`${key.slice(0, -3)}e`);
    if (key.length > 5 && key.at(-4) === key.at(-5)) add(key.slice(0, -4));
  }
  if (key.endsWith('ly') && key.length > 4) {
    add(key.slice(0, -2));
    if (key.endsWith('ily')) add(`${key.slice(0, -3)}y`);
  }
  if (key.endsWith('ier') && key.length > 4) add(`${key.slice(0, -3)}y`);
  if (key.endsWith('er') && key.length > 4) add(key.slice(0, -2));
  if (key.endsWith('iest') && key.length > 5) add(`${key.slice(0, -4)}y`);
  if (key.endsWith('est') && key.length > 5) add(key.slice(0, -3));
  return forms;
}

function lookup(word) {
  const direct = directLookup(word);
  if (direct) return direct;
  for (const candidate of candidateForms(word)) {
    const found = directLookup(candidate);
    if (found) {
      return { gloss: found.gloss, matched: found.matched, form: 'inflection' };
    }
  }
  return null;
}

function glossFor(word, maxLength = 48) {
  const found = lookup(word);
  return found ? { text: shortGloss(found.gloss, maxLength), ...found } : null;
}

module.exports = {
  lookup,
  glossFor,
  shortGloss,
  normalizeKey,
  supplement,
  loadDictionary
};
