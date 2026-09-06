#!/usr/bin/env node

/**
 * validate-fix.js — fix後のslide.jsonが情報を削っていないか決定論的に検証する
 *
 * Usage: node validate-fix.js <before.json> <after.json>
 *
 * Checks:
 *   1. コンテンツblocks数が減っていないか（br除く）
 *   2. テキスト総文字数が10%以上減っていないか
 *   3. スライド数が減っていないか
 *
 * Exit code: 0 = OK, 1 = 情報削減を検出（fix却下）
 */

const fs = require('fs');

function countContentBlocks(slides) {
  let count = 0;
  for (const slide of slides) {
    for (const block of slide.blocks || []) {
      if (block.type !== 'br') count++;
    }
  }
  return count;
}

function countTextChars(slides) {
  let chars = 0;
  for (const slide of slides) {
    for (const block of slide.blocks || []) {
      switch (block.type) {
        case 'h1': case 'h2': case 'h3': case 'text': case 'quote':
          chars += (block.text || '').length;
          break;
        case 'list': case 'olist':
          chars += (block.items || []).join('').length;
          break;
        case 'table':
          chars += (block.headers || []).join('').length;
          for (const row of block.rows || []) {
            chars += row.join('').length;
          }
          break;
        case 'code':
          chars += (block.code || '').length;
          break;
      }
    }
  }
  return chars;
}

// --- Main ---

const args = process.argv.slice(2);
if (args.length < 2) {
  console.error('Usage: node validate-fix.js <before.json> <after.json>');
  process.exit(1);
}

const before = JSON.parse(fs.readFileSync(args[0], 'utf-8'));
const after = JSON.parse(fs.readFileSync(args[1], 'utf-8'));

const beforeSlides = before.slides || [];
const afterSlides = after.slides || [];

const beforeBlocks = countContentBlocks(beforeSlides);
const afterBlocks = countContentBlocks(afterSlides);
const beforeChars = countTextChars(beforeSlides);
const afterChars = countTextChars(afterSlides);

const errors = [];

// Check 1: スライド数が減っていないか
if (afterSlides.length < beforeSlides.length) {
  errors.push(`FAIL: スライド数が減少 (${beforeSlides.length} → ${afterSlides.length})。統合ではなく分割で対応せよ`);
}

// Check 2: コンテンツblocks数が減っていないか
if (afterBlocks < beforeBlocks) {
  const diff = beforeBlocks - afterBlocks;
  errors.push(`FAIL: コンテンツblock数が ${diff} 減少 (${beforeBlocks} → ${afterBlocks})。blocks を削除するな、分割で対応せよ`);
}

// Check 3: テキスト総文字数が10%以上減っていないか
if (beforeChars > 0) {
  const ratio = afterChars / beforeChars;
  if (ratio < 0.9) {
    const pct = ((1 - ratio) * 100).toFixed(1);
    errors.push(`FAIL: テキスト総文字数が ${pct}% 減少 (${beforeChars} → ${afterChars})。情報を削るな、器を広げろ`);
  }
}

// Report
console.log(`--- validate-fix ---`);
console.log(`Slides:  ${beforeSlides.length} → ${afterSlides.length}`);
console.log(`Blocks:  ${beforeBlocks} → ${afterBlocks}`);
console.log(`Chars:   ${beforeChars} → ${afterChars}`);

if (errors.length > 0) {
  console.log(`\nRESULT: REJECTED`);
  for (const e of errors) {
    console.error(e);
  }
  process.exit(1);
} else {
  console.log(`\nRESULT: OK`);
  process.exit(0);
}
