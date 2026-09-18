# ddskk-jev

[ddskk](https://github.com/skk-dev/ddskk) の変換候補を、[TypeSafe AI の Jev](https://docs.typesafe.ai/) で文脈に応じて並べ替える Emacs のグローバルマイナーモードです。Jev は [Vercel AI Gateway](https://vercel.com/ai-gateway/models/jev) 経由（既定）と、[TypeSafe の API](https://docs.typesafe.ai/api) を直接呼ぶ経路のどちらでも利用できます。

Jev はテキストを生成しない評価モデルで、「状態 (state)」と「型付きの質問 (questions)」を受け取り、選択肢ごとの確率を返します。ddskk-jev は、変換位置の前後のテキストと読みを state として渡し、各変換候補を choice 質問の選択肢として問い合わせ、返ってきた確率の降順に候補を並べ替えます。

## 動作の概要

1. ▽モードで読みを入力し、SPC で変換を開始します。
2. ddskk が辞書から候補リスト (`skk-henkan-list`) を得た直後（`skk-henkan-list-filter` の後）に、ddskk-jev が介入します。
   ddskk の `skk-search` は候補を返した最初の辞書（通常は個人辞書）で検索を止めるため、既定（`ddskk-jev-search-all-progs` が t）では、ここで残りの辞書（大辞書・辞書サーバなど）もすべて検索し、全候補をまとめてから次へ進みます。
3. 変換位置の前後のテキスト（既定で前 120 文字、後 40 文字）、読み、送り仮名を state とし、先頭から最大 12 件の候補を Choice 質問の選択肢として Jev に問い合わせます。候補の注釈（`;` 以降）は選択肢の説明として渡します。既定では「どの候補も合わない」選択肢（`none_of_the_above`）も加えます。
4. 返ってきた確率の降順に候補を並べ替えます。確率が同じ候補や問い合わせ対象外の候補は、元の順序を保ちます。
5. 次の場合は並べ替えを適用せず、辞書の順序をそのまま使います。
   - モデルが「どの候補も合わない」を最上位に選んだとき
   - `ddskk-jev-min-confidence` を設定していて、応答の confidence がそれに満たないとき

並べ替えは変換の 1 発目（`skk-henkan-count` が 0 のとき）にだけ行います。候補一覧を表示している途中で順序が変わることはありません。

## 必要なもの

- Emacs 28.1 以上
- ddskk 17.1 以上
- Vercel AI Gateway の API キー、または TypeSafe AI の API キー（どちらか一方）

## インストールと設定

```elisp
(require 'ddskk-jev)
(ddskk-jev-mode 1)

;; TypeSafe の API を直接呼ぶ場合
(setq ddskk-jev-backend 'typesafe)
```

### バックエンド

`ddskk-jev-backend` で呼び出し経路を選びます。エンドポイント、モデル ID、API キーの探索先の既定値はバックエンドごとに決まります。`ddskk-jev-endpoint` と `ddskk-jev-model` を明示すると既定値より優先されます。

| | `vercel`（既定） | `typesafe` |
| --- | --- | --- |
| 送信先 | `https://ai-gateway.vercel.sh/v4/ai/evaluation-model` | `https://api.typesafe.ai/v1/systemone` |
| モデル ID | `typesafe-ai/jev` | `jev-latest` |
| API キーの環境変数 | `AI_GATEWAY_API_KEY` | `TYPESAFE_API_KEY` |
| auth-source の host | `ai-gateway.vercel.sh` | `api.typesafe.ai` |
| キーの発行元 | Vercel ダッシュボードの AI Gateway | [console.typesafe.ai](https://console.typesafe.ai/) |
| 課金 | Vercel のクレジット | TypeSafe のアカウント |
| 応答の `confidence` | 含まれない可能性がある（最大確率で代用） | 含まれる |

### API キー

API キーは次の順に探します。

1. 変数 `ddskk-jev-api-key`
2. バックエンドに応じた環境変数（`AI_GATEWAY_API_KEY` または `TYPESAFE_API_KEY`）
3. auth-source（`~/.authinfo.gpg` などに `machine ai-gateway.vercel.sh login ddskk-jev password <API キー>` または `machine api.typesafe.ai login ddskk-jev password <API キー>` と書きます）

`ddskk-jev-api-key` には次のいずれかを設定できます。

```elisp
;; 文字列（現在のバックエンドにそのまま使う）
(setq ddskk-jev-api-key "vck_...")

;; バックエンドごとに分ける alist。値は文字列か関数
(setq ddskk-jev-api-key
      '((vercel . "vck_...")
        (typesafe . "ts_...")))

;; 関数（呼び出した結果を使う）
(setq ddskk-jev-api-key (lambda () (my-read-secret "jev")))
```

alist に現在のバックエンドの要素が無いときや、値が空文字列のときは、環境変数と auth-source を探します。文字列を設定ファイルに直接書くと平文で残るため、設定ファイルを共有・公開する場合は auth-source か関数の利用を検討してください。

接続確認には `M-x ddskk-jev-test-connection` を使います。固定の例文で問い合わせて、候補ごとの確率をメッセージに表示します。

現在の状態は `M-x ddskk-jev-status` で確認できます。有効・停止の別、連続失敗回数、直近のエラー、直近の応答時間、API キーが見つかっているかを表示します。「変換しているのに Jev が呼ばれない」と感じたときは、まずこのコマンドで停止していないかを確認してください。

## 主な設定項目

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `ddskk-jev-backend` | `vercel` | 呼び出し経路。`vercel` または `typesafe` |
| `ddskk-jev-endpoint` | nil | 送信先 URL。nil ならバックエンドの既定値 |
| `ddskk-jev-model` | nil | モデル ID。nil ならバックエンドの既定値 |
| `ddskk-jev-context-before-chars` | 120 | 変換位置より前から送る最大文字数 |
| `ddskk-jev-context-after-chars` | 40 | 変換位置より後から送る最大文字数 |
| `ddskk-jev-max-candidates` | 12 | 問い合わせる候補数の上限 |
| `ddskk-jev-min-candidates` | 2 | この数未満なら問い合わせない |
| `ddskk-jev-search-all-progs` | t | 1 発目で残りの辞書もすべて検索してから Jev に渡す |
| `ddskk-jev-timeout` | 2.0 | HTTP のタイムアウト秒数。タイムアウトも失敗として数える |
| `ddskk-jev-max-consecutive-failures` | 3 | 連続失敗でこの回数に達すると自動停止する |
| `ddskk-jev-zero-data-retention` | nil | AI Gateway に zeroDataRetention を要求する（`vercel` のみ） |
| `ddskk-jev-none-option` | t | 「どの候補も合わない」選択肢を加える |
| `ddskk-jev-min-confidence` | nil | 並べ替えを適用する confidence の下限。nil なら常に適用する |
| `ddskk-jev-instructions` | （英語の構造化された指示） | Choice 質問に添える指示。文字列か、JSON オブジェクトになる alist |
| `ddskk-jev-debug` | nil | リクエストと応答を `*ddskk-jev*` バッファに記録する |

## 設計の根拠

質問の設計は [TypeSafe のドキュメント](https://docs.typesafe.ai/llms.txt)と [TypeSafe agent skill](https://github.com/typesafe-ai/skills/blob/main/skills/typesafe-ai/SKILL.md) の指針に沿っています。

- Choice の選択肢名と説明は両方モデルに送られるため、選択肢名を候補語そのものにし、辞書の注釈があれば説明として渡しています。
- 選択肢がすべての入力を網羅しないときは none-of-the-above を加えることが推奨されているため、`none_of_the_above` を加え、それが選ばれたときは辞書順を保ちます。
- 低い確信度では行動しないことが推奨されているため、`ddskk-jev-min-confidence` で並べ替えの適用を制御できます。AI Gateway 経由の応答に confidence が含まれない場合は最大確率で代用します。適切な閾値は自分の入力で試して決める必要があります。
- Jev の主要な学習言語は英語で、CJK テキストは精度が下がると[明記されています](https://docs.typesafe.ai/models#language-support)。既定の指示文は英語にしてありますが、日本語の文脈に対する精度は保証されません。実際の変換で確認しながら使ってください。

## 留意点

- **Jev は日本語向けに最適化されていません。** 上記のとおり CJK テキストの精度は英語より低いと明記されています。並べ替えが改悪になるケースがあれば `ddskk-jev-min-confidence` を上げるか、モードを無効にしてください。
- **バッファの内容が外部に送信されます。** 変換位置の前後のテキストが Vercel と TypeSafe AI に送られます。機密情報を扱うバッファでは `ddskk-jev-mode` を無効にするか、送信文字数を減らしてください。
- **変換の 1 発目に HTTP 往復の待ち時間が加わります。** リクエストは同期的に行い、`ddskk-jev-timeout` 秒を超えると並べ替えを諦めて元の順序を使います。
- **失敗が続くと自動停止します。** `ddskk-jev-max-consecutive-failures` 回連続で失敗すると問い合わせを止め、メッセージを表示します。タイムアウトも失敗に数えます。停止しているかは `M-x ddskk-jev-status` で確認でき、`M-x ddskk-jev-reset` で再開できます。
- **1 発目の候補一覧が ddskk 単体のときと変わります。** `ddskk-jev-search-all-progs` が t のとき、ddskk が 2 発目以降に順次表示していた大辞書などの候補が 1 発目から一覧に含まれます。`skk-kakutei-when-unique-candidate` を使っている場合、候補が 1 件だけになる場面が減ります。以前の挙動に戻すには nil にしてください。ただし nil のときは、個人辞書に候補が 1 件しかない読みでは Jev を呼びません。
- **課金が発生します。** Jev の価格は AI Gateway または TypeSafe のモデルページを参照してください。変換の 1 発目ごとに 1 回問い合わせます。
- **skk-study など、他の候補順序調整機構と併用すると、後から動いたものの順序が優先されます。**

## HTTP プロトコルについて

### Vercel AI Gateway

AI Gateway の評価モダリティは公式には AI SDK 経由のみの提供とされています。ddskk-jev は `@ai-sdk/gateway` の実装を参照し、同じ HTTP リクエストを Emacs から直接送っています。

- `POST https://ai-gateway.vercel.sh/v4/ai/evaluation-model`
- ヘッダー: `Authorization: Bearer <API キー>`、`ai-gateway-protocol-version: 0.0.1`、`ai-gateway-auth-method: api-key`、`ai-evaluation-model-specification-version: 4`、`ai-model-id: typesafe-ai/jev`
- ボディ: `{"state": ..., "questions": {"candidate": {"type": "choice", "instructions": ..., "criteria": {"候補": null, ...}}}}`
- 応答: `{"answers": {"candidate": {"type": "choice", "choice": "...", "probabilities": {"候補": 0.9, ...}}}, "usage": ...}`

AI SDK 側の変更でこのプロトコルが変わる可能性があります。

### TypeSafe AI 直接

[公開されている API リファレンス](https://docs.typesafe.ai/api)に従います。

- `POST https://api.typesafe.ai/v1/systemone`
- ヘッダー: `Authorization: Bearer <API キー>`、`Content-Type: application/json`
- ボディ: Gateway の形に `"model": "jev-latest"` を加えたもの
- 応答: Gateway と同じ形で、`confidence` と `usage.input_tokens` などが含まれます

エラーは 401/403（認証）、422（検証失敗）、429（レート制限）、529（過負荷）で返ります。ddskk-jev はいずれも失敗として数え、連続失敗の上限で自動停止します。

## 開発

```sh
make compile   # byte-compile（警告をエラーとして扱う）
make test      # ERT テスト（HTTP 層はスタブ）
```

## ライセンス

GPL-3.0-or-later
