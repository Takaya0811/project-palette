#!/usr/bin/env node
/**
 * estimate-slides.js — ソース構造ベースのスライド枚数見積もり
 *
 * Usage:
 *   node estimate-slides.js <source.md> [density]
 *
 * Arguments:
 *   source.md  ソースファイルパス
 *   density    compact | standard (default) | detailed | rich
 *
 * Output: JSON
 *
 * 見出し・コードブロック・画像・テキスト量から積み上げで見積もる。
 */
const fs = require("fs");
const path = process.argv[2];
if (!path || !fs.existsSync(path)) {
  console.error("Usage: node estimate-slides.js <source.md> [density]");
  process.exit(1);
}

const src = fs.readFileSync(path, "utf-8");
const lines = src.split("\n");

// 構造要素をカウント
let h2 = 0, h3 = 0, codeBlocks = 0, images = 0, inCode = false;
for (const line of lines) {
  if (line.startsWith("```")) { inCode = !inCode; if (inCode) codeBlocks++; continue; }
  if (inCode) continue;
  if (/^## /.test(line)) h2++;
  else if (/^### /.test(line)) h3++;
  else if (/!\[.*\]\(.*\)/.test(line)) images++;
}

const chars = src.length;

// 構造ベース: h3は親h2に統合されがち、コードはインライン多い
const structural = h2 * 1.5 + h3 * 0.3 + codeBlocks * 0.5 + images + 2;

// 文字数ベース: 日本語は1文字の情報密度が高いため270文字/スライド
const charBased = chars / 270;

// レンジ算出: structural と charBased の乖離が幅になる
const lo = Math.min(structural, charBased);
const hi = Math.max(structural, charBased) * 1.3;
const recommended = Math.round((structural + charBased) / 2);

const density = process.argv[3] || "standard";
const factors = { compact: 0.7, standard: 1.0, detailed: 1.3, rich: 1.6 };
const factor = factors[density] || 1.0;

const range = [
  Math.max(8, Math.round(lo * factor)),
  Math.min(100, Math.round(hi * factor)),
];
const slides = Math.max(8, Math.round(recommended * factor));
const isLow = range[1] <= 12;

console.log(JSON.stringify({
  chars,
  density,
  factor,
  structure: { h2, h3, codeBlocks, images },
  structural: Math.round(structural),
  charBased: Math.round(charBased),
  slides,
  range,
  isLow,
  ...(isLow && {
    suggestion: `${range[0]}-${range[1]}枚見積もり。このまま進めるか、関連情報の追加・インタビューで補完するかユーザーに確認してください。`,
  }),
}));
