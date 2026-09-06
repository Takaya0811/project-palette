# 構図設計 リファレンス

wrap-thumbnails の N パターン構図設計用の参考資料。SKILL.md から段階的開示で読む。

## テーマ別 mode 親和性（★ 分類）

mode の一次情報は `bash .claude/skills/run-thumbnail/scripts/generate.sh --list-modes`。下表は wrap 側の経験則で、テーマカテゴリごとに ★★★ (最優先) / ★★ (使える) / ★ (稀に使う) を分類したもの。

**4 枚選ぶ時は ★★★ から 2〜3 + ★★ から 1〜2** を目安に、毎回違う順列を作る。

### 解説系 / チュートリアル系
例: 「Claude Code 徹底解説」「MCP 使い方」「React入門」

- ★★★: `right-layout`, `center-hero`, `concept-map`, `product-flow`
- ★★: `sandwich`, `badge-comparison`, `face-closeup`
- 合わない: `vs-split`（ビフォーアフター専用）

### ○選 / まとめ / 比較系
例: 「プロンプト5選」「おすすめAI10選」

- ★★★: `sandwich`, `concept-map`, `product-flow`, `face-closeup`, `center-chaos`
- ★★: `right-layout`, `center-hero`, `badge-comparison`
- 合わない: `vs-split`

### ビフォーアフター / 成果 / 変化系
例: 「収入5倍」「生産性10倍」「未経験→エンジニア」

- ★★★: `vs-split`, `badge-comparison`, `center-hero`
- ★★: `right-layout`, `face-closeup`, `product-flow`, `center-chaos`
- 合わない: `concept-map`, `sandwich`

### ニュース / 速報 / 煽り系
例: 「〜が終了」「衝撃の新機能」

- ★★★: `face-closeup`, `center-chaos`, `center-hero`
- ★★: `right-layout`, `badge-comparison`, `product-flow`
- 合わない: `vs-split`, `concept-map`

汎用テーマは ★★★/★★ からバランス良く 4 つ、ただし **前回と同じ組み合わせは避ける**。

## Few-shot anchor を打ち破る

SKILL.md の例や過去会話の 4 mode 組み合わせに **無意識に引きずられる** のが最大リスク。能動的にやる:

1. **前回と違う順列を選ぶ**: 9 mode から 4 つ選ぶ組み合わせは `C(9, 4) = 126 通り`。毎回別の 4 を選ぶ余地は十分。
2. **star マッピングは優先順位ではなく制約**: 「★★★ から必ず全部」ではない。★★★ 2 + ★★ 2 や ★★★ 3 + ★★ 1 など混ぜる。
3. **同じテーマカテゴリでも rotation を変える**: 「解説系」の例として下記 4 つは全て有効で互換。実案件ではどれを引いても良い:
   - A案: `right-layout / center-hero / product-flow / concept-map`
   - B案: `right-layout / product-flow / face-closeup / sandwich`
   - C案: `center-hero / concept-map / product-flow / face-closeup`
   - D案: `right-layout / center-hero / badge-comparison / sandwich`
4. **選んだ 4 を自己点検**: 組み終わったら「これ前も見た組み合わせでは？」と振り返る。心当たりがあれば 1〜2 枚差し替える。

## さらに重ねる軸（テキスト系スロットの方向性）

mode を散らした上で、**各 mode の "煽りスロット" と "結論スロット" を互いに重ねない**。スロット名は mode ごとに異なるので、`generate.sh -m <mode> --help` で実際のパラメータを確認してから、以下の方向性で言葉を振り分ける:

1. **煽り / hook の角度**: 警告 / 命令 / 数値 / 驚き
2. **補足 / 権威付けの方向性**: 公式 / 時系列 / 属性 / 数値
3. **結論 / killer word**: 解説 / 結果 / 変化 / アクション

各軸で **同一値が 2 枚以上にならない** よう設計する。

## 具体例（スロット記述の参考 — anchor にしないこと）

下の 2 例はどちらも「Claude Code 徹底解説」に対する有効な組み立て。**実案件ではこの 2 例とも避けて、C案 / D案 や他の順列を組む** のが正しい運用（同じ組み合わせを繰り返すと anchor 化する）。

### A案: `right-layout / product-flow / concept-map / center-hero`

| # | mode | 必須パラメータ（実際の `--flag` で記述） |
|---|------|---|
| 01 | `right-layout` | `--line1 "知らないと損"` `--line2 "Claude Code"` `--line3 "Anthropic公式直伝"` `--line4 "徹底解説"` |
| 02 | `product-flow` | `--line1 "どれが最強？"` `--line2 "結論: Claude Code 一択"` |
| 03 | `concept-map` | `--top-text "Claude Code の全機能"` `--labeled-objects "CLI, MCP, hooks, skills, codex"` `--bottom-text "10倍生産性"` |
| 04 | `center-hero` | `--bottom-text "開発革命"` `--objects "Claude Code ロゴ, ターミナル, コードブロック"` `--chip-text "公式"` |

### B案: `product-flow / face-closeup / sandwich / badge-comparison`

| # | mode | 必須パラメータ |
|---|------|---|
| 01 | `product-flow` | `--hook-text "これ使わないと損する"` `--main-visual "ターミナル画面"` `--bottom-text "結論: 徹底解説"` |
| 02 | `face-closeup` | `--hook-text "マジか"` `--bottom-text "Claude Code 完全攻略"` |
| 03 | `sandwich` | `--top-text "2026年版"` `--bottom-text "開発革命"` `--objects "Claude Code ロゴ, エディタ, コード"` |
| 04 | `badge-comparison` | `--before-label "手動開発"` `--after-label "AI 全自動"` `--bottom-text "生産性10倍"` |

軸のチェック（どちらの案も共通で守る）:
- mode: 4 種全部違う ✓
- 煽り / 結論フレーズ: 4 枚で全部別表現 ✓

**各 mode の実スロットは必ず `generate.sh -m <mode> --help` で確認**。A案 B案のスロット名は目安で、実際は `--help` が正。勝手にスロット名を作らない。

## mode ごとの icon-image 対応

`run-thumbnail/config.json` の `accepts_icon` を一次情報として参照すること。下記は 2026-04-22 時点の snapshot:

- **対応**: `right-layout`, `face-closeup`, `vs-split`, `product-flow`, `badge-comparison`
- **非対応**: `sandwich`, `center-chaos`, `concept-map`, `center-hero`

非対応 mode にはロゴを渡せないが、プロンプトテンプレート内で「関連素材」として自動描画される余地があるので、ロゴ取得自体は無駄にならない。**4 パターンの 1〜3 枚だけでもロゴ付きで統一感を出す**（全枚数で対応している必要はない）。
