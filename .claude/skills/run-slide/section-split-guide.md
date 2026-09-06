# Section Split Design Guide (Phase 1-3B)

`run-slide` の Phase 1-3B 専用補助。**N > 20 枚** のとき、単一の slide-designer では関心の分離ができないため、セクション単位でサブエージェントに委譲する（孫エージェント構造）。

## 構造

```
run-slide (親)
  ├── Agent #1 (子) → Skill(assign-slide-generator) (孫) → s1-slide.json
  ├── Agent #2 (子) → Skill(assign-slide-generator) (孫) → s2-slide.json
  └── Agent #3 (子) → Skill(assign-slide-generator) (孫) → s3-slide.json
        ↓ (全完了後)
  merge-sections.js → 統合 slide.json + images.json
```

## Step 1: セクション分割計画

source.md の h2 構造を分析しチャンクに分割する:

- 各チャンクが **15〜20枚程度** になるよう h2 セクション群をグルーピング
- チャンク数の目安: `ceil(N / 18)`
- 各チャンクのスライド配分: コンテンツ量（文字数）に比例
- **第1チャンク** にタイトルスライドを含む（+1〜2枚）
- **最終チャンク** に結論・まとめスライドを含む（+2〜3枚）
- **第2チャンク以降** は先頭に full-image セクション仕切りスライドを入れる

## Step 2: セクション別ソースファイル生成

各チャンク `i` に対して `output/{name}-s{i}-source.md` を書き出す:

```markdown
<!-- Presentation Context -->
<!-- 全体タイトル: {title} -->
<!-- テーマ: {theme} -->
<!-- セクション {i}/{total} — {section_title} -->
<!-- このセクションの目標スライド数: {N_i} -->
<!-- 前セクション末尾の要約: {prev_ending} -->（i >= 2 のみ）
<!-- 次セクション冒頭の要約: {next_preview} -->（最終以外）
<!-- セクション2以降は先頭に full-image セクション仕切りスライドを含めること -->

{source.md の該当部分}
```

## Step 3: 並列 Agent 起動（孫エージェント構造）

各セクションに対して Agent(general-purpose, model:opus) を **並列** 起動する。Agent ツールの `prompt` 引数として渡す本文:

```
あなたはスライドセクション設計者です。
担当セクションのスライドJSONを設計してください。

1. output/{name}-s{i}-source.md を読む

2. bash で context JSON を書き出し、絶対パスを stdout に出力する:
   ```bash
   cat > output/{name}-s{i}-gen-ctx.json <<'JSON'
   {
     "project_dir": "output",
     "name": "{name}-s{i}",
     "source": "output/{name}-s{i}-source.md",
     "theme": "{theme}",
     "slides": {N_i},
     "iteration": 1,
     "output_contract": {
       "slide_json": "output/{name}-s{i}-slide.json",
       "images_json": "output/{name}-s{i}-images.json"
     }
   }
   JSON
   echo "CONTEXT:$(pwd)/output/{name}-s{i}-gen-ctx.json"
   ```

3. Skill ツールで assign-slide-generator を起動する（args は絶対パス必須:
   fork コンテキスト実行時に相対パスは cwd 不一致で解決失敗するため）:
   - skill: assign-slide-generator
   - args: 上記 bash 出力の `CONTEXT:` 行のパス（絶対パス）

4. 完了後、output/{name}-s{i}-slide.json と output/{name}-s{i}-images.json が
   生成されていることを確認する
```

## Step 4: セクション統合

全サブエージェント完了後:

```bash
node .claude/skills/run-slide/scripts/merge-sections.js output/{name} --sections {total}
```

統合後の確認:
- セクション境界のスライド接続が自然か
- slideIndex が連番か
- images.json の slideIndex がスライド配列と一致するか

問題があれば手動で微調整する。

**出力**: `output/{name}-slide.json` + `output/{name}-images.json`（統合済み）
