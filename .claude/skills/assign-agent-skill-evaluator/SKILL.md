---
name: assign-agent-skill-evaluator
description: 「スキルレビュー」「skill レビュー」で発動。 ref-agent-skill に照らしてスキル設計を採点する evaluator
user-invocable: true
argument-hint: "<context-json path | skill dir | SKILL.md path>"
context: fork
agent: general-purpose
model: opus
---

# assign-agent-skill-evaluator

対象スキルを `ref-agent-skill` ガイドライン (v3 taxonomy 準拠) に照らして採点し、構造化フィードバックを返す評価者。

**このスキルは対象スキルを直接修正しない。** ref-agent-skill / 評価基準の書き換えも禁止 (評価基準の保護原則、ref-agent-skill §8)。

## 契約 (単一)

- **Input**: `$ARGUMENTS` = context JSON ファイルのパス (evaluator 単一契約)。JSON キーは `project_dir` / `plan` / `criteria` / `threshold` / `turns_dir` / `iteration` / `output_contract` (`eval_file` / `schema` / `instructions`) を含む。
- **Output**: `output_contract.eval_file` に下記 eval JSON schema で Write する。

### context JSON 不在時のフォールバック

`$ARGUMENTS` が context JSON として解釈できない場合 (JSON でない / ファイル不在 / `output_contract` が空) は以下にフォールバックする:

- `$ARGUMENTS` が文字列 (SKILL.md ファイル or スキルディレクトリ) ならそれを対象として扱う
  - ディレクトリ → `SKILL.md` + 補助ファイルを Read
  - ファイル → Read
- `project_dir` はカレントディレクトリ、`plan` は none とみなす
- eval JSON の書き出し先は `{project_dir}/output/eval-<YYYYMMDD-HHMMSS>-assign-agent-skill-evaluator.json`
- 出力ディレクトリが存在しなければ作成する
- Markdown フィードバックは stdout に出力、末尾に同 schema の eval JSON を添付

## コンテキスト JSON のキー

| キー | 内容 |
|------|------|
| project_dir | 成果物が置かれたディレクトリ |
| `task` | ユーザー指定の task 原文。**評価軸の最終的な拠り所** (T-2.2)。plan より優先 |
| criteria | 追加品質基準 (任意) |
| threshold | 合格スコア (0-100) |
| plan | 成果物の所在と検査観点 |
| turns_dir | ターンログ保存先 |
| iteration | イテレーション番号 |
| output_contract | 出力先と JSON スキーマ |

## 手順

### 1. 読み込み

1. Skill ツールで `ref-agent-skill` を読み、v3 taxonomy 準拠の評価基準を把握する。特に以下を押さえる:
   - **4 軸分類** (§1): Axis A Purpose (`knowledge` / `produce` / `judge` / `pass-through`) / Axis B Trigger (`user` / `internal` / `both`) / Axis C Shape (`atomic` / `forked` / `orchestrated`) / Axis D Role (`generator` / `evaluator` / `contributor` / `delegate` / `null`)
   - **prefix 5 種と決定木** (§2): `ref-*` / `run-*` / `wrap-*` / `assign-*-{役}` / `delegate-*`。4 軸から prefix を導出する合成関数 `f(A, B, C, Role) → prefix` (例外分岐なし)
   - **frontmatter modifier**: `base:` (wrap-* 必須) / `pair:` (generator/evaluator ペア推奨) / `kind:` (ref-* のみ、`essence` / `meta`)
   - **共通ルール** (§3): Less is More / description トリガー性 / Gotchas の鮮度 / 段階的開示
   - **型固有ルール** (§4-§7): 辞書型 (ref-*) / ワークフロー型 (run/wrap/assign/delegate) / assign-*-evaluator の単一契約 / `!` による外部 LLM 呼び出しパターン
   - **評価基準の保護原則** (§8)
2. 対象を読む (context JSON 時: `project_dir` / `plan` から該当 SKILL.md + 補助ファイルを特定。フォールバック時: `$ARGUMENTS` から再解釈)

### 2. 評価 → フィードバック出力

v3 taxonomy に照らして 4 軸で評価し、以下のフォーマットで Markdown を生成する:

```markdown
# Skill Review: {skill-name}

> 評価基準: ref-agent-skill ガイドライン (v3 taxonomy)

## 軸判定

- **Axis A Purpose**: {knowledge / produce / judge / pass-through} (根拠: {description / 本文のどこから導出したか})
- **Axis B Trigger**: {user / internal / both} (根拠: {user-invocable 値 + フォールバック節の有無})
- **Axis C Shape**: {atomic / forked / orchestrated} (根拠: {context: fork の有無 / ループ / 並列 dispatch})
- **Axis D Role**: {generator / evaluator / contributor / delegate / null} (assign-* / delegate-* 以外は null)

## prefix 導出

- **期待値**: {4 軸から決定木で導出される prefix}
- **実名**: {skill 名}
- **整合性**: {OK / NG -- NG なら「X 軸値が Y なのに prefix が Z」のような形で指摘}

## Frontmatter

| フィールド | 現状 | 期待 | 判定 |
|-----------|------|------|------|
| user-invocable | ... | ... | ... |
| context | ... | ... | ... |
| agent | ... | ... | ... |
| model | ... | ... | ... |
| base (wrap-* のみ必須) | ... | ... | ... |
| pair (generator/evaluator 推奨) | ... | ... | ... |
| kind (ref-* のみ) | ... | ... | ... |
| 廃止フィールド (scope / layer) | ... | 存在しないこと | ... |

## 共通ルール準拠

| 観点 | 判定 | コメント |
|------|------|---------|
| description がトリガー条件 1 文 | {OK/NG} | 冗長な両対応併記や実装詳細がないか |
| Less is More | {OK/NG} | 当たり前の説明・不要ルールが残っていないか |
| input/output が観測可能 | {OK/NG/N/A} | 「完了しました」ではなくファイル/exit code/JSON で定義 |
| Gotchas の鮮度 | {OK/NG/N/A} | 修正済み項目・古い情報が残っていないか |
| 段階的開示 | {OK/NG/N/A} | 優先度低の情報が references/ に分離されているか |

## 型固有ルール準拠

{prefix 別に該当ルールを評価。例:}
- **ref-*** なら: `kind:` 設定の妥当性、知識辞書として成立しているか
- **run-*** / **wrap-*** なら: input/output 明確、`wrap-*` は `base:` が適切か
- **assign-*-generator** なら: evaluator との単一契約、create/fix 分岐を書いていないか、`{projroot}/output/` フォールバック
- **assign-*-evaluator** なら: eval JSON schema / context JSON 受領 / フォールバック節 / 評価基準の保護 / Read のみ
- **assign-*-contributor** なら: blackboard 契約準拠
- **delegate-*** なら: 契約なし・suffix なし・出力を未信頼入力扱い

## 総評

{1-2 文で要約}
```

### 3. eval JSON の書き出し

```json
{
  "score": <quality.overall と同値の 0-100>,
  "plan_implementation": {"overall": <0-100 補助指標、score 算出に使わない>, "notes": "<未実装メモ>"},
  "quality": {
    "overall": <0-100>,
    "breakdown": {
      "axis_consistency": <0-100>,
      "prefix_derivation_compliance": <0-100>,
      "frontmatter_compliance": <0-100>,
      "common_rules_compliance": <0-100>
    }
  },
  "feedback": "<3 軸構造化 (high → medium → low) を畳み込んだ string サマリ。Planner はこの string を読んで次イテに反映>",
  "feedback_structured": {
    "high":   [{"area": "<axis|prefix|frontmatter|common|type-specific>", "message": "<指摘 + 書き換え案>"}],
    "medium": [{"area": "...", "message": "..."}],
    "low":    [{"area": "...", "message": "..."}]
  },
  "passed": <score >= threshold (context JSON 時) or score >= 80 (フォールバック時)>,
  "evaluator_skill": "assign-agent-skill-evaluator"
}
```

## 採点観点の定義

| breakdown キー | 評価内容 |
|---------------|---------|
| `axis_consistency` | (A, B, C, Role) 4 軸が description / frontmatter / 本文から一意に判定できるか。矛盾があれば減点 (例: description が「外部 CLI に委譲」と言うのに fork も ループも無い) |
| `prefix_derivation_compliance` | 軸値から決定木 (§2) で導出される prefix が実名と一致するか。例: (pass-through, user, forked, delegate) → `delegate-*` / (judge, both, forked, evaluator) → `assign-*-evaluator` |
| `frontmatter_compliance` | v3 modifier (`base:` / `pair:` / `kind:` / `user-invocable:`) が prefix と整合。廃止済 `scope:` / `layer:` が残っていたら致命的 NG |
| `common_rules_compliance` | Less is More / description トリガー性 / input-output の観測可能性 / Gotchas 鮮度 / assign-*-evaluator なら eval JSON contract |

## ルール

- 対象スキルを変更しない (Read のみ)
- ref-agent-skill および本スキル自身の rubric を変更しない (評価基準の保護)
- context JSON 経由でもフォールバック時でも同一の eval JSON schema を出力する (schema を feedback.md 等に退化させない)
- 廃止概念 (α/β 分類、`scope:` / `layer:` frontmatter) が対象 skill に残っていたら high feedback で指摘する
- prefix allowlist は 5 種 (`ref-*` / `run-*` / `wrap-*` / `assign-*-{役}` / `delegate-*`)。これ以外 (`orch-*` / `review-*` 等の旧 prefix) は NG
