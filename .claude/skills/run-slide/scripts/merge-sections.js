#!/usr/bin/env node
/**
 * merge-sections.js
 * セクション分割されたスライドJSONと画像JSONを統合する。
 *
 * Usage:
 *   node merge-sections.js output/{name} --sections N
 *
 * Inputs:
 *   output/{name}-s1-slide.json ... output/{name}-sN-slide.json
 *   output/{name}-s1-images.json ... output/{name}-sN-images.json (optional)
 *
 * Outputs:
 *   output/{name}-slide.json
 *   output/{name}-images.json
 */

const fs = require("fs");

const args = process.argv.slice(2);
const baseName = args[0];
const sectionsIdx = args.indexOf("--sections");
const sectionCount =
  sectionsIdx !== -1 ? parseInt(args[sectionsIdx + 1]) : 0;

if (!baseName || !sectionCount || sectionCount < 1) {
  console.error(
    "Usage: node merge-sections.js output/{name} --sections N"
  );
  process.exit(1);
}

let mergedSlides = [];
let mergedImages = [];
let metadata = null;

for (let i = 1; i <= sectionCount; i++) {
  const slideFile = `${baseName}-s${i}-slide.json`;

  if (!fs.existsSync(slideFile)) {
    console.error(`ERROR: ${slideFile} not found`);
    process.exit(1);
  }

  const data = JSON.parse(fs.readFileSync(slideFile, "utf-8"));

  // 第1セクションからメタデータ（title, theme 等）を取得
  if (i === 1) {
    metadata = { ...data };
    delete metadata.slides;
  }

  const slides = data.slides || [];
  const slideOffset = mergedSlides.length;
  mergedSlides = mergedSlides.concat(slides);

  // images.json のマージ（slideIndex をオフセット）
  const imageFile = `${baseName}-s${i}-images.json`;
  if (fs.existsSync(imageFile)) {
    const images = JSON.parse(fs.readFileSync(imageFile, "utf-8"));
    for (const img of images) {
      if (typeof img.slideIndex === "number") {
        img.slideIndex += slideOffset;
      }
      mergedImages.push(img);
    }
    console.log(
      `  Section ${i}: ${slides.length} slides, ${images.length} images`
    );
  } else {
    console.log(`  Section ${i}: ${slides.length} slides`);
  }
}

// 統合 slide.json を出力
const output = { ...metadata, slides: mergedSlides };
fs.writeFileSync(`${baseName}-slide.json`, JSON.stringify(output, null, 2));
console.log(
  `✓ Merged: ${mergedSlides.length} slides → ${baseName}-slide.json`
);

// 統合 images.json を出力
if (mergedImages.length > 0) {
  fs.writeFileSync(
    `${baseName}-images.json`,
    JSON.stringify(mergedImages, null, 2)
  );
  console.log(
    `✓ Merged: ${mergedImages.length} images → ${baseName}-images.json`
  );
} else {
  console.log("  No images to merge");
}
