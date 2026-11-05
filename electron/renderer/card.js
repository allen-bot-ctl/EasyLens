'use strict';

const card = document.getElementById('card');
const title = document.getElementById('title');
const text = document.getElementById('text');
const loading = document.getElementById('loading');
const hint = document.getElementById('hint');

function measureAndResize() {
  card.style.width = 'max-content';
  const natural = card.getBoundingClientRect();
  const width = Math.max(200, Math.min(460, natural.width));
  card.style.width = `${width}px`;
  const height = card.getBoundingClientRect().height;
  window.easylens.resizeCard({
    width: Math.ceil(width + 12),
    height: Math.ceil(height + 12)
  });
}

window.easylens.onCardShow((payload) => {
  if (!payload) return;
  const loadingMode = payload.kind === 'loading';
  title.textContent = payload.title || '';
  title.hidden = !payload.title;
  text.textContent = loadingMode ? '' : (payload.text || '');
  text.hidden = loadingMode || !payload.text;
  text.classList.toggle('selection', payload.kind === 'selection');
  loading.hidden = !loadingMode;
  hint.hidden = true;
  hint.textContent = '';
  card.dataset.kind = payload.kind || 'word';
  requestAnimationFrame(() => requestAnimationFrame(measureAndResize));
});

window.addEventListener('resize', () => {
  // The window size is driven by the content; avoid a feedback loop by only
  // re-measuring when the text actually overflows the current width.
  if (card.scrollWidth > window.innerWidth + 1) measureAndResize();
});

measureAndResize();
