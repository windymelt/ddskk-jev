;;; ddskk-jev-test.el --- Tests for ddskk-jev -*- lexical-binding: t; -*-

;;; Commentary:

;; HTTP 層を差し替えて、リクエスト生成・応答の解釈・並べ替えを検証する。
;; 実行: make test

;;; Code:

(require 'ert)
(require 'ddskk-jev)

;; ddskk なしでテストするため、let で動的束縛できるように宣言する。
(defvar skk-henkan-start-point)
(defvar skk-henkan-end-point)
(defvar skk-henkan-okurigana)
(defvar skk-henkan-list)
(defvar skk-henkan-key)
(defvar skk-henkan-count)
(defvar skk-current-search-prog-list)

(defun ddskk-jev-test--parse (body)
  "unibyte の JSON BODY をパースして alist にする。"
  (json-parse-string (decode-coding-string body 'utf-8)
                     :object-type 'alist :null-object :null :false-object nil))

(ert-deftest ddskk-jev-test-build-request ()
  "state と candidates が想定の JSON になる。注釈は criteria の値になる。"
  (let* ((ddskk-jev-instructions "INSTR")
         (ddskk-jev-none-option nil)
         (ddskk-jev-zero-data-retention nil)
         (state (ddskk-jev--build-state (cons "会議の" "を確認") "きろく" nil))
         (json (ddskk-jev-test--parse
                (ddskk-jev--build-request state '("記録" "気力;annotation")))))
    (should (equal (alist-get 'context_before (alist-get 'state json)) "会議の"))
    (should (equal (alist-get 'reading (alist-get 'state json)) "きろく"))
    (should (equal (alist-get 'okurigana (alist-get 'state json)) ""))
    (let ((q (alist-get 'candidate (alist-get 'questions json))))
      (should (equal (alist-get 'type q) "choice"))
      (should (equal (alist-get 'instructions q) "INSTR"))
      (should (eq (alist-get '記録 (alist-get 'criteria q)) :null))
      (should (equal (alist-get '気力 (alist-get 'criteria q)) "annotation")))
    (should-not (alist-get 'providerOptions json))))

(ert-deftest ddskk-jev-test-build-request-none-option-and-structured-instructions ()
  "none_of_the_above が criteria に加わり、alist の指示文はオブジェクトになる。"
  (let* ((ddskk-jev-none-option t)
         (ddskk-jev-instructions '((question . "Q?") (notes . ["n1" "n2"])))
         (json (ddskk-jev-test--parse (ddskk-jev--build-request "s" '("a" "b"))))
         (q (alist-get 'candidate (alist-get 'questions json))))
    (should (equal (alist-get 'question (alist-get 'instructions q)) "Q?"))
    (should (equal (alist-get 'notes (alist-get 'instructions q)) ["n1" "n2"]))
    (should (stringp (alist-get 'none_of_the_above (alist-get 'criteria q))))
    (should (= (length (alist-get 'criteria q)) 3))))

(ert-deftest ddskk-jev-test-build-request-zero-data-retention ()
  "zeroDataRetention は Vercel バックエンドのときだけ providerOptions に入る。"
  (let* ((ddskk-jev-backend 'vercel)
         (ddskk-jev-zero-data-retention t)
         (json (ddskk-jev-test--parse
                (ddskk-jev--build-request "s" '("a" "b")))))
    (should (eq t (alist-get 'zeroDataRetention
                             (alist-get 'gateway
                                        (alist-get 'providerOptions json)))))
    (should-not (alist-get 'model json)))
  (let* ((ddskk-jev-backend 'typesafe)
         (ddskk-jev-zero-data-retention t)
         (json (ddskk-jev-test--parse
                (ddskk-jev--build-request "s" '("a" "b")))))
    (should-not (alist-get 'providerOptions json))))

(ert-deftest ddskk-jev-test-typesafe-backend-request ()
  "TypeSafe 直接ではボディに model を含め、Gateway 用ヘッダーを付けない。"
  (let* ((ddskk-jev-backend 'typesafe)
         (ddskk-jev-model nil)
         (ddskk-jev-endpoint nil)
         (json (ddskk-jev-test--parse (ddskk-jev--build-request "s" '("a" "b"))))
         (headers (ddskk-jev--request-headers "KEY")))
    (should (equal (alist-get 'model json) "jev-latest"))
    (should (equal (ddskk-jev--endpoint) "https://api.typesafe.ai/v1/systemone"))
    (should (equal (cdr (assoc "Authorization" headers)) "Bearer KEY"))
    (should-not (assoc "ai-model-id" headers))
    (should-not (assoc "ai-gateway-protocol-version" headers))))

(ert-deftest ddskk-jev-test-vercel-backend-request ()
  "Vercel ではボディに model を含めず、Gateway 用ヘッダーで指定する。"
  (let* ((ddskk-jev-backend 'vercel)
         (ddskk-jev-model nil)
         (ddskk-jev-endpoint nil)
         (json (ddskk-jev-test--parse (ddskk-jev--build-request "s" '("a" "b"))))
         (headers (ddskk-jev--request-headers "KEY")))
    (should-not (alist-get 'model json))
    (should (equal (ddskk-jev--endpoint)
                   "https://ai-gateway.vercel.sh/v4/ai/evaluation-model"))
    (should (equal (cdr (assoc "ai-model-id" headers)) "typesafe-ai/jev"))
    (should (equal (cdr (assoc "ai-evaluation-model-specification-version" headers)) "4"))))

(ert-deftest ddskk-jev-test-api-key-variable ()
  "`ddskk-jev-api-key' は文字列・関数・バックエンドごとの alist で指定できる。"
  (cl-letf (((symbol-function 'getenv) (lambda (_name) nil))
            ((symbol-function 'auth-source-search) (lambda (&rest _) nil)))
    (let ((ddskk-jev-backend 'vercel))
      (let ((ddskk-jev-api-key "plain"))
        (should (equal (ddskk-jev--api-key) "plain")))
      (let ((ddskk-jev-api-key (lambda () "from-fn")))
        (should (equal (ddskk-jev--api-key) "from-fn")))
      (let ((ddskk-jev-api-key ""))
        (should-not (ddskk-jev--api-key))))
    (let ((ddskk-jev-api-key '((vercel . "vc") (typesafe . (lambda () "ts")))))
      (let ((ddskk-jev-backend 'vercel))
        (should (equal (ddskk-jev--api-key) "vc")))
      (let ((ddskk-jev-backend 'typesafe))
        (should (equal (ddskk-jev--api-key) "ts"))))
    ;; alist に現在のバックエンドの要素が無ければ見つからない扱いになる
    (let ((ddskk-jev-api-key '((vercel . "vc")))
          (ddskk-jev-backend 'typesafe))
      (should-not (ddskk-jev--api-key)))))

(ert-deftest ddskk-jev-test-api-key-alist-falls-back-to-env ()
  "alist に該当バックエンドの要素が無いときは環境変数へ倒れる。"
  (let ((ddskk-jev-api-key '((vercel . "vc")))
        (ddskk-jev-backend 'typesafe))
    (cl-letf (((symbol-function 'getenv)
               (lambda (name) (and (equal name "TYPESAFE_API_KEY") "ts-env"))))
      (should (equal (ddskk-jev--api-key) "ts-env")))))

(ert-deftest ddskk-jev-test-backend-overrides-and-api-key-env ()
  "endpoint と model の明示指定はバックエンドの既定値より優先される。
API キーはバックエンドに応じた環境変数から読む。"
  (let ((ddskk-jev-backend 'typesafe)
        (ddskk-jev-endpoint "https://example.test/x")
        (ddskk-jev-model "jev-1.12"))
    (should (equal (ddskk-jev--endpoint) "https://example.test/x"))
    (should (equal (ddskk-jev--model) "jev-1.12")))
  (let ((ddskk-jev-api-key nil))
    (cl-letf (((symbol-function 'getenv)
               (lambda (name) (pcase name
                                ("TYPESAFE_API_KEY" "ts-key")
                                ("AI_GATEWAY_API_KEY" "vc-key")))))
      (let ((ddskk-jev-backend 'typesafe))
        (should (equal (ddskk-jev--api-key) "ts-key")))
      (let ((ddskk-jev-backend 'vercel))
        (should (equal (ddskk-jev--api-key) "vc-key")))))
  (let ((ddskk-jev-backend 'unknown))
    (should-error (ddskk-jev--endpoint) :type 'ddskk-jev-error)))

(ert-deftest ddskk-jev-test-answer-from-response ()
  "応答から probabilities・choice・confidence を取り出す。"
  (let* ((response '((answers . ((candidate . ((type . "choice")
                                               (choice . "記録")
                                               (confidence . 0.8)
                                               (probabilities . ((記録 . 0.9)
                                                                 (気力 . 0.1)))))))))
         (answer (ddskk-jev--answer-from-response response)))
    (should (equal (plist-get answer :probabilities)
                   '(("記録" . 0.9) ("気力" . 0.1))))
    (should (equal (plist-get answer :choice) "記録"))
    (should (= (plist-get answer :confidence) 0.8))))

(ert-deftest ddskk-jev-test-answer-from-response-without-confidence ()
  "confidence が無い応答 (AI Gateway 経由で落ちる場合) は最大確率で代用する。"
  (let* ((response '((answers . ((candidate . ((type . "choice")
                                               (choice . "a")
                                               (probabilities . ((a . 0.7) (b . 0.3)))))))))
         (answer (ddskk-jev--answer-from-response response)))
    (should (= (plist-get answer :confidence) 0.7))))

(ert-deftest ddskk-jev-test-answer-from-response-rejects-unexpected ()
  "choice 以外の応答はエラーになる。"
  (should-error
   (ddskk-jev--answer-from-response
    '((answers . ((candidate . ((type . "boolean") (probability . 0.5)))))))
   :type 'ddskk-jev-error))

(ert-deftest ddskk-jev-test-apply-p ()
  "none_of_the_above が選ばれたとき、confidence が低いときは適用しない。"
  (let ((ddskk-jev-none-option t)
        (ddskk-jev-min-confidence nil))
    (should (ddskk-jev--apply-p '(:choice "記録" :confidence 0.2)))
    (should-not (ddskk-jev--apply-p '(:choice "none_of_the_above" :confidence 0.9))))
  (let ((ddskk-jev-none-option nil)
        (ddskk-jev-min-confidence 0.5))
    (should (ddskk-jev--apply-p '(:choice "記録" :confidence 0.5)))
    (should-not (ddskk-jev--apply-p '(:choice "記録" :confidence 0.49)))))

(ert-deftest ddskk-jev-test-reorder-stable ()
  "確率降順に並び、同率と未知の候補は元の順序を保つ。"
  (should (equal (ddskk-jev--reorder '("a" "b;note" "c" "d")
                                     '(("b" . 0.5) ("a" . 0.2) ("d" . 0.2)))
                 '("b;note" "a" "d" "c"))))

(ert-deftest ddskk-jev-test-reorder-numeric-cons ()
  "数値変換時の (元 . 変換後) 形式の要素も並べ替えられる。"
  (should (equal (ddskk-jev--reorder '(("#1" . "１") ("#0" . "1"))
                                     '(("1" . 0.8) ("１" . 0.2)))
                 '(("#0" . "1") ("#1" . "１")))))

(ert-deftest ddskk-jev-test-partition ()
  "上限を超えた候補と重複する候補本体は問い合わせ対象から外れる。"
  (let ((ddskk-jev-max-candidates 3))
    (should (equal (ddskk-jev--partition-candidates
                    '("a" "b;x" "b;y" "c" "d"))
                   '(("a" "b;x") . ("b;y" "c" "d"))))))

(ert-deftest ddskk-jev-test-reorder-henkan-list-with-stubbed-http ()
  "HTTP を差し替えた end-to-end。並べ替え結果を確認する。"
  (let ((ddskk-jev--consecutive-failures 0)
        (ddskk-jev--suspended nil)
        (ddskk-jev-max-candidates 12)
        (ddskk-jev-min-candidates 2))
    (cl-letf (((symbol-function 'ddskk-jev--post)
               (lambda (body)
                 (let ((json (ddskk-jev-test--parse body)))
                   (should (equal (alist-get 'reading (alist-get 'state json))
                                  "きろく")))
                 '((answers . ((candidate . ((type . "choice")
                                             (choice . "記録")
                                             (confidence . 0.9)
                                             (probabilities . ((記録 . 0.94)
                                                               (帰路区 . 0.01)
                                                               (気力 . 0.04)
                                                               (none_of_the_above . 0.01)))))))))))
      (let ((state (ddskk-jev--build-state (cons "会議の" "") "きろく" nil)))
        (should (equal (ddskk-jev-reorder-henkan-list
                        '("帰路区" "気力;note" "記録" "きろく") state)
                       '("記録" "気力;note" "帰路区" "きろく")))
        (should (= ddskk-jev--consecutive-failures 0))))))

(ert-deftest ddskk-jev-test-none-of-the-above-keeps-order ()
  "モデルが「どの候補も合わない」を選んだときは辞書の順序を保つ。"
  (let ((ddskk-jev--consecutive-failures 0)
        (ddskk-jev--suspended nil)
        (ddskk-jev-none-option t))
    (cl-letf (((symbol-function 'ddskk-jev--post)
               (lambda (_body)
                 '((answers . ((candidate . ((type . "choice")
                                             (choice . "none_of_the_above")
                                             (probabilities . ((a . 0.1) (b . 0.3)
                                                               (none_of_the_above . 0.6)))))))))))
      (should (equal (ddskk-jev-reorder-henkan-list '("a" "b") "s") '("a" "b"))))))

(ert-deftest ddskk-jev-test-failure-keeps-order-and-suspends ()
  "失敗時は元の順序を返し、連続失敗が上限に達すると停止する。"
  (let ((ddskk-jev--consecutive-failures 0)
        (ddskk-jev--suspended nil)
        (ddskk-jev-max-consecutive-failures 2)
        (inhibit-message t))
    (cl-letf (((symbol-function 'ddskk-jev--post)
               (lambda (_body) (signal 'ddskk-jev-error '("boom")))))
      (should (equal (ddskk-jev-reorder-henkan-list '("a" "b") "s1") '("a" "b")))
      (should-not ddskk-jev--suspended)
      (should (equal (ddskk-jev-reorder-henkan-list '("a" "b") "s2") '("a" "b")))
      (should ddskk-jev--suspended)
      (should (= ddskk-jev--consecutive-failures 2)))
    (ddskk-jev-reset)
    (should-not ddskk-jev--suspended)
    (should (= ddskk-jev--consecutive-failures 0))))

(ert-deftest ddskk-jev-test-below-min-candidates-skips-http ()
  "候補が少ないときは問い合わせない。"
  (let ((ddskk-jev-min-candidates 2))
    (cl-letf (((symbol-function 'ddskk-jev--post)
               (lambda (_body) (ert-fail "HTTP を呼ぶべきではない"))))
      (should (equal (ddskk-jev-reorder-henkan-list '("a") "s") '("a"))))))

(defmacro ddskk-jev-test--with-fake-skk (progs &rest body)
  "ddskk の検索関数を PROGS (候補リストのリスト) を順に返すスタブにして BODY を実行する。
`skk-search' は `skk-current-search-prog-list' の先頭を 1 つ消費し、
対応する候補を返す。`skk-nunion' は重複を除いた連結、
`skk-henkan-list-filter' は何もしない。"
  (declare (indent 1))
  `(let ((skk-current-search-prog-list (copy-sequence ,progs)))
     (cl-letf (((symbol-function 'skk-search)
                (lambda ()
                  (prog1 (car skk-current-search-prog-list)
                    (setq skk-current-search-prog-list
                          (cdr skk-current-search-prog-list)))))
               ((symbol-function 'skk-nunion)
                (lambda (a b) (append a (cl-remove-if (lambda (x) (member x a)) b))))
               ((symbol-function 'skk-henkan-list-filter)
                (lambda () nil)))
       ,@body)))

(ert-deftest ddskk-jev-test-collect-remaining-candidates ()
  "残りの検索プログラムをすべて評価して skk-henkan-list に追加する。"
  (let ((skk-henkan-list '("個人")))
    (ddskk-jev-test--with-fake-skk '(nil ("大辞書1" "個人") ("サーバ"))
      (ddskk-jev--collect-remaining-candidates)
      (should (equal skk-henkan-list '("個人" "大辞書1" "サーバ")))
      (should-not skk-current-search-prog-list))))

(ert-deftest ddskk-jev-test-maybe-reorder-searches-all-progs-first ()
  "1 発目で個人辞書の候補が 1 件でも、残りの辞書を検索してから Jev に渡す。"
  (with-temp-buffer
    (insert "会議の▽きろく")
    (let ((ddskk-jev-mode t)
          (ddskk-jev--suspended nil)
          (ddskk-jev--consecutive-failures 0)
          (ddskk-jev-search-all-progs t)
          (ddskk-jev-min-candidates 2)
          (skk-henkan-count 0)
          (skk-henkan-key "きろく")
          (skk-henkan-okurigana nil)
          (skk-henkan-start-point (copy-marker 5))
          (skk-henkan-end-point (point-marker))
          (skk-henkan-list '("帰路区"))
          sent)
      (ddskk-jev-test--with-fake-skk '(("気力" "記録"))
        (cl-letf (((symbol-function 'ddskk-jev--post)
                   (lambda (body)
                     (setq sent (ddskk-jev-test--parse body))
                     '((answers . ((candidate . ((type . "choice")
                                                 (choice . "記録")
                                                 (probabilities . ((記録 . 0.9)
                                                                   (気力 . 0.08)
                                                                   (帰路区 . 0.02)))))))))))
          (ddskk-jev--maybe-reorder)))
      (should (equal skk-henkan-list '("記録" "気力" "帰路区")))
      (should (= (length (alist-get 'criteria
                                    (alist-get 'candidate
                                               (alist-get 'questions sent))))
                 4)))))

(ert-deftest ddskk-jev-test-maybe-reorder-without-search-all-progs ()
  "`ddskk-jev-search-all-progs' が nil なら残りの辞書は検索せず、候補不足なら問い合わせない。"
  (with-temp-buffer
    (insert "▽きろく")
    (let ((ddskk-jev-mode t)
          (ddskk-jev--suspended nil)
          (ddskk-jev-search-all-progs nil)
          (ddskk-jev-min-candidates 2)
          (skk-henkan-count 0)
          (skk-henkan-key "きろく")
          (skk-henkan-okurigana nil)
          (skk-henkan-start-point (copy-marker 2))
          (skk-henkan-end-point (point-marker))
          (skk-henkan-list '("帰路区")))
      (ddskk-jev-test--with-fake-skk '(("気力" "記録"))
        (cl-letf (((symbol-function 'ddskk-jev--post)
                   (lambda (_body) (ert-fail "HTTP を呼ぶべきではない"))))
          (ddskk-jev--maybe-reorder))
        ;; 残りの検索プログラムは消費されない
        (should (equal skk-current-search-prog-list '(("気力" "記録")))))
      (should (equal skk-henkan-list '("帰路区"))))))

(ert-deftest ddskk-jev-test-maybe-reorder-skips-when-not-first-henkan ()
  "2 発目以降 (skk-henkan-count が 0 以外) では何もしない。"
  (let ((ddskk-jev-mode t)
        (ddskk-jev--suspended nil)
        (ddskk-jev-search-all-progs t)
        (skk-henkan-count 1)
        (skk-henkan-key "きろく")
        (skk-henkan-list '("a" "b")))
    (ddskk-jev-test--with-fake-skk '(("c"))
      (cl-letf (((symbol-function 'ddskk-jev--post)
                 (lambda (_body) (ert-fail "HTTP を呼ぶべきではない"))))
        (ddskk-jev--maybe-reorder)))
    (should (equal skk-henkan-list '("a" "b")))))

(ert-deftest ddskk-jev-test-status-command ()
  "`ddskk-jev-status' がエラーなく状態バッファを作る。"
  (let ((ddskk-jev-backend 'vercel)
        (ddskk-jev--suspended t)
        (ddskk-jev--last-error "HTTP 401: x")
        (ddskk-jev--last-latency 0.5)
        (ddskk-jev--last-request-time (current-time)))
    (cl-letf (((symbol-function 'ddskk-jev--api-key) (lambda () nil)))
      (ddskk-jev-status))
    (with-current-buffer "*ddskk-jev status*"
      (should (string-match-p "suspended: *yes" (buffer-string)))
      (should (string-match-p "NOT FOUND" (buffer-string)))
      (should (string-match-p "HTTP 401" (buffer-string))))
    (kill-buffer "*ddskk-jev status*")))

(ert-deftest ddskk-jev-test-context ()
  "変換位置の前後から指定文字数を切り出す。マーカー文字は前文脈に含めない。"
  (with-temp-buffer
    ;; ddskk は ▽ の直後に start-point を置く (位置 12)
    (insert "abcdefghij▽よみklmnopqrst")
    (let ((ddskk-jev-context-before-chars 4)
          (ddskk-jev-context-after-chars 3)
          (skk-henkan-okurigana nil)
          (skk-henkan-start-point (copy-marker 12))
          (skk-henkan-end-point (copy-marker 14)))
      (should (equal (ddskk-jev--context) (cons "ghij" "klm"))))
    (let ((skk-henkan-okurigana nil)
          (skk-henkan-start-point nil)
          (skk-henkan-end-point nil))
      (should (equal (ddskk-jev--context) (cons "" ""))))))

(ert-deftest ddskk-jev-test-context-okurigana ()
  "end-point 直後に残る送り仮名は後文脈に含めない。▼ も前文脈から除く。"
  (with-temp-buffer
    (insert "本を▼よりました。")
    (let ((ddskk-jev-context-before-chars 10)
          (ddskk-jev-context-after-chars 10)
          (skk-henkan-okurigana "り")
          (skk-henkan-start-point (copy-marker 4))
          (skk-henkan-end-point (copy-marker 6)))
      (should (equal (ddskk-jev--context) (cons "本を" "ました。"))))))

(provide 'ddskk-jev-test)
;;; ddskk-jev-test.el ends here
