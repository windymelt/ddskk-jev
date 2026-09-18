;;; ddskk-jev.el --- Reorder ddskk candidates with TypeSafe AI Jev via Vercel AI Gateway -*- lexical-binding: t; -*-

;; Copyright (C) 2026 windymelt

;; Author: windymelt
;; URL: https://github.com/windymelt/ddskk-jev
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (ddskk "17.1"))
;; Keywords: japanese, input method

;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied
;; warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
;; PURPOSE.  See the GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; ddskk-jev は、ddskk の変換候補リスト (`skk-henkan-list') を、
;; TypeSafe AI の評価モデル Jev (Vercel AI Gateway 経由) で
;; 文脈に応じて並べ替えるマイナーモードです。
;;
;; Jev はテキストを生成しないモデルで、「状態 (state)」と
;; 「型付きの質問 (questions)」を受け取り、選択肢ごとの確率を返します。
;; 本パッケージは、変換位置の前後のテキストと読みを state として渡し、
;; 各候補を choice 質問の選択肢として問い合わせ、返ってきた確率の
;; 降順に候補を並べ替えます。
;;
;; 使い方:
;;
;;   (require 'ddskk-jev)
;;   ;; 既定は Vercel AI Gateway 経由です。API キーは環境変数
;;   ;; AI_GATEWAY_API_KEY か auth-source (machine ai-gateway.vercel.sh)
;;   ;; から読み込みます。
;;   (ddskk-jev-mode 1)
;;
;;   ;; TypeSafe の API を直接呼ぶ場合。API キーは環境変数
;;   ;; TYPESAFE_API_KEY か auth-source (machine api.typesafe.ai) から
;;   ;; 読み込みます。
;;   (setq ddskk-jev-backend 'typesafe)
;;
;; 並べ替えは変換の 1 発目 (▽→SPC→▼) のときだけ行います。
;; 候補一覧を表示中に順序を変えないためです。
;;
;; 注意:
;;  - 変換位置の前後のテキストが外部サービス (Vercel / TypeSafe AI) に
;;    送信されます。送信する文字数は `ddskk-jev-context-before-chars' と
;;    `ddskk-jev-context-after-chars' で制御できます。
;;  - HTTP リクエストは同期的に行い、`ddskk-jev-timeout' 秒で諦めます。
;;    失敗が `ddskk-jev-max-consecutive-failures' 回続くと自動的に
;;    停止します。`ddskk-jev-reset' で再開できます。

;;; Code:

(require 'cl-lib)
(require 'url)
(require 'url-http)
(require 'auth-source)
(require 'subr-x)

;; ddskk が提供する変数・関数。コンパイル時の警告を抑えるために宣言する。
(defvar skk-henkan-list)
(defvar skk-henkan-key)
(defvar skk-henkan-count)
(defvar skk-henkan-okurigana)
(defvar skk-henkan-start-point)
(defvar skk-henkan-end-point)
(defvar skk-abbrev-mode)
(defvar skk-current-search-prog-list)
(declare-function skk-henkan-list-filter "skk")
(declare-function skk-search "skk")
(declare-function skk-nunion "skk-macs")

(defgroup ddskk-jev nil
  "Reorder ddskk candidates with TypeSafe AI Jev via Vercel AI Gateway."
  :group 'skk
  :prefix "ddskk-jev-")

(defcustom ddskk-jev-backend 'vercel
  "Jev を呼び出す経路。
`vercel' は Vercel AI Gateway の evaluation エンドポイントを、
`typesafe' は TypeSafe AI の API (POST /v1/systemone) を直接使います。
エンドポイント・モデル ID・API キーの探索先の既定値は、
この値に応じて `ddskk-jev--backends' から決まります。"
  :type '(choice (const :tag "Vercel AI Gateway" vercel)
                 (const :tag "TypeSafe AI 直接" typesafe)))

(defconst ddskk-jev--backends
  '((vercel
     :endpoint "https://ai-gateway.vercel.sh/v4/ai/evaluation-model"
     :model "typesafe-ai/jev"
     :env "AI_GATEWAY_API_KEY"
     :auth-source-host "ai-gateway.vercel.sh")
    (typesafe
     :endpoint "https://api.typesafe.ai/v1/systemone"
     :model "jev-latest"
     :env "TYPESAFE_API_KEY"
     :auth-source-host "api.typesafe.ai"))
  "バックエンドごとの既定値。")

(defun ddskk-jev--backend-default (key)
  "現在の `ddskk-jev-backend' の既定値のうち KEY のものを返す。"
  (let ((plist (alist-get ddskk-jev-backend ddskk-jev--backends)))
    (unless plist
      (signal 'ddskk-jev-error
              (list (format "未知のバックエンド: %s" ddskk-jev-backend))))
    (plist-get plist key)))

(defcustom ddskk-jev-api-key nil
  "API キー。次のいずれかを指定します。

- 文字列: そのままキーとして使います (バックエンドを問わず)。
- 引数なしの関数: 呼び出した結果をキーとして使います。
- alist: バックエンド名をキーにした alist で、値は文字列か関数です。
  例: \='((vercel . \"vck_...\") (typesafe . \"ts_...\"))
  現在の `ddskk-jev-backend' に対応する要素を使います。
- nil: バックエンドに応じた環境変数 (Vercel なら AI_GATEWAY_API_KEY、
  TypeSafe なら TYPESAFE_API_KEY)、次に auth-source
  \(host が `ddskk-jev-auth-source-host' のエントリ) の順に探します。

alist で現在のバックエンドの要素が無いとき、または文字列が空のときも
環境変数と auth-source を探します。
文字列をそのまま設定ファイルに書くと平文で残ります。設定ファイルを
共有・公開する場合は auth-source か関数の利用を検討してください。"
  :type '(choice (const :tag "環境変数または auth-source から取得" nil)
                 (string :tag "API キー")
                 (function :tag "API キーを返す関数")
                 (alist :tag "バックエンドごとの API キー"
                        :key-type (choice (const vercel) (const typesafe))
                        :value-type (choice string function))))

(defcustom ddskk-jev-auth-source-host nil
  "auth-source から API キーを探すときの host 名。
nil ならバックエンドの既定値 (ai-gateway.vercel.sh または api.typesafe.ai) を使います。"
  :type '(choice (const :tag "バックエンドの既定値" nil) string))

(defcustom ddskk-jev-endpoint nil
  "リクエストを送る URL。
nil ならバックエンドの既定値を使います。"
  :type '(choice (const :tag "バックエンドの既定値" nil) string))

(defcustom ddskk-jev-model nil
  "利用するモデルの ID。
nil ならバックエンドの既定値 (Vercel なら typesafe-ai/jev、
TypeSafe なら jev-latest) を使います。"
  :type '(choice (const :tag "バックエンドの既定値" nil) string))

(defun ddskk-jev--endpoint ()
  "実際に使うエンドポイント URL を返す。"
  (or ddskk-jev-endpoint (ddskk-jev--backend-default :endpoint)))

(defun ddskk-jev--model ()
  "実際に使うモデル ID を返す。"
  (or ddskk-jev-model (ddskk-jev--backend-default :model)))

(defcustom ddskk-jev-context-before-chars 120
  "変換位置より前から state に含める最大文字数。"
  :type 'natnum)

(defcustom ddskk-jev-context-after-chars 40
  "変換位置より後から state に含める最大文字数。"
  :type 'natnum)

(defcustom ddskk-jev-max-candidates 12
  "Jev に問い合わせる候補数の上限。
これを超える候補は元の順序のまま後ろに置きます。"
  :type 'natnum)

(defcustom ddskk-jev-min-candidates 2
  "この数未満の候補しかないときは問い合わせを行いません。"
  :type 'natnum)

(defcustom ddskk-jev-timeout 2.0
  "HTTP リクエストのタイムアウト秒数。
超過した場合は並べ替えを諦めて元の順序を使います。
タイムアウトも失敗として数えるため、小さすぎると
`ddskk-jev-max-consecutive-failures' に達して自動停止しやすくなります。"
  :type 'number)

(defcustom ddskk-jev-search-all-progs t
  "Non-nil なら、1 発目の変換で残りの辞書もすべて検索してから Jev に渡します。
ddskk の `skk-search' は候補を返した最初の辞書で検索を止めるため、
既定では 1 発目の候補は個人辞書の内容だけになります。この設定を有効に
すると `skk-current-search-prog-list' に残っている検索プログラムをすべて
評価し、大辞書や辞書サーバの候補も含めた一覧を Jev で並べ替えます。
副作用として、ddskk が 2 発目以降に順次表示していた候補が 1 発目から
候補一覧に含まれます。`skk-kakutei-when-unique-candidate' を使っている
場合、候補が 1 件だけになる場面が減ります。"
  :type 'boolean)

(defcustom ddskk-jev-max-consecutive-failures 3
  "連続でこの回数失敗すると自動的に停止します。
nil なら停止しません。`ddskk-jev-reset' で再開できます。"
  :type '(choice (const :tag "停止しない" nil) natnum))

(defcustom ddskk-jev-zero-data-retention nil
  "Non-nil なら AI Gateway に zeroDataRetention を要求します。
Vercel バックエンドでのみ意味を持ちます。TypeSafe 直接の場合は
契約側の設定になるため、リクエストには含めません。"
  :type 'boolean)

(defcustom ddskk-jev-instructions
  '((question . "Which candidate is the correct kanji conversion for the kana `reading` at the position between `context_before` and `context_after`?")
    (focus . "Choose the word that is grammatically and semantically most natural in this Japanese sentence. Consider the words immediately before and after the conversion point.")
    (notes . ["The text is Japanese. `reading` is written in kana."
              "When `okurigana` is non-empty, the chosen candidate is immediately followed by that okurigana in the sentence."
              "Each option is a candidate word; its description, when present, is a dictionary annotation."]))
  "choice 質問に添える指示文。
文字列、または JSON オブジェクトになる alist を指定します。
TypeSafe の推奨に従い、既定では英語の構造化された指示を使います。
Jev の主要な学習言語は英語で、CJK テキストは精度が下がると
ドキュメントに明記されているため、日本語の文脈に対しても指示は
英語のままにしています。"
  :type '(choice string sexp))

(defcustom ddskk-jev-none-option t
  "Non-nil なら「どの候補も合わない」選択肢を加えます。
TypeSafe のドキュメントは、選択肢がすべての入力を網羅しないときに
none-of-the-above の選択肢を加えることを推奨しています。
この選択肢が最も高い確率になったときは、辞書の順序をそのまま使います。"
  :type 'boolean)

(defconst ddskk-jev--none-key "none_of_the_above"
  "「どの候補も合わない」選択肢のキー。")

(defconst ddskk-jev--none-description
  "None of the candidate words fits this context; the correct word is not among the options."
  "「どの候補も合わない」選択肢の説明。")

(defcustom ddskk-jev-min-confidence nil
  "並べ替えを適用する confidence の下限。nil なら常に適用します。
応答に confidence が含まれていればそれを、なければ最大確率を使います。
TypeSafe のドキュメントは、低い確信度では行動しないことを推奨しています。
適切な値は自分の入力で試して決める必要があります。"
  :type '(choice (const :tag "常に適用" nil) number))

(defcustom ddskk-jev-debug nil
  "Non-nil ならリクエストと応答を `ddskk-jev-log-buffer' に記録します。"
  :type 'boolean)

(defcustom ddskk-jev-log-buffer "*ddskk-jev*"
  "デバッグ用ログを書き出すバッファ名。"
  :type 'string)

(defvar ddskk-jev--consecutive-failures 0
  "直近の連続失敗回数。")

(defvar ddskk-jev--suspended nil
  "Non-nil なら失敗が続いたために問い合わせを停止しています。")

(defvar ddskk-jev-last-response nil
  "最後に受け取った応答 (パース済み)。デバッグ用。")

(defvar ddskk-jev--last-error nil
  "最後に起きた失敗のメッセージ。")

(defvar ddskk-jev--last-latency nil
  "最後の問い合わせにかかった秒数。")

(defvar ddskk-jev--last-request-time nil
  "最後に問い合わせた時刻。")

(defvar ddskk-jev--in-reorder nil
  "並べ替え処理の再入を防ぐフラグ。
残りの辞書を検索した後に `skk-henkan-list-filter' を呼び直すが、
その advice から再び並べ替えに入らないようにする。")

(defvar ddskk-jev-mode)

(define-error 'ddskk-jev-error "ddskk-jev error")

;;;; ログ

(defun ddskk-jev--log (format-string &rest args)
  "`ddskk-jev-debug' が non-nil のときログバッファに記録する。"
  (when ddskk-jev-debug
    (with-current-buffer (get-buffer-create ddskk-jev-log-buffer)
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S] ")
              (apply #'format format-string args)
              "\n"))))

;;;; API キー

(defun ddskk-jev--configured-api-key ()
  "`ddskk-jev-api-key' の設定から現在のバックエンドのキーを返す。
設定が無い、または空文字列のときは nil。"
  (let* ((spec ddskk-jev-api-key)
         (value (cond ((stringp spec) spec)
                      ((functionp spec) (funcall spec))
                      ((and (consp spec) (consp (car spec)))
                       (let ((entry (alist-get ddskk-jev-backend spec)))
                         (if (functionp entry) (funcall entry) entry))))))
    (and (stringp value) (not (string-empty-p value)) value)))

(defun ddskk-jev--api-key ()
  "API キーを返す。見つからなければ nil。
`ddskk-jev-api-key'、環境変数、auth-source の順に探す。"
  (or (ddskk-jev--configured-api-key)
      (let ((env (getenv (ddskk-jev--backend-default :env))))
        (and env (not (string-empty-p env)) env))
      (let* ((host (or ddskk-jev-auth-source-host
                       (ddskk-jev--backend-default :auth-source-host)))
             (found (car (auth-source-search :host host
                                             :max 1
                                             :require '(:secret))))
             (secret (plist-get found :secret)))
        (cond ((functionp secret) (funcall secret))
              ((stringp secret) secret)))))

;;;; 候補の扱い

(defun ddskk-jev--split-note (word)
  "WORD を (候補 . 注釈) に分ける。注釈がなければ cdr は nil。"
  (if (string-match ";" word)
      (cons (substring word 0 (match-beginning 0))
            (substring word (match-end 0)))
    (cons word nil)))

(defun ddskk-jev--candidate-word (candidate)
  "`skk-henkan-list' の要素 CANDIDATE から候補文字列を取り出す。
数値変換時の要素は (元の候補 . 変換後) の cons になっている。"
  (if (consp candidate) (cdr candidate) candidate))

(defconst ddskk-jev--henkan-markers '(?▽ ?▼)
  "ddskk が変換位置の直前に置くマーカー文字。前文脈から除外する。")

(defun ddskk-jev--context ()
  "現在のバッファから (前文脈 . 後文脈) を返す。
変換位置の直前にある ddskk のマーカー (▽ ▼) と、変換位置の直後に
残っている送り仮名は文脈に含めない。
変換位置の情報が得られないときは (\"\" . \"\") を返す。"
  (let ((start (and (markerp skk-henkan-start-point)
                    (marker-position skk-henkan-start-point)))
        (end (and (markerp skk-henkan-end-point)
                  (marker-position skk-henkan-end-point)))
        (okurigana (and (boundp 'skk-henkan-okurigana)
                        (stringp skk-henkan-okurigana)
                        skk-henkan-okurigana)))
    (if (not (and start end (<= (point-min) start) (<= start end) (<= end (point-max))))
        (cons "" "")
      (when (and (> start (point-min))
                 (memq (char-before start) ddskk-jev--henkan-markers))
        (setq start (1- start)))
      (when (and okurigana
                 (not (string-empty-p okurigana))
                 (<= (+ end (length okurigana)) (point-max))
                 (string= okurigana
                          (buffer-substring-no-properties
                           end (+ end (length okurigana)))))
        (setq end (+ end (length okurigana))))
      (cons (buffer-substring-no-properties
             (max (point-min) (- start ddskk-jev-context-before-chars))
             start)
            (buffer-substring-no-properties
             end
             (min (point-max) (+ end ddskk-jev-context-after-chars)))))))

(defun ddskk-jev--build-state (context reading okurigana)
  "state として送る alist を作る。
CONTEXT は (前文脈 . 後文脈)、READING は読み、OKURIGANA は送り仮名。"
  `((context_before . ,(car context))
    (reading . ,reading)
    (okurigana . ,(or okurigana ""))
    (context_after . ,(cdr context))))

(defun ddskk-jev--build-request (state candidates)
  "STATE と CANDIDATES から送信する JSON 文字列 (UTF-8 の unibyte) を作る。
CANDIDATES は注釈付きの候補文字列のリスト。criteria のキーは候補本体、
値は注釈 (なければ null) とする。
ボディの形は `ddskk-jev-backend' によって一部異なる。"
  (let ((criteria (append
                   (mapcar (lambda (word)
                             (let ((pair (ddskk-jev--split-note word)))
                               (cons (intern (car pair))
                                     (or (cdr pair) :null))))
                           candidates)
                   (when ddskk-jev-none-option
                     (list (cons (intern ddskk-jev--none-key)
                                 ddskk-jev--none-description))))))
    (encode-coding-string
     (json-serialize
      `((state . ,state)
        ;; TypeSafe の API はボディで model を指定する。AI Gateway は
        ;; ヘッダー (ai-model-id) で指定するため含めない。
        ,@(when (eq ddskk-jev-backend 'typesafe)
            `((model . ,(ddskk-jev--model))))
        (questions . ((candidate . ((type . "choice")
                                    (instructions . ,ddskk-jev-instructions)
                                    (criteria . ,criteria)))))
        ,@(when (and ddskk-jev-zero-data-retention
                     (eq ddskk-jev-backend 'vercel))
            '((providerOptions . ((gateway . ((zeroDataRetention . t))))))))
      :null-object :null
      :false-object :false)
     'utf-8)))

;;;; HTTP

(defun ddskk-jev--request-headers (api-key)
  "API-KEY を使った HTTP ヘッダーの alist を返す。
Vercel AI Gateway には評価モダリティ用のヘッダーを付ける。
TypeSafe 直接では Authorization と Content-Type だけでよい。"
  (append
   `(("Content-Type" . "application/json")
     ("Authorization" . ,(concat "Bearer " api-key))
     ("User-Agent" . "ddskk-jev/0.1.0"))
   (when (eq ddskk-jev-backend 'vercel)
     `(("ai-gateway-protocol-version" . "0.0.1")
       ("ai-gateway-auth-method" . "api-key")
       ("ai-evaluation-model-specification-version" . "4")
       ("ai-model-id" . ,(ddskk-jev--model))))))

(defun ddskk-jev--post (body)
  "BODY (unibyte の JSON) をエンドポイントへ POST し、応答をパースして返す。
HTTP エラー・タイムアウト・パース失敗時は `ddskk-jev-error' を signal する。"
  (let* ((api-key (or (ddskk-jev--api-key)
                      (signal 'ddskk-jev-error '("API キーが見つかりません"))))
         (url-request-method "POST")
         (url-request-extra-headers (ddskk-jev--request-headers api-key))
         (url-request-data body)
         (url-show-status nil)
         (buffer (url-retrieve-synchronously (ddskk-jev--endpoint) t t
                                             ddskk-jev-timeout)))
    (unless (buffer-live-p buffer)
      (signal 'ddskk-jev-error (list "応答がありません (タイムアウト)")))
    (unwind-protect
        (with-current-buffer buffer
          (let ((status (bound-and-true-p url-http-response-status)))
            (unless (and (integerp status) (<= 200 status 299))
              (signal 'ddskk-jev-error
                      (list (format "HTTP %s: %s" status
                                    (ddskk-jev--response-body-string)))))
            (condition-case err
                (json-parse-string (ddskk-jev--response-body-string)
                                   :object-type 'alist
                                   :null-object nil
                                   :false-object nil)
              (error (signal 'ddskk-jev-error
                             (list (format "JSON のパースに失敗: %s" err)))))))
      (kill-buffer buffer))))

(defun ddskk-jev--response-body-string ()
  "カレントバッファ (url の応答バッファ) の本文を UTF-8 として返す。"
  (let ((start (if (and (boundp 'url-http-end-of-headers)
                        (integer-or-marker-p url-http-end-of-headers))
                   (1+ url-http-end-of-headers)
                 (save-excursion
                   (goto-char (point-min))
                   (if (re-search-forward "\r?\n\r?\n" nil t)
                       (point)
                     (point-min))))))
    (decode-coding-string
     (buffer-substring-no-properties (min start (point-max)) (point-max))
     'utf-8)))

;;;; 評価

(defun ddskk-jev--answer-from-response (response)
  "RESPONSE (alist) から choice 回答を取り出し plist で返す。
:probabilities は (候補 . 確率) の alist、:choice は選ばれたキー、
:confidence は応答に含まれていればその値、なければ最大確率。
形式が想定と異なるときは `ddskk-jev-error' を signal する。"
  (let* ((answers (alist-get 'answers response))
         (answer (alist-get 'candidate answers))
         (probabilities (alist-get 'probabilities answer))
         (confidence (alist-get 'confidence answer)))
    (unless (equal (alist-get 'type answer) "choice")
      (signal 'ddskk-jev-error
              (list (format "想定外の応答: %S" response))))
    (unless (and (listp probabilities) probabilities)
      (signal 'ddskk-jev-error
              (list (format "probabilities がありません: %S" response))))
    (let ((alist (mapcar (lambda (cell)
                           (cons (symbol-name (car cell)) (float (cdr cell))))
                         probabilities)))
      (list :probabilities alist
            :choice (alist-get 'choice answer)
            :confidence (if (numberp confidence)
                            (float confidence)
                          (apply #'max (mapcar #'cdr alist)))))))

(defun ddskk-jev--evaluate (state candidates)
  "STATE と CANDIDATES を Jev に問い合わせ、回答の plist を返す。
plist の形式は `ddskk-jev--answer-from-response' を参照。
失敗時は `ddskk-jev-error' を signal する。"
  (let* ((body (ddskk-jev--build-request state candidates))
         (start (current-time))
         (response (progn
                     (ddskk-jev--log "request: %s"
                                     (decode-coding-string body 'utf-8))
                     (setq ddskk-jev--last-request-time start)
                     (ddskk-jev--post body)))
         (answer (ddskk-jev--answer-from-response response)))
    (setq ddskk-jev--last-latency (float-time (time-subtract nil start))
          ddskk-jev-last-response response)
    (ddskk-jev--log "response (%.3fs): %S" ddskk-jev--last-latency response)
    answer))

(defun ddskk-jev--reorder (candidates probabilities)
  "CANDIDATES を PROBABILITIES (候補本体 . 確率) の降順に安定ソートする。
確率が得られなかった候補は 0 として扱う。"
  (let ((indexed (cl-loop for c in candidates
                          for i from 0
                          collect (cons i c))))
    (mapcar #'cdr
            (sort indexed
                  (lambda (a b)
                    (let ((pa (or (cdr (assoc (car (ddskk-jev--split-note
                                                    (ddskk-jev--candidate-word (cdr a))))
                                              probabilities))
                                  0.0))
                          (pb (or (cdr (assoc (car (ddskk-jev--split-note
                                                    (ddskk-jev--candidate-word (cdr b))))
                                              probabilities))
                                  0.0)))
                      (if (= pa pb)
                          (< (car a) (car b))
                        (> pa pb))))))))

(defun ddskk-jev--partition-candidates (henkan-list)
  "HENKAN-LIST を (問い合わせ対象 . それ以外) に分ける。
先頭から `ddskk-jev-max-candidates' 件までのうち、候補本体が重複しない
ものだけを対象とする。"
  (let (targets rest seen)
    (cl-loop for c in henkan-list
             for i from 0
             do (let ((word (car (ddskk-jev--split-note
                                  (ddskk-jev--candidate-word c)))))
                  (if (and (< i ddskk-jev-max-candidates)
                           (not (string-empty-p word))
                           (not (member word seen)))
                      (progn (push word seen)
                             (push c targets))
                    (push c rest))))
    (cons (nreverse targets) (nreverse rest))))

(defun ddskk-jev-reorder-henkan-list (henkan-list state)
  "HENKAN-LIST を STATE に基づいて並べ替えた新しいリストを返す。
問い合わせに失敗したときは HENKAN-LIST をそのまま返す。"
  (let* ((partition (ddskk-jev--partition-candidates henkan-list))
         (targets (car partition))
         (rest (cdr partition)))
    (if (< (length targets) ddskk-jev-min-candidates)
        henkan-list
      (condition-case err
          (let* ((words (mapcar #'ddskk-jev--candidate-word targets))
                 (answer (ddskk-jev--evaluate state words)))
            (setq ddskk-jev--consecutive-failures 0)
            (if (ddskk-jev--apply-p answer)
                (append (ddskk-jev--reorder targets (plist-get answer :probabilities))
                        rest)
              henkan-list))
        (error
         (ddskk-jev--record-failure (error-message-string err))
         henkan-list)))))

(defun ddskk-jev--apply-p (answer)
  "回答 ANSWER に基づいて並べ替えを適用すべきなら non-nil を返す。
「どの候補も合わない」が最上位のとき、または confidence が
`ddskk-jev-min-confidence' 未満のときは適用しない。"
  (let ((choice (plist-get answer :choice))
        (confidence (plist-get answer :confidence)))
    (cond ((and ddskk-jev-none-option (equal choice ddskk-jev--none-key))
           (ddskk-jev--log "skip: none_of_the_above was chosen")
           nil)
          ((and (numberp ddskk-jev-min-confidence)
                (< confidence ddskk-jev-min-confidence))
           (ddskk-jev--log "skip: confidence %.3f < %.3f"
                           confidence ddskk-jev-min-confidence)
           nil)
          (t t))))

(defun ddskk-jev--record-failure (message)
  "失敗を記録し、必要なら停止する。"
  (cl-incf ddskk-jev--consecutive-failures)
  (setq ddskk-jev--last-error message)
  (ddskk-jev--log "failure (%d): %s" ddskk-jev--consecutive-failures message)
  (if (and ddskk-jev-max-consecutive-failures
           (>= ddskk-jev--consecutive-failures
               ddskk-jev-max-consecutive-failures))
      (progn
        (setq ddskk-jev--suspended t)
        (message "ddskk-jev: %d 回連続で失敗したため停止しました (%s)。M-x ddskk-jev-reset で再開できます"
                 ddskk-jev--consecutive-failures message))
    (message "ddskk-jev: %s" message)))

;;;; ddskk への接続

(defun ddskk-jev--collect-remaining-candidates ()
  "`skk-current-search-prog-list' に残る検索プログラムをすべて評価し、
得られた候補を `skk-henkan-list' に加える。候補が増えたら
`skk-henkan-list-filter' を呼び直して数値変換などの後処理を適用する。"
  (when (and (boundp 'skk-current-search-prog-list)
             (fboundp 'skk-search)
             (fboundp 'skk-nunion))
    (let (added)
      (while skk-current-search-prog-list
        (let ((candidates (skk-search)))
          (when candidates
            (setq skk-henkan-list (skk-nunion skk-henkan-list candidates)
                  added t))))
      (when added
        (ddskk-jev--log "collected %d candidates from remaining progs"
                        (length skk-henkan-list))
        (skk-henkan-list-filter)))))

(defun ddskk-jev--maybe-reorder ()
  "`skk-henkan-list-filter' の後に呼ばれ、条件を満たせば候補を並べ替える。
変換の 1 発目 (`skk-henkan-count' が 0) のときだけ動作する。
`ddskk-jev-search-all-progs' が non-nil なら、先に残りの辞書を検索する。"
  (when (and ddskk-jev-mode
             (not ddskk-jev--suspended)
             (not ddskk-jev--in-reorder)
             (boundp 'skk-henkan-count)
             (eql skk-henkan-count 0)
             (listp skk-henkan-list)
             (stringp skk-henkan-key))
    (let ((ddskk-jev--in-reorder t))
      (when ddskk-jev-search-all-progs
        (ddskk-jev--collect-remaining-candidates))
      (if (< (length skk-henkan-list) ddskk-jev-min-candidates)
          (ddskk-jev--log "skip: %d candidate(s) < %d"
                          (length skk-henkan-list) ddskk-jev-min-candidates)
        (let ((state (ddskk-jev--build-state (ddskk-jev--context)
                                             skk-henkan-key
                                             skk-henkan-okurigana)))
          (setq skk-henkan-list
                (ddskk-jev-reorder-henkan-list skk-henkan-list state)))))))

;;;###autoload
(define-minor-mode ddskk-jev-mode
  "ddskk の変換候補を Jev で文脈に応じて並べ替えるグローバルマイナーモード。"
  :global t
  :lighter " Jev"
  :group 'ddskk-jev
  (if ddskk-jev-mode
      (advice-add 'skk-henkan-list-filter :after #'ddskk-jev--maybe-reorder)
    (advice-remove 'skk-henkan-list-filter #'ddskk-jev--maybe-reorder)))

;;;###autoload
(defun ddskk-jev-reset ()
  "失敗カウンタと停止状態をリセットする。"
  (interactive)
  (setq ddskk-jev--consecutive-failures 0
        ddskk-jev--suspended nil
        ddskk-jev--last-error nil)
  (message "ddskk-jev: リセットしました"))

;;;###autoload
(defun ddskk-jev-status ()
  "現在の状態 (有効・停止・直近の失敗・直近の応答) を表示する。"
  (interactive)
  (with-output-to-temp-buffer "*ddskk-jev status*"
    (princ (format "mode:                  %s\n" (if ddskk-jev-mode "on" "off")))
    (princ (format "backend:               %s\n" ddskk-jev-backend))
    (princ (format "endpoint:              %s\n" (ddskk-jev--endpoint)))
    (princ (format "model:                 %s\n" (ddskk-jev--model)))
    (princ (format "api key:               %s\n"
                   (if (ddskk-jev--api-key) "found" "NOT FOUND")))
    (princ (format "suspended:             %s\n" (if ddskk-jev--suspended "yes" "no")))
    (princ (format "consecutive failures:  %d / %s\n"
                   ddskk-jev--consecutive-failures
                   (or ddskk-jev-max-consecutive-failures "unlimited")))
    (princ (format "last error:            %s\n" (or ddskk-jev--last-error "-")))
    (princ (format "last request:          %s\n"
                   (if ddskk-jev--last-request-time
                       (format-time-string "%Y-%m-%d %H:%M:%S"
                                           ddskk-jev--last-request-time)
                     "-")))
    (princ (format "last latency:          %s\n"
                   (if ddskk-jev--last-latency
                       (format "%.3fs (timeout %.1fs)"
                               ddskk-jev--last-latency ddskk-jev-timeout)
                     "-")))
    (princ (format "search all progs:      %s\n" ddskk-jev-search-all-progs))
    (princ (format "min candidates:        %d\n" ddskk-jev-min-candidates))
    (princ (format "debug log:             %s\n"
                   (if ddskk-jev-debug ddskk-jev-log-buffer "off (setq ddskk-jev-debug t)")))
    (princ (format "last response:\n%S\n" ddskk-jev-last-response))))

;;;###autoload
(defun ddskk-jev-test-connection ()
  "固定の例文で Jev に問い合わせ、結果をメッセージ表示する。"
  (interactive)
  (let* ((state (ddskk-jev--build-state
                 (cons "会議の" "を確認してください。")
                 "きろく" nil))
         (candidates '("記録" "帰路区" "気力;annotation")))
    (condition-case err
        (let* ((answer (ddskk-jev--evaluate state candidates))
               (probabilities (plist-get answer :probabilities)))
          (message "ddskk-jev (%s): choice=%s confidence=%.3f | %s"
                   ddskk-jev-backend
                   (plist-get answer :choice)
                   (plist-get answer :confidence)
                   (mapconcat (lambda (cell)
                                (format "%s=%.3f" (car cell) (cdr cell)))
                              (sort (copy-sequence probabilities)
                                    (lambda (a b) (> (cdr a) (cdr b))))
                              " ")))
      (error (message "ddskk-jev: 失敗しました: %s" (error-message-string err))))))

(provide 'ddskk-jev)
;;; ddskk-jev.el ends here
