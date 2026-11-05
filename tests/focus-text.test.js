'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  eligibleEnglishText,
  selectedTextAtFocus,
  relativeTimeChinese,
  formatSelectionTranslation,
  normalizeSourceSelectionParagraphs,
  matchSelectionInBlocks,
  looksLikePathOrCode,
  clipboardWords,
  hintSupportsFocus
} = require('../electron/app/focus-text');

test('English gate skips non-English text and keeps English', () => {
  assert.equal(eligibleEnglishText('这是中文段落', 1200), null);
  assert.equal(eligibleEnglishText('Good morning!', 1200), 'Good morning!');
});

test('selections support the current focus but not stale nearby text', () => {
  assert.ok(selectedTextAtFocus('before the meeting', 'before',
    'before the meeting', 0));
  assert.equal(selectedTextAtFocus('before the meeting', 'before',
    'before the calendar', 0), null);
  assert.equal(selectedTextAtFocus('one two', 'Two', 'three Two', 1), null);
});

test('relative time is translated without a cloud request', () => {
  assert.equal(relativeTimeChinese('3 hours ago'), '3小时前');
  assert.equal(relativeTimeChinese('2 days ago'), '2天前');
});

test('path detection keeps prose comments translatable', () => {
  assert.equal(looksLikePathOrCode('node_modules/openclaw'), true);
  assert.equal(looksLikePathOrCode('// Use the vendor lock carefully'), false);
});

test('formatSelectionTranslation preserves multiple paragraphs', () => {
  const input = '第一段内容。\n\n第二段内容。\n\n\n第三段内容。';
  assert.equal(formatSelectionTranslation(input), '第一段内容。\n第二段内容。\n第三段内容。');
});

test('normalizeSourceSelectionParagraphs splits Chromium inline bullets', () => {
  const raw = 'What you can expect from us, which describes how we provide and develop our services• What we expect from you, which establishes certain rules for using our services• Content in Google services, which describes the intellectual property rights to the content you find in our services — whether that content belongs to you, Google, or others• In case of problems or disagreements, which describes other legal rights you have, and what to expect in case someone violates these terms';
  const eligible = eligibleEnglishText(raw, 1200);
  const lines = eligible.split('\n');
  assert.equal(lines.length, 4);
  assert.equal(lines[0], '• What you can expect from us, which describes how we provide and develop our services');
  assert.equal(lines[1], '• What we expect from you, which establishes certain rules for using our services');
});

test('matchSelectionInBlocks reconstructs plain paragraphs and lists', () => {
  const blocks = [
    'Understanding these terms is important because you’re agreeing to these terms.',
    'Besides these terms, we also publish a Privacy Policy.',
    'We encourage you to read it carefully.'
  ];
  assert.equal(matchSelectionInBlocks(blocks.join(''), blocks), blocks.join('\n'));
});

test('matchSelectionInBlocks projects boundaries when an inline widget differs', () => {
  const blocks = [
    'What’s covered in these terms',
    'We know it’s tempting to skip these Terms of Service, but it’s important to establish what you can expect from us as you use Google services?, and what we expect from you.',
    'These Terms of Service reflect the way Google’s business works.'
  ];
  const raw = 'What’s covered in these termsWe know it’s tempting to skip these Terms of Service, but it’s important to establish what you can expect from us as you use Google services, and what we expect from you.These Terms of Service reflect the way Google’s business works.';
  const lines = matchSelectionInBlocks(raw, blocks).split('\n');
  assert.equal(lines.length, 3);
  assert.equal(lines[0], 'What’s covered in these terms');
  assert.ok(lines[1].startsWith('We know it’s tempting to skip'));
  assert.equal(lines[2], 'These Terms of Service reflect the way Google’s business works.');
});

test('normalization splits heading and punctuated paragraph seams', () => {
  const raw = 'What’s covered in these termsWe know it’s tempting to skip these Terms of Service, but it’s important to establish what you can expect from us as you use Google services, and what we expect from you.These Terms of Service reflect the way Google’s business works, the laws that apply to our company, and certain things we’ve always believed to be true. As a result, these Terms of Service help define Google’s relationship with you as you interact with our services. For example, these terms include the following topic headings:• What you can expect from us, which describes how we provide and develop our services• What we expect from you, which establishes certain rules for using our services';
  const lines = normalizeSourceSelectionParagraphs(raw).split('\n');
  assert.equal(lines.length, 5);
  assert.equal(lines[0], 'What’s covered in these terms');
  assert.equal(lines[1], 'We know it’s tempting to skip these Terms of Service, but it’s important to establish what you can expect from us as you use Google services, and what we expect from you.');
  assert.ok(lines[2].startsWith('These Terms of Service reflect the way'));
  assert.ok(lines[2].endsWith('following topic headings:'));
  assert.ok(lines[3].startsWith('• What you can expect from us'));
  assert.ok(lines[4].startsWith('• What we expect from you'));
});

test('normalization preserves brand names in prose', () => {
  const prose = 'You can use GitHub, JavaScript, DeepSeek, YouTube, iPhone, and macOS in your daily workflow.';
  assert.equal(normalizeSourceSelectionParagraphs(prose), prose);
});

test('long multi-paragraph prose with URLs remains eligible', () => {
  const paragraph = 'We know it’s tempting to skip these Terms of Service, and/or to overlook how country/region rules apply when you visit https://policies.google.com/terms or read our documentation.';
  const longSelection = Array.from({ length: 10 }, () => paragraph).join('\n');
  assert.ok(longSelection.length > 1200);
  assert.ok(eligibleEnglishText(longSelection, 4000));
});

test('formatSelectionTranslation restores a middle-dot delimited list', () => {
  for (const dot of ['・', '·', '•']) {
    const input = [
      '您可以在期待我们做什么，其中说明了我们如何提供和发展我们的服务',
      '我们期待您做什么，其中确立了使用我们服务的某些规则',
      'Google 服务中的内容，其中描述了您在我们服务中找到的内容的知识产权——无论该内容属于您、Google 还是他人',
      '如果出现问题或分歧，其中描述了您拥有的其他法律权利，以及如果有人违反这些条款会发生什么'
    ].join(dot);
    const source = '• What you can expect from us...\n• What we expect from you...\n• Content in Google services...\n• In case of problems...';
    const lines = formatSelectionTranslation(input, source).split('\n');
    assert.equal(lines.length, 4, `failed for dot ${dot}`);
    assert.ok(lines[0].startsWith('• 您可以在期待我们做什么'));
    assert.ok(lines[1].startsWith('• 我们期待您做什么'));
    assert.ok(lines[2].startsWith('• Google 服务中的内容'));
    assert.ok(lines[3].startsWith('• 如果出现问题或分歧'));
  }
});

test('formatSelectionTranslation preserves foreign names with middle dots', () => {
  for (const name of ['莱昂纳多・达・芬奇', '莱昂纳多·达·芬奇']) {
    assert.equal(formatSelectionTranslation(name, 'Leonardo da Vinci'), name);
  }
});

test('formatSelectionTranslation strips outer quotes and markdown headings', () => {
  const input = '"### 条款标题\n第一项说明 • 第二项说明"';
  assert.deepEqual(formatSelectionTranslation(input).split('\n'),
    ['条款标题', '第一项说明', '• 第二项说明']);
});

test('clipboard hints corroborate a focus word', () => {
  assert.equal(hintSupportsFocus('before the meeting', 'meeting'), true);
  assert.equal(hintSupportsFocus('before the meeting', 'calendar'), false);
  assert.deepEqual(clipboardWords('It’s fine'), ["it's", 'fine']);
});
