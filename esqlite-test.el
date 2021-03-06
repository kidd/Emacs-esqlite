;; -*- coding: utf-8 -*-
;;TODO switch esqlite command version.

(require 'ert)

(defun esqlite-test-wait-exit (process)
  (while (eq (process-status process) 'run) (sleep-for 0.01)))

(defun esqlite-test-make-tempfile ()
  (make-temp-file "esqlite-test-"))

(defun esqlite-test-call/tempfile (proc-db)
  (let ((db (esqlite-test-make-tempfile)))
    (unwind-protect
        (funcall proc-db db)
      (delete-file db))))

(defun esqlite-test-call/stream (proc-stream)
  (esqlite-test-call/tempfile
   (lambda (db)
     (let* ((stream (esqlite-stream-open db)))
       (unwind-protect
           (funcall proc-stream stream)
         (esqlite-stream-close stream 0))))))

(ert-deftest normal-0001 ()
  :tags '(esqlite)
  (esqlite-test-call/stream
   (lambda (stream)
     (should (esqlite-stream-execute stream "CREATE TABLE hoge (id INTEGER PRIMARY KEY, text TEXT)"))
     (should (equal '((0 "id" "INTEGER" nil :null t) (1 "text" "TEXT" nil :null nil))
                    (esqlite-read-table-schema stream "hoge")))
     (should (esqlite-stream-execute stream "INSERT INTO hoge \nVALUES (1, 'a')"))
     (should (esqlite-stream-execute stream "INSERT INTO hoge \nVALUES (2, 'b')"))
     (should (equal '(("1" "a") ("2" "b"))
                    (esqlite-stream-read
                     stream "SELECT * FROM hoge ORDER BY id")))
     (should (esqlite-stream-execute stream "UPDATE hoge SET id = id + 10, text = text || 'z'"))
     (should (equal
              '(("11" "az") ("12" "bz"))
              (esqlite-stream-read stream "SELECT * \n\nFROM hoge")))
     (should (esqlite-stream-execute stream "DELETE FROM hoge \nWHERE id = 11"))
     (should (equal
              '(("12" "bz"))
              (esqlite-stream-read stream "SELECT * FROM hoge")))
     (should (esqlite-stream-execute stream "INSERT INTO hoge VALUES(3, 'あイｳ')"))
     (should (equal
              '(("あイｳ"))
              (esqlite-stream-read stream "SELECT text FROM hoge WHERE id = 3")))
     (should (equal
              '("あイｳ")
              (esqlite-stream-read-top stream "SELECT text FROM hoge WHERE id = 3")))
     (should (equal
              "あイｳ"
              (esqlite-stream-read-atom stream "SELECT text FROM hoge WHERE id = 3"))))))

(ert-deftest normal-0002 ()
  :tags '(esqlite)
  (esqlite-test-call/stream
   (lambda (stream)
     (should (esqlite-stream-execute stream "CREATE TABLE hoge (id INTEGER PRIMARY KEY, text TEXT)"))
     ;; try to create multibyte data (not utf-8)
     (esqlite-stream-set-coding-system stream 'shift_jis 'shift_jis)
     (unwind-protect
         (progn
           (should (esqlite-stream-execute
                    stream (esqlite-format
                            "INSERT INTO hoge \nVALUES (1, %T)"
                            "あイｳe")))
           (should (equal
                    "あイｳe"
                    (esqlite-stream-read-atom stream "SELECT text \nFROM hoge \nWHERE id = 1")
                    )))
       ;; reset
       (esqlite-stream-reset-coding-system stream))
     (should (equal
              "あイｳe"
              (decode-coding-string
               (esqlite-stream-read-atom stream "SELECT text \nFROM hoge \nWHERE id = 1")
               'shift_jis))))))

(ert-deftest normal-0003 ()
  :tags '(esqlite)
  ;; try to create binary data
  ;; -csv option can't output which contain 0 byte sequence.
  ;;  shell.c says only handle TEXT data not BLOB.
  (esqlite-test-call/stream
   (lambda (stream)
     (should (esqlite-stream-execute stream "CREATE TABLE hoge \n(id INTEGER PRIMARY KEY, text TEXT)"))
     (esqlite-stream-set-coding-system stream 'binary 'binary)
     (unwind-protect
         (progn
           (should (esqlite-stream-execute
                    stream (esqlite-format
                            "INSERT INTO hoge \nVALUES (2, %X)"
                            "\x57\x00\x57\xbf\xff")))
           (should (equal
                    "\x57\x00\x57\xbf\xff"
                    (esqlite-hex-to-bytes
                     (esqlite-stream-read-atom stream "SELECT HEX(text) FROM hoge WHERE id = 2"))
                    )))
       ;; reset
       (esqlite-stream-reset-coding-system stream)))))

(ert-deftest normal-0004 ()
  :tags '(esqlite)
  (let ((s1 (esqlite-stream-memory 'test1))
        (s2 (esqlite-stream-memory 'test2)))
    (should (esqlite-stream-alive-p s1))
    (should (esqlite-stream-alive-p s2))
    (should (eq s1 (esqlite-stream-memory 'test1)))
    (should-error (esqlite-stream-memory "a"))))

(ert-deftest normal-0005 ()
  :tags '(esqlite)
  (should-error (esqlite-stream-open 'test1)))

(ert-deftest normal-0006 ()
  :tags '(esqlite)
  (esqlite-test-call/stream
   (lambda (stream)
     (esqlite-stream-async-execute stream "CREATE TABLE foo(a,b,c)")
     (dotimes (i 10)
       (esqlite-stream-async-execute
        stream (format "INSERT INTO foo VALUES(%d,%d,%d)"
                       i i i)))
     ;; check detect the error
     (should-error (esqlite-stream-async-execute stream "INSERT"))
     (should-error (esqlite-stream-async-execute stream "INSERT '") :type 'esqlite-unterminate-query)
     ;; terminate the previous statement (but error)
     (should-error (esqlite-stream-async-execute stream "'"))
     (should (equal (esqlite-stream-read stream "SELECT a,b,c FROM foo WHERE a = 1")
                    '(("1" "1" "1")))))))

(ert-deftest normal-0007 ()
  :tags '(esqlite)
  (let ((ms (esqlite-stream-memory)))
    (esqlite-stream-async-execute ms "CREATE TABLE foo(a)")
    (let ((i (random ?\xffffff))
          (dbfile (esqlite-test-make-tempfile)))
      (esqlite-stream-async-execute ms (format "INSERT INTO foo VALUES(%d)" i))
      ;; backup file (and test `esqlite-stream-send-command')
      (esqlite-stream-send-command ms "backup" dbfile)
      (esqlite-stream-close ms)
      (let ((stream (esqlite-stream-open dbfile)))
        (unwind-protect
            ;; check correctly saved and can restore
            (should (esqlite-stream-read-atom stream (format "SELECT a FROM foo WHERE a = %d" i)))
          (esqlite-stream-close stream))))))

(ert-deftest irregular-0001 ()
  :tags '(esqlite)
  (esqlite-test-call/stream
   (lambda (stream)
     (esqlite-stream-execute stream "CREATE TABLE hoge (id INTEGER PRIMARY KEY)")
     (should-error (esqlite-stream-execute stream "CREATE TABLE1"))
     (should-error (esqlite-stream-execute stream "CREATE TABLE hoge (id INTEGER PRIMARY KEY)"))
     (esqlite-stream-execute stream "INSERT INTO hoge VALUES (1)")
     (should-error (esqlite-stream-execute stream "INSERT INTO hoge VALUES (1)"))
     (should (equal '(("1")) (esqlite-stream-read stream "SELECT * FROM hoge")))
     (should-error (esqlite-stream-read stream "SELECT"))
     ;; works fine after syntax error
     (should (equal '(("1")) (esqlite-stream-read stream "SELECT * FROM hoge")))
     ;; works fine multiple line statement
     (should (esqlite-stream-read stream "SELECT 1\n FROM hoge\n\n"))
     (should (equal '(("1")) (esqlite-stream-read stream "SELECT * FROM hoge")))
     (should (esqlite-file-guessed-database-p db)))))

(ert-deftest irregular-0002 ()
  :tags '(esqlite)
  (esqlite-test-call/stream
   (lambda (stream)
     ;; unterminated string in query
     (should-error (esqlite-stream-read stream "SELECT '")
                   :type 'esqlite-unterminate-query)
     ;; stream still alive
     (should (esqlite-stream-alive-p stream)))))

(ert-deftest irregular-0003 ()
  :tags '(esqlite)
  (esqlite-test-call/stream
   (lambda (stream)
     ;; contain error statement in compound statement
     (should-error (esqlite-stream-read stream "select\n 1;\n\n select; select 3;\n"))

     ;; compound statement may have newlines
     (should (equal (esqlite-stream-read stream "select 1; select 2; select 3;") '(("1") ("2") ("3"))))
     (should (equal (esqlite-stream-read stream "select 1;\n select 2; select 3;") '(("1") ("2") ("3"))))
     (should (equal (esqlite-stream-read stream "select\n 1;\n select\n 2; select 3;") '(("1") ("2") ("3"))))
     (should (equal (esqlite-stream-read stream "select\n 1;\n\n select\n 2; select 3;\n\n") '(("1") ("2") ("3"))))
     (should (equal (esqlite-stream-read stream "select\n 1;\n\n select\n 2\n; \nselect 3;\n\n") '(("1") ("2") ("3"))))

     (should (equal (esqlite-stream-read stream "select\n 1;\n\n select\n '\n'\n; \nselect 3;\n\n") '(("1") ("\n") ("3"))))
     (should (equal (esqlite-stream-read stream "select\n 1;\n\n select\n '\n\n'\n; \nselect 3;\n\n") '(("1") ("\n\n") ("3"))))
     )))

(ert-deftest async-read-0001 ()
  :tags '(esqlite)
  (esqlite-test-call/tempfile
   (lambda (db)
     (esqlite-async-execute db "CREATE TABLE hoge (id);" (lambda ()))
     (let ((query (mapconcat
                   'identity
                   (mapcar
                    (lambda (n)
                      (format "INSERT INTO hoge VALUES(%d);" n))
                    (number-sequence 1 5)) "")))
       (esqlite-async-read db query (lambda (x)))
       (lexical-let ((result '()))
         (esqlite-async-read
          db "SELECT id FROM hoge;"
          (lambda (x)
            (if (eq x :EOF)
                (should (equal '(5 4 3 2 1) result))
              (setq result (cons (string-to-number (nth 0 x)) result))))))
       (should-error (esqlite-async-read db "SELECT" (lambda (x))))
       ;; unterminated string in query
       (should-error (esqlite-async-read db "SELECT '" (lambda (x)))
                     :type 'esqlite-unterminate-query)))))

(ert-deftest read-0001 ()
  :tags '(esqlite)
  (esqlite-test-call/tempfile
   (lambda (db)
     (esqlite-read db "CREATE TABLE hoge (id, text);")
     (esqlite-read db "INSERT INTO hoge \nVALUES (1, 'あイｳ');")
     (should (equal '(("あイｳ")) (esqlite-read db "SELECT text FROM hoge WHERE id = 1")))
     (should-error (esqlite-read db "SELECT"))
     ;; unterminated string in query
     (should-error (esqlite-read db "SELECT '") :type 'esqlite-unterminate-query)
     (should (equal '("あイｳ") (esqlite-read-top db "SELECT text FROM hoge WHERE id = 1")))
     (should (equal "あイｳ" (esqlite-read-atom db "SELECT text FROM hoge WHERE id = 1"))))))

(ert-deftest format-call-macro ()
  :tags '(esqlite)
  (esqlite-test-call/tempfile
   (lambda (db)
     (esqlite-call/stream db
       (lambda (s)
         (should (equal (esqlite-stream-read-atom s "SELECT 1") "1"))))
     (esqlite-call/transaction db
       (lambda (s)
         (should (equal (esqlite-stream-read-atom s "SELECT 1") "1")))))))

;;TODO prepare big test data file.
;;TODO helm interactive test

(ert-deftest format-value-0001 ()
  :tags '(esqlite)
  (should (equal "''" (esqlite-format-value "")))
  ;; string which is only ascii printable and common chars
  (should (equal "'a\n\r\t\s'" (esqlite-format-value "a\n\r\t\s")))
  ;; unibyte string
  (should (equal "x'00'" (esqlite-format-value "\x00")))
  (should (equal "x'7f'" (esqlite-format-value "\x7f")))
  ;; multibyte string (well encoded)
  (should (equal "'あ'" (esqlite-format-value "あ")))
  ;; unibyte string (encoded from well encoded multibyet string)
  (should (equal "x'82a0'" (esqlite-format-value (encode-coding-string "あ" 'shift_jis))))
  (should (equal "1" (esqlite-format-value 1)))
  (should (equal "null" (esqlite-format-value :null)))
  (should (equal "null, 'a', 'あ', 1, x'00'"
                 (esqlite-format-value
                  (list :null "a" "あ" 1 "\x00"))))
  )

(ert-deftest escape-0001 ()
  :tags '(esqlite)
  (should (equal "A" (esqlite-escape-string "A") ))
  (should (equal "A''''" (esqlite-escape-string "A''")))
  (should (equal "A''\"" (esqlite-escape-string "A'\"")))
  (should (equal "A'\"\"" (esqlite-escape-string "A'\"" ?\")))
  (should (equal "A" (esqlite-escape-like "A" ?\\)))
  (should (equal "A\\%\\_" (esqlite-escape-like "A%_" ?\\)))
  (should (equal "\\\\\\%\\\\\\_" (esqlite-escape-like "\\%\\_" ?\\))))

(ert-deftest glob-to-like-0001 ()
  :tags '(esqlite)
  (should (equal "a" (esqlite-helm-glob-to-like "a")))
  (should (equal "%ab_" (esqlite-helm-glob-to-like "*ab?")))
  (should (equal "\\_a" (esqlite-helm-glob-to-like "_a" ?\\)))
  (should (equal "*?%_\\%\\_" (esqlite-helm-glob-to-like "\\*\\?*?\\%\\_" ?\\)))
  (should (equal "*0\\%" (esqlite-helm-glob-to-like "\\*0%" ?\\)))
  (should (equal "\\0|%||" (esqlite-helm-glob-to-like "\\\\0%|" ?\|)))
  (should (equal "\\\\0\\%|" (esqlite-helm-glob-to-like "\\\\0%|" ?\\))))

(ert-deftest glob-to-fuzzy-like-0001 ()
  :tags '(esqlite)
  (should (equal "a%" (esqlite-helm-glob-to-fuzzy-like "^a")))
  (should (equal "%a%" (esqlite-helm-glob-to-fuzzy-like "a")))
  (should (equal "%a" (esqlite-helm-glob-to-fuzzy-like "a$")))
  (should (equal "%^a%" (esqlite-helm-glob-to-fuzzy-like "\\^a")))
  (should (equal "%a$%" (esqlite-helm-glob-to-fuzzy-like "a\\$")))
  (should (equal "%a\\\\" (esqlite-helm-glob-to-fuzzy-like "a\\\\$")))
  (should (equal "%\\$%" (esqlite-helm-glob-to-fuzzy-like "\\\\$" ?a)))
  )

(ert-deftest glob-to-fuzzy-like-0001 ()
  :tags '(esqlite)
  (should (equal "a*" (esqlite-helm-glob-to-fuzzy-glob "^a")))
  (should (equal "*a*" (esqlite-helm-glob-to-fuzzy-glob "a")))
  (should (equal "*a" (esqlite-helm-glob-to-fuzzy-glob "a$"))))

(ert-deftest format-0001 ()
  :tags '(esqlite)
  ;;TODO error test

  (should (equal
           (concat
            "SELECT \n"
            "\"a\", \"b\",\"c\",'''text','something',x'00ff'\n"
            " FROM \"table\"\n"
            " WHERE\n"
            " \"d\" LIKE 'hoge' ESCAPE '\\' \n"
            " AND col2 IN ('foo', 1)")
           (let ((search-text "hoge"))
             (esqlite-format
              '("SELECT "
                "%O,%o,%T,%V,%X"
                " FROM %o"
                " WHERE"
                " %o LIKE %L{search-text}"
                " AND col2 IN (%V)")
              '("a" "b")
              "c" "'text"
              "something" "\x00\xff"
              "table"
              "d" '("foo" 1)))))
  (should (equal
           (concat
            "INSERT INTO (\"a\", \"b\")\n"
            " VALUES ('1', 2) ")
           (esqlite-format
            '(
              "INSERT INTO (%O)"
              " VALUES (%V) ")
            '("a" "b") '("1" 2))))

  ;; malicious name
  (should
   (equal
    "\"odd \"\" table\""
    (esqlite-format "%o" "odd \" table")))

  )

(ert-deftest number-0001 ()
  :tags '(esqlite)
  (should (esqlite-numeric-text-p "1"))
  (should (esqlite-numeric-text-p "+2"))
  (should (esqlite-numeric-text-p "-3"))
  (should (esqlite-numeric-text-p "+4.0"))
  (should (esqlite-numeric-text-p "+4.0E50")))
