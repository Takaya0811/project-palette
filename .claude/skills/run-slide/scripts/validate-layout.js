#!/usr/bin/env node

/**
 * validate-layout.js — スライドJSONのレイアウトオーバーフローを決定論的に検出する
 *
 * Usage: node validate-layout.js <slide.json>
 *
 * Marpスライド (1280x720) の各テーマCSSの制約から、
 * ブロック構成の推定高さを計算し、コンテンツ領域を超過する場合にWARNINGを出す。
 *
 * Exit code: 0 = OK, 1 = オーバーフロー検出
 */

const fs = require('fs');

// --- Slide dimensions ---
const SLIDE_W = 1280;
const SLIDE_H = 720;

// --- Theme constants (extracted from CSS) ---
const THEMES = {
  kanso: {
    paddingTop: 60, paddingBottom: 60, paddingLeft: 60, paddingRight: 60,
    h2MarginTop: 112,  // h2 + * { margin-top: 112px }
    fontSize: 30, lineHeight: 1.7,
    h3FontSize: 28, h3MarginTop: 32, h3MarginBottom: 12,
    listMarginBottom: 12,
    tableFontSize: 24, tableThPadding: 10, tableTdPadding: 8,
    codeFontSize: 18, codeLineHeight: 1.7, codePaddingV: 16,
    quoteFontSize: 26, quotePaddingV: 12, quoteMarginV: 16,
  },
  prisma: {
    paddingTop: 56, paddingBottom: 56, paddingLeft: 56, paddingRight: 56,
    h2MarginTop: 112,
    fontSize: 30, lineHeight: 1.6,
    h3FontSize: 28, h3MarginTop: 28, h3MarginBottom: 12,
    listMarginBottom: 12,
    tableFontSize: 24, tableThPadding: 10, tableTdPadding: 8,
    codeFontSize: 18, codeLineHeight: 1.6, codePaddingV: 16,
    quoteFontSize: 26, quotePaddingV: 12, quoteMarginV: 16,
  },
  abyss: {
    paddingTop: 60, paddingBottom: 60, paddingLeft: 60, paddingRight: 60,
    h2MarginTop: 120,
    fontSize: 32, lineHeight: 1.6,
    h3FontSize: 34, h3MarginTop: 28, h3MarginBottom: 12,
    listMarginBottom: 14,
    tableFontSize: 26, tableThPadding: 14, tableTdPadding: 12,
    codeFontSize: 20, codeLineHeight: 1.5, codePaddingV: 20,
    quoteFontSize: 28, quotePaddingV: 16, quoteMarginV: 20,
  },
  tabula: {
    paddingTop: 72, paddingBottom: 72, paddingLeft: 72, paddingRight: 72,
    h2MarginTop: 120,
    fontSize: 30, lineHeight: 1.6,
    h3FontSize: 34, h3MarginTop: 32, h3MarginBottom: 8,
    listMarginBottom: 12,
    tableFontSize: 24, tableThPadding: 12, tableTdPadding: 12,
    codeFontSize: 18, codeLineHeight: 1.7, codePaddingV: 20,
    quoteFontSize: 26, quotePaddingV: 16, quoteMarginV: 16,
  },
  sumi: {
    paddingTop: 60, paddingBottom: 60, paddingLeft: 72, paddingRight: 60,
    h2MarginTop: 96,
    fontSize: 30, lineHeight: 1.7,
    h3FontSize: 26, h3MarginTop: 28, h3MarginBottom: 12,
    listMarginBottom: 12,
    tableFontSize: 24, tableThPadding: 10, tableTdPadding: 8,
    codeFontSize: 18, codeLineHeight: 1.7, codePaddingV: 18,
    quoteFontSize: 26, quotePaddingV: 14, quoteMarginV: 16,
  },
};

// --- Helpers ---

/**
 * Markdownインライン記法を除いた実テキスト長を返す（日本語全角は幅2倍）
 * Returns: visual width in "half-width character units"
 */
function visualTextWidth(text) {
  // Strip markdown bold/italic markers
  const stripped = text
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/\*(.+?)\*/g, '$1')
    .replace(/__(.+?)__/g, '$1')
    .replace(/_(.+?)_/g, '$1')
    .replace(/`(.+?)`/g, '$1')
    .replace(/\[(.+?)\]\(.+?\)/g, '$1');

  let width = 0;
  for (const ch of stripped) {
    const code = ch.codePointAt(0);
    // CJK ranges: full-width = 2 units
    if (
      (code >= 0x3000 && code <= 0x9FFF) ||   // CJK, Hiragana, Katakana
      (code >= 0xF900 && code <= 0xFAFF) ||   // CJK Compatibility
      (code >= 0xFF01 && code <= 0xFF60) ||   // Fullwidth forms
      (code >= 0x20000 && code <= 0x2FA1F)    // CJK Extension B+
    ) {
      width += 2;
    } else {
      width += 1;
    }
  }
  return width;
}

/**
 * テキストの折り返し行数を推定
 */
function estimateTextLines(text, charsPerLine) {
  const width = visualTextWidth(text);
  return Math.max(1, Math.ceil(width / charsPerLine));
}

/**
 * 画像がbg右配置かどうか判定
 */
function isRightImage(block, slideClass) {
  if (block.type !== 'image') return false;
  const pos = block.position || '';
  const isFullImage = /\bfull-image\b/.test(slideClass || '');
  if (isFullImage) return false;
  return /^(right|left)/i.test(pos);
}

/**
 * 右配置画像の占有幅割合を取得（例: "right:40%" → 0.4）
 */
function getImageWidthRatio(block) {
  const pos = block.position || '';
  const match = pos.match(/:(\d+)%/);
  return match ? parseInt(match[1]) / 100 : 0.4; // default 40%
}

// --- Main layout estimator ---

function estimateSlideHeight(slide, theme) {
  const t = THEMES[theme];
  if (!t) return { height: 0, available: 999, details: [] };

  const slideClass = slide.class || '';
  const blocks = slide.blocks || [];

  // Skip lead/full-image slides
  if (/\blead\b/.test(slideClass) || /\bfull-image\b/.test(slideClass)) {
    return { height: 0, available: 999, skip: true, details: [] };
  }

  const contentWidth = SLIDE_W - t.paddingLeft - t.paddingRight;
  const availableHeight = SLIDE_H - t.paddingTop - t.paddingBottom;

  // Detect h2 and right-image presence
  const hasH2 = blocks.some(b => b.type === 'h2');
  const rightImage = blocks.find(b => isRightImage(b, slideClass));
  const imageWidthRatio = rightImage ? getImageWidthRatio(rightImage) : 0;

  // Effective content width (narrowed if right-image)
  const effectiveWidth = contentWidth * (1 - imageWidthRatio);

  // Characters per line (Noto Sans JP: full-width char ~= fontSize * 1.0, half-width ~= fontSize * 0.55)
  // We use half-width units, so charsPerLine = effectiveWidth / (fontSize * 0.55)
  const charsPerLine = Math.floor(effectiveWidth / (t.fontSize * 0.55));

  let totalHeight = 0;
  const details = [];

  // h2 area: absolute positioned, adds margin-top to next element
  if (hasH2) {
    totalHeight += t.h2MarginTop;
    details.push({ type: 'h2-area', height: t.h2MarginTop });
  }

  for (const block of blocks) {
    let blockHeight = 0;

    switch (block.type) {
      case 'h2':
        // absolute positioned — already accounted for via h2MarginTop
        blockHeight = 0;
        break;

      case 'h3':
        blockHeight = t.h3MarginTop + t.h3FontSize * 1.3 + t.h3MarginBottom;
        break;

      case 'text': {
        const lines = estimateTextLines(block.text || '', charsPerLine);
        blockHeight = lines * t.fontSize * t.lineHeight;
        break;
      }

      case 'list':
      case 'olist': {
        const items = block.items || [];
        let listHeight = 0;
        for (const item of items) {
          const lines = estimateTextLines(item, charsPerLine);
          listHeight += lines * t.fontSize * t.lineHeight + t.listMarginBottom;
        }
        blockHeight = listHeight;
        break;
      }

      case 'table': {
        const headers = block.headers || [];
        const rows = block.rows || [];
        const headerHeight = t.tableFontSize * 1.3 + t.tableThPadding * 2;
        const rowHeight = t.tableFontSize * 1.3 + t.tableTdPadding * 2;
        blockHeight = headerHeight + rows.length * rowHeight + 8; // +8 for margin-top
        break;
      }

      case 'code': {
        const codeLines = (block.code || '').split('\n').length;
        blockHeight = codeLines * t.codeFontSize * t.codeLineHeight + t.codePaddingV * 2;
        break;
      }

      case 'quote': {
        const quoteCharsPerLine = Math.floor(effectiveWidth / (t.quoteFontSize * 0.55));
        const lines = estimateTextLines(block.text || '', quoteCharsPerLine);
        blockHeight = lines * t.quoteFontSize * 1.6 + t.quotePaddingV * 2 + t.quoteMarginV;
        break;
      }

      case 'image': {
        // Right/bg images don't consume height in content flow
        if (isRightImage(block, slideClass)) {
          blockHeight = 0;
        } else {
          const pos = block.position || '';
          const isFullImage = /\bfull-image\b/.test(slideClass);
          const isBg = isFullImage || /^(contain|cover)$/i.test(pos);
          if (isBg) {
            blockHeight = 0;
          } else {
            // Inline block-image — flex: 1 1 0, takes remaining space. Estimate 200px.
            blockHeight = 200;
          }
        }
        break;
      }

      case 'br':
        blockHeight = (block.count || 1) * 30; // spacer div with height: 1em (~30px at font-size 30)
        break;

      case 'h1':
        // h1 is typically only on lead slides (skipped), but account for it
        blockHeight = 52 * 1.2 + 16; // font-size * line-height + margin
        break;

      default:
        blockHeight = 0;
    }

    if (blockHeight > 0) {
      details.push({ type: block.type, height: Math.round(blockHeight), text: (block.text || '').substring(0, 30) });
    }
    totalHeight += blockHeight;
  }

  return {
    height: Math.round(totalHeight),
    available: availableHeight,
    skip: false,
    details,
  };
}

// --- Main ---

const inputPath = process.argv[2];
if (!inputPath) {
  console.error('Usage: node validate-layout.js <slide.json>');
  process.exit(1);
}

const raw = fs.readFileSync(inputPath, 'utf-8');
const data = JSON.parse(raw);

const theme = data.theme || 'kanso';
const slides = data.slides || [];

if (!THEMES[theme]) {
  console.error(`❌ 未知のテーマ: "${theme}"。対応テーマ: ${Object.keys(THEMES).join(', ')}`);
  process.exit(1);
}

const BUFFER = 0.85; // 15%バッファ — 明らかなオーバーフローだけ検出
const warnings = [];

for (let i = 0; i < slides.length; i++) {
  const slide = slides[i];
  const result = estimateSlideHeight(slide, theme);

  if (result.skip) continue;

  const threshold = result.available * (1 / BUFFER); // available is the limit; we warn when height > available / BUFFER
  // Actually: warn when estimated > available. Buffer means we undercount by 15%, so only clear overflows are caught.
  // Simpler: apply buffer to estimated height
  const adjustedHeight = Math.round(result.height * BUFFER);

  if (adjustedHeight > result.available) {
    const overflow = adjustedHeight - result.available;
    const slideClass = slide.class || '';
    const h2Block = slide.blocks.find(b => b.type === 'h2');
    const title = h2Block ? h2Block.text : '(no h2)';

    let detail = `  slide[${i}] "${title}"`;
    detail += ` — 推定${adjustedHeight}px / 上限${result.available}px（+${overflow}px超過）`;

    if (slideClass) detail += ` [class: ${slideClass}]`;

    // Add breakdown
    const breakdown = result.details
      .filter(d => d.height > 0)
      .map(d => `    ${d.type}: ${d.height}px${d.text ? ` "${d.text}"` : ''}`)
      .join('\n');
    if (breakdown) detail += '\n' + breakdown;

    warnings.push(detail);
  }
}

if (warnings.length > 0) {
  console.error(`⚠️  レイアウト警告: ${warnings.length}枚のスライドでオーバーフローの可能性`);
  warnings.forEach(w => console.error(w));
  process.exit(1);
} else {
  console.log(`✅ レイアウトOK（${slides.length}枚）`);
}
