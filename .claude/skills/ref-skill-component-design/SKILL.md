---
name: ref-skill-component-design
description: Skill コンポーネント設計仕様。ref + evaluator ペア / ref + evaluator + generator 三組の構造を規定。
user-invocable: false
disable-model-invocation: true
kind: meta
---

# ref-skill-component-design: Skill コンポーネント設計仕様 (メタ辞書)

> 位置づけ: skill コンポーネントの構造規定 (メタ辞書)。`ref-agent-skill` の 4 軸 / 5 prefix taxonomy のうち「コンポーネント構造」部分に特化する。

---

## 1. 本 skill の役割

本 skill は Claude Code skill コンポーネント設計の **仕様辞書** (frontmatter `kind: meta`)。以下を規定する:

1. **コンポーネントの 2 形式**: ref + evaluator ペア (generator 不在) / ref + evaluator + generator 三組
2. **ペア契約**: `pair:` frontmatter による generator ↔ evaluator の相方関係
3. **evaluator rubric の保護原則**: ref / RUBRIC を evaluator/generator が書き換えない

skill 分類の全体像 (4 軸 + 5 prefix) は `ref-agent-skill` を正とし、本書はその中で「コンポーネント構造」部分のみ扱う。

---

## 2. コンポーネントの 2 形式

skill コンポーネントは **ref (知識) + それを消費する実行系 skill 群** の組として成立する。`pair:` frontmatter の有無で 2 形式に分かれる。

### 2.1 ペア形式 (ref + evaluator、generator 不在)

**構造**:

```
.claude/skills/
├── ref-<domain>/                           # kind: essence または kind: meta
│   └── SKILL.md                            # user-invocable: false / disable-model-invocation: true
└── assign-<domain>-evaluator/              # pair: ref-<domain>
    ├── SKILL.md                            # evaluator 単一契約 (eval JSON を返す)
    └── eval-schema.json                    # 機械可読 schema
```

**frontmatter 要点**:

- `ref-<domain>`: `kind: essence` (基底辞書) または `kind: meta` (メタ辞書)。`pair:` は不要 (ペア相手を持つのは evaluator 側)
- `assign-<domain>-evaluator`: `pair: ref-<domain>` で相方を宣言

**目的関数の性質**: 本質原則 (P-*) の集合。「判定命令」としては機能するが、「これに従うと唯一の正しい生成が導ける」手順ではない。したがって generator を自動生成しない。

**本プロジェクトの実例**: `ref-agent-skill` + `assign-agent-skill-evaluator`

### 2.2 三組形式 (ref + evaluator + generator)

**構造**:

```
.claude/skills/
├── ref-<domain>/                           # 原則 (軽量) + 技法カタログ
│   └── SKILL.md
├── assign-<domain>-evaluator/              # pair: assign-<domain>-generator
│   ├── SKILL.md
│   └── eval-schema.json
└── assign-<domain>-generator/              # pair: assign-<domain>-evaluator
    └── SKILL.md
```

**frontmatter 要点**:

- `assign-<domain>-evaluator` と `assign-<domain>-generator` が **互いを `pair:` で参照**する
- ref 側には `pair:` は不要 (ペア関係は evaluator ↔ generator の 2 点で閉じる)

**目的関数の性質**: 技法 T-* の再現的効果カタログ + それを支える軽量化原則。「適用手順」に落とせるため generator が成立する。

**本プロジェクトの実例**: `assign-slide-evaluator` ↔ `assign-slide-generator` (相互 `pair:` 宣言。`run-slide` がオーケストレーターとしてループを駆動する)

### 2.3 判定規則 (どちらの形式を選ぶか)

domain の知識構造で決まる:

| domain の知識構造 | 形式 |
|------------------|------|
| 原則 P-* のみ (技法カタログを持たない) | ペア形式 (ref + evaluator) |
| 原則 + 技法 T-* カタログ (適用手順に落とせる) | 三組形式 (ref + evaluator + generator) |

**禁止**: 重厚な原則と技法カタログを ref 側に同時記述する (P と T の混在はスキーマ違反)。

---

## 3. ペア契約 (`pair:` frontmatter)

`ref-agent-skill` taxonomy に準拠。`pair:` は skill コンポーネント間の依存関係を frontmatter で明示する仕組み。

### 3.1 `pair:` の使い方

| skill 種別 | `pair:` の値 | 意味 |
|-----------|------------|------|
| `assign-<domain>-evaluator` (ペア形式) | `ref-<domain>` | evaluator がこの ref を参照する |
| `assign-<domain>-evaluator` (三組形式) | `assign-<domain>-generator` | generator との相互依存 |
| `assign-<domain>-generator` (三組形式) | `assign-<domain>-evaluator` | evaluator との相互依存 |
| `ref-*` | 省略 | ref が主体ではなく参照先 |

### 3.2 契約内容 (三組形式の generator ↔ evaluator)

**generator 側の契約**:

- `plan` / `criteria` / `threshold` / `turns_dir` / `iteration` / `output_contract` を受け取る
- `project_dir` 内のファイルのみ書き換え (write_targets 準拠)
- `ref-<domain>` を Read で参照、書き換えない
- turn レポートを `turns_dir/turn-NNN-generator.md` に書く

**evaluator 側の契約**:

- 同じコンテキスト JSON を受け取る
- `output_contract.eval_file` に eval JSON を書く (`score` / `quality.breakdown` / `quality.dimension_thresholds` / `all_dimensions_passed` / `passed` が必須キー)
- 成果物 (`project_dir`) と `ref-<domain>` を Read、いずれも書き換えない
- `passed = all_dimensions_passed AND score >= threshold` の AND 条件で合否判定
- **`eval-schema.json` を skill ディレクトリに並置すること** (機械可読 schema)。`breakdown_keys` / `score_field` / `extras` が SKILL.md 本文と整合していること

### 3.3 ペア形式の契約 (ref + evaluator、generator 不在)

evaluator は §3.2 の evaluator 側契約をそのまま満たす。generator は対応ペアを持たないので、ループを回す場合は呼び出し元 (Claude 本体ないしオーケストレーター skill) が plan に従って編集する。

---

## 4. evaluator rubric の保護原則

### 4.1 権限分離 (3 層)

1. **ref (ref-\<domain\>)** = 定義 (Read 専用、どの skill からも書き換え不可)
2. **generator (assign-\<domain\>-generator)** = 実行 (成果物を書く、ref は読むだけ)
3. **evaluator (assign-\<domain\>-evaluator)** = 判定 (eval JSON を書く、成果物と ref は読むだけ)

evaluator と generator を同一 skill に兼ねない。

### 4.2 ref を書き換えない理由

評価器/生成器が ref を書き換えると、「評価をパスする最短経路として基準を緩める」ループが成立し、多次元評価が機能しなくなる。`ref-<domain>` の `user-invocable: false` / `disable-model-invocation: true` は、Claude (LLM) の自動書き換え経路を閉じる構造的防御。

### 4.3 ref 更新は人間承認経由

ref の更新が必要になったら:

1. `assign-agent-skill-evaluator` で ref のレビュー
2. seed から再設計 (dry_run で diff 確認)
3. 人間が diff をレビューして merge

evaluator / generator が eval 結果を根拠に ref を書き換える経路は禁止。

### 4.4 多次元足切り

- 各次元 D1..Dn (ペア形式) または D-tech / D-principle / D-outcome (三組形式) に **足切り閾値** を設ける
- evaluator は AND 判定: `passed = (全次元が閾値以上) AND (総合 score >= threshold)`
- 単一総合スコアでの合格は構造的にできない

---

## 5. ディレクトリ構造

### 5.1 ペア形式 (§2.1)

```
.claude/skills/
├── ref-<domain>/
│   ├── SKILL.md                 # kind: essence / meta, user-invocable: false
│   └── [補助.md]                 # 任意 (原則本文、具体例集)
└── assign-<domain>-evaluator/
    ├── SKILL.md                 # pair: ref-<domain>
    └── eval-schema.json         # 機械可読 schema
```

### 5.2 三組形式 (§2.2)

```
.claude/skills/
├── ref-<domain>/
│   └── SKILL.md
├── assign-<domain>-evaluator/
│   ├── SKILL.md                 # pair: assign-<domain>-generator
│   └── eval-schema.json         # 機械可読 schema
└── assign-<domain>-generator/
    └── SKILL.md                 # pair: assign-<domain>-evaluator
```

### 5.3 命名規約 (`ref-agent-skill` 準拠)

- `ref-*` — 知識辞書 (A=knowledge)
- `run-*` — user 向け基底ワークフロー (A=produce, B=user)
- `wrap-*` — 既存 run-* の薄いラッパ (base: あり)
- `assign-*-{役}` — 役バインド内部 skill (generator / evaluator / contributor)

---

## 6. 新規コンポーネント設計チェックリスト

新しいコンポーネント (ペア or 三組) を設計するときの自己チェック:

- [ ] 対象 domain の知識構造が ペア (原則のみ) / 三組 (原則 + 技法カタログ) のどちらか一方に決まっているか (混在していないか)
- [ ] `ref-<domain>/SKILL.md` の frontmatter に `user-invocable: false` / `disable-model-invocation: true` / `kind: essence`(or `meta`) を付けたか
- [ ] ref / RUBRIC に次元別足切り閾値を書いたか
- [ ] evaluator SKILL.md に `pair:` を正しく書いたか (ペア形式なら `ref-<domain>`、三組形式なら generator skill 名)
- [ ] 三組形式なら generator SKILL.md にも対称な `pair:` を書いたか
- [ ] evaluator / generator を別ディレクトリに分けたか (同一 skill に兼ねていないか)
- [ ] `ref-*` / `assign-*-evaluator` / `assign-*-generator` 以外から ref を書き換える経路がないか
- [ ] eval JSON の必須キー (`score` / `quality.breakdown` / `quality.dimension_thresholds` / `all_dimensions_passed` / `passed`) を evaluator テンプレが満たすか
- [ ] `assign-*-evaluator` ディレクトリに `eval-schema.json` を並置したか (`breakdown_keys` / `score_field` / `extras` を SKILL.md と整合させる)
