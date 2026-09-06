---
name: run-remove-bg
description: macOS Vision APIで背景除去。「背景除去」「透過PNG」で発動。
user-invocable: true
argument-hint: "<image path> [output path]"
---

# Remove Background

## WHY

ローカルで完結、無料、高速。外部APIへの画像送信不要。

## WHAT

macOS Vision API (`VNGenerateForegroundInstanceMaskRequest`) で被写体を検出し透過PNG生成。

## HOW

```bash
.claude/skills/run-remove-bg/scripts/removebg.swift input.png output.png
```
