#!/usr/bin/env node

// validate-images.js — slide.json 内の全画像パスの存在を検証する
// Usage: node validate-images.js output/{name}-slide.json

const fs = require('fs');
const path = require('path');

const inputPath = process.argv[2];
if (!inputPath) {
  console.error('Usage: node validate-images.js <slide.json>');
  process.exit(1);
}

const raw = fs.readFileSync(inputPath, 'utf-8');
const data = JSON.parse(raw);

// MD file is generated next to the JSON file (same directory)
const mdDir = path.dirname(path.resolve(inputPath));

let total = 0;
let missing = 0;
const errors = [];

for (let i = 0; i < data.slides.length; i++) {
  const slide = data.slides[i];
  for (const block of slide.blocks) {
    if (block.type !== 'image') continue;
    total++;

    const src = block.src;

    // Check for common path mistakes
    if (src.includes('/output/')) {
      errors.push(`  slide[${i}]: "${src}" — パスに /output/ が含まれています。Marp は MD ファイル（output/ 内）からの相対パスで解決するため、"./output/" は二重パスになります。"./${path.basename(src)}" に修正してください。`);
      missing++;
      continue;
    }

    // Resolve path relative to the MD file location
    const resolved = path.resolve(mdDir, src);
    if (!fs.existsSync(resolved)) {
      errors.push(`  slide[${i}]: "${src}" → ${resolved} が見つかりません`);
      missing++;
    }
  }
}

if (errors.length > 0) {
  console.error(`❌ ${missing}/${total} 枚の画像に問題があります:`);
  errors.forEach(e => console.error(e));
  process.exit(1);
} else if (total === 0) {
  console.log('⚠️  画像スライドがありません');
} else {
  console.log(`✅ 全画像OK（${total}枚）`);
}
