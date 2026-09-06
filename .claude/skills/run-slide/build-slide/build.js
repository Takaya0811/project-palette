#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const THEMES_DIR = path.join(__dirname, 'themes');

// --- Theme CSS loader ---

function loadThemeCSS(themeName) {
  const cssPath = path.join(THEMES_DIR, `${themeName}.css`);
  if (!fs.existsSync(cssPath)) {
    const available = fs.readdirSync(THEMES_DIR)
      .filter(f => f.endsWith('.css'))
      .map(f => f.replace('.css', ''));
    console.error(`Error: theme "${themeName}" not found.`);
    console.error(`Available: ${available.join(', ')}`);
    process.exit(1);
  }
  return fs.readFileSync(cssPath, 'utf-8');
}

// --- Base CSS for inline block images ---

const BASE_CSS = `
/* Ensure section is a flex column so block-image can fill remaining space */
section {
  display: flex !important;
  flex-direction: column !important;
}

/* Block-level inline images (non-bg) */
.block-image {
  display: flex;
  justify-content: center;
  align-items: center;
  flex: 1 1 0;
  min-height: 0;
}
.block-image img {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
}

/* Block-level spacer (replaces inline <br>) */
.spacer {
  display: block;
  height: 1em;
  flex-shrink: 0;
}
`;

// --- Block renderers ---

function renderBlock(block, slide) {
  switch (block.type) {
    case 'h1':    return `# ${block.text}\n`;
    case 'h2':    return `## ${block.text}\n`;
    case 'h3':    return `### ${block.text}\n`;
    case 'text':  return `${block.text}\n`;
    case 'list':  return block.items.map(i => `- ${i}`).join('\n') + '\n';
    case 'olist': return block.items.map((item, i) => `${i + 1}. ${item}`).join('\n') + '\n';
    case 'table': return renderTable(block);
    case 'code':  return '```' + (block.language || '') + '\n' + block.code + '\n```\n';
    case 'quote': return `> ${block.text}\n`;
    case 'image': {
      const pos = block.position || '';
      const isFullImage = slide && /\bfull-image\b/.test(slide.class || '');
      const isDirectional = /^(right|left)/i.test(pos);
      const isBgExplicit = /^(contain|cover)$/i.test(pos);

      if (isFullImage || isDirectional || isBgExplicit) {
        // Background image mode (full-image slide or split layout)
        const effectivePos = pos || 'contain';
        const needsContain = isDirectional && !/contain|cover/i.test(pos);
        const bgSpec = needsContain ? `contain ${effectivePos}` : effectivePos;
        return `![bg ${bgSpec}](${block.src})\n`;
      }
      // Inline image – participates in content flow
      return `<div class="block-image"><img src="${block.src}" /></div>\n`;
    }
    case 'br':    return '<div class="spacer"></div>\n'.repeat(block.count || 1);
    default:
      console.error(`Error: unknown block type "${block.type}"`);
      process.exit(1);
  }
}

function renderTable(block) {
  let md = '| ' + block.headers.join(' | ') + ' |\n';
  md += '| ' + block.headers.map(() => '---').join(' | ') + ' |\n';
  for (const row of block.rows) {
    md += '| ' + row.join(' | ') + ' |\n';
  }
  return md;
}

// --- Slide renderer ---

function renderSlide(slide) {
  const parts = [];

  if (slide.class) parts.push(`<!-- _class: ${slide.class} -->`);
  if (slide.paginate === false) parts.push('<!-- _paginate: false -->');
  if (parts.length > 0) parts.push('');

  for (const block of slide.blocks) {
    parts.push(renderBlock(block, slide));
  }

  return parts.join('\n');
}

// --- Marp renderer ---

function renderWithMarp(mdPath, outputPath) {
  const { execSync } = require('child_process');
  const ext = path.extname(outputPath).toLowerCase();

  const flags = ['--html', '--no-stdin', '--allow-local-files'];
  if (ext === '.pdf') flags.push('--pdf');
  if (ext === '.pptx') flags.push('--pptx');

  const cmd = `marp ${flags.join(' ')} "${mdPath}" -o "${outputPath}"`;
  try {
    execSync(cmd, { stdio: 'inherit' });
    console.log(`Rendered: ${outputPath}`);
  } catch (e) {
    console.error(`Error: marp CLI failed. Is it installed? (npm i -g @marp-team/marp-cli)`);
    process.exit(1);
  }
}

// --- Main build ---

function build(inputPath, outputPath) {
  const raw = fs.readFileSync(inputPath, 'utf-8');
  const input = JSON.parse(raw);

  const themeName = input.theme || 'kanso';
  const css = loadThemeCSS(themeName);
  const paginate = input.paginate !== false;

  const parts = [];

  // Frontmatter
  parts.push('---');
  parts.push('marp: true');
  parts.push('theme: default');
  if (paginate) parts.push('paginate: true');
  parts.push("footer: ' '");
  parts.push('---');
  parts.push('');

  // Style block
  parts.push('<style>');
  parts.push(BASE_CSS.trim());
  parts.push(css.trim());
  parts.push('</style>');
  parts.push('');

  // Slides
  input.slides.forEach((slide, i) => {
    if (i > 0) {
      parts.push('---');
      parts.push('');
    }
    parts.push(renderSlide(slide));
  });

  const md = parts.join('\n');

  if (!outputPath) {
    process.stdout.write(md);
    return;
  }

  const ext = path.extname(outputPath).toLowerCase();
  const dir = path.dirname(outputPath);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

  if (ext === '.md') {
    fs.writeFileSync(outputPath, md, 'utf-8');
    console.log(`Generated: ${outputPath}`);
  } else {
    const mdPath = outputPath.replace(ext, '.md');
    fs.writeFileSync(mdPath, md, 'utf-8');
    console.log(`Generated: ${mdPath}`);
    renderWithMarp(mdPath, outputPath);
  }
}

// --- CLI ---

const args = process.argv.slice(2);

if (args.includes('--help') || args.includes('-h') || args.length < 1) {
  console.log(`Usage: node build.js <input.json> <output>

  input.json   Slide data (see schema/slide-schema.json)
  output       Output path. Extension determines format:
                 .pdf  → PDF (default)
                 .html → HTML
                 .pptx → PowerPoint
                 .md   → Markdown only

Examples:
  node build.js input.json slides.pdf
  node build.js input.json slides.md`);
  process.exit(args.length < 1 ? 1 : 0);
}

build(args[0], args[1]);
