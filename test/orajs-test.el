;;; orajs-test.el --- ERT tests for orajs  -*- lexical-binding: t; -*-

;; Unit tests need no database: where one is involved, the bridge is
;; replaced by canned replies.  The orajs-live-* tests go through the
;; real bridge to a real database when ORAJS_SERVICE is set (CI runs
;; Oracle Database Free; locally, source test/env.sh), else they skip.
;; test/bridge-test.js covers the bridge protocol in depth.
;;
;;   emacs --batch -Q -L . -l test/orajs-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'orajs)

(defmacro orajs-test--with-sql (text &rest body)
  "Run BODY in a `sql-mode' buffer holding TEXT; \"|\" in TEXT marks point."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     (let ((mark (search-forward "|" nil t)))
       (when mark (delete-char -1)))
     (let ((sql-mode-hook nil)) (sql-mode))
     (syntax-ppss-flush-cache (point-min))
     ,@body))

(defconst orajs-test--script "select * from dual;

select 1
from   dual
where  'a;b' = 'a;b';  -- a ; in a string
-- a comment before the package
create or replace package body p as
  procedure x is
  begin

    null;  -- blank line above is inside the unit
  end;
end;
/
select 2 from dual
/
insert into t values (1)

update t set a = 1")

(defun orajs-test--texts ()
  (mapcar (lambda (s) (string-trim (buffer-substring-no-properties (car s) (cadr s))))
          (orajs--statements)))

(ert-deftest orajs-statements-split ()
  (orajs-test--with-sql orajs-test--script
    (should (equal (orajs-test--texts)
                   '("select * from dual"
                     "select 1\nfrom   dual\nwhere  'a;b' = 'a;b'"
                     "create or replace package body p as\n  procedure x is\n  begin\n\n    null;  -- blank line above is inside the unit\n  end;\nend;"
                     "select 2 from dual"
                     "insert into t values (1)"
                     "update t set a = 1")))))

(ert-deftest orajs-statement-at-point ()
  (orajs-test--with-sql orajs-test--script
    (dolist (case '(("from   dual" . "select 1")
                    ("null;" . "create or replace package body p")
                    ("\n\n    null" . "create or replace package body p") ; the blank line inside
                    ("end;\n/" . "create or replace package body p")
                    ("select 2" . "select 2 from dual")
                    ("set a" . "update t set a = 1")))
      (goto-char (point-min))
      (search-forward (car case))
      (should (string-prefix-p (cdr case) (car (orajs--statement-at-point)))))
    ;; On the blank line between two statements: the one before.
    (goto-char (point-min))
    (search-forward "values (1)\n")
    (should (equal (car (orajs--statement-at-point)) "insert into t values (1)"))))

(ert-deftest orajs-grid-values ()
  ;; Exact numbers where Emacs can hold them, else the string.
  (should (equal (orajs--sort-value "146064" t) 146064))
  (should (equal (orajs--sort-value "123456789012345678901234567890" t)
                 123456789012345678901234567890))
  (should (equal (orajs--sort-value ".1" t) 0.1))
  (should (equal (orajs--sort-value "-12.5" t) -12.5))
  (should (equal (orajs--sort-value "12345678901234567890.123456789" t)
                 "12345678901234567890.123456789"))
  (should (eql (orajs--sort-value nil t) 1.0e+INF))
  (should (eq (orajs--sort-value nil nil) orajs--null))
  (should (equal (orajs--sort-value "007" nil) "007"))
  ;; Display.
  (should (equal (orajs--format-cell 146064) "146064"))
  (should (equal (orajs--format-cell 0.1) "0.1"))
  (should (equal (orajs--format-cell "line1\nline2") "line1⏎line2"))
  (should (equal (orajs--format-cell 1.0e+INF) "∅"))
  (should (equal (orajs--format-cell orajs--null) "∅"))
  (should (equal (orajs--format-cell nil) "∅")))

(ert-deftest orajs-json-pretty ()
  (should (equal (orajs--json-pretty
                  "{\"_id\":10,\"n\":12345678901234567890.123456789,\"s\":\"a{b},[c]: \\\"q\\\"\",\"e\":[],\"o\":{},\"staff\":[{\"empno\":1},{\"empno\":2}]}")
                 (concat "{\n"
                         "  \"_id\": 10,\n"
                         "  \"n\": 12345678901234567890.123456789,\n"
                         "  \"s\": \"a{b},[c]: \\\"q\\\"\",\n"
                         "  \"e\": [],\n"
                         "  \"o\": {},\n"
                         "  \"staff\": [\n"
                         "    {\n"
                         "      \"empno\": 1\n"
                         "    },\n"
                         "    {\n"
                         "      \"empno\": 2\n"
                         "    }\n"
                         "  ]\n"
                         "}")))
  (should (equal (orajs--json-pretty "[1,2]") "[\n  1,\n  2\n]"))
  (should (equal (orajs--json-pretty "\"just a string\"") "\"just a string\"")))

;;;; Completion against a fake cache

(defun orajs-test--load-fake-cache ()
  (setq orajs--user "HR")
  (orajs--reset-cache)
  (setq orajs--schemas '("HR" "SALES"))
  (orajs--merge-objects [["HR" "DEPT" "TABLE" "2026-09-01T00:00:00"]
                          ["HR" "EMP" "TABLE" "2026-09-01T00:00:00"]
                          ["SALES" "ORDERS" "TABLE" "2026-09-01T00:00:00"]
                          ["SALES" "ORDER_V" "VIEW" "2026-09-01T00:00:00"]])
  (orajs--put-columns [["HR" "DEPT" "DEPTNO" "NUMBER"]
                        ["HR" "DEPT" "DNAME" "VARCHAR2"]
                        ["HR" "EMP" "EMPNO" "NUMBER"]
                        ["HR" "EMP" "ENAME" "VARCHAR2"]
                        ["HR" "EMP" "DEPTNO" "NUMBER"]
                        ["SALES" "ORDERS" "ID" "NUMBER"]
                        ["SALES" "ORDER_V" "ID" "NUMBER"]]))

(ert-deftest orajs-merge-objects ()
  (orajs-test--load-fake-cache)
  (let ((changed (orajs--merge-objects
                  [["HR" "DEPT" "TABLE" "2026-09-01T00:00:00"]          ; same
                   ["HR" "EMP" "TABLE" "2026-09-30T10:00:00"]           ; altered
                   ["HR" "JOBS" "TABLE" "2026-09-30T10:00:00"]          ; new
                   ["SALES" "ORDER_V" "VIEW" "2026-09-01T00:00:00"]]))) ; ORDERS dropped
    (should (equal changed '("HR.EMP" "HR.JOBS")))
    (should-not (gethash "SALES.ORDERS" orajs--tables))
    ;; Unchanged tables keep their columns; changed ones keep the old until refetched.
    (should (equal (length (plist-get (gethash "HR.DEPT" orajs--tables) :columns)) 2))
    (should (equal (plist-get (gethash "HR.EMP" orajs--tables) :ddl) "2026-09-30T10:00:00"))
    (orajs--put-columns [["HR" "EMP" "EMPNO" "NUMBER"] ["HR" "EMP" "HIRED" "DATE"]
                          ["HR" "JOBS" "JOB_ID" "VARCHAR2"]])
    (should (equal (plist-get (gethash "HR.EMP" orajs--tables) :columns)
                   '(("EMPNO" . "NUMBER") ("HIRED" . "DATE"))))
    (should (equal (plist-get (gethash "HR.JOBS" orajs--tables) :columns)
                   '(("JOB_ID" . "VARCHAR2"))))
    (should (equal (length (plist-get (gethash "HR.DEPT" orajs--tables) :columns)) 2))))

(ert-deftest orajs-disk-cache-round-trip ()
  (let* ((orajs-cache-directory (make-temp-file "orajs-cache" t))
         (orajs--connection "my db/1"))
    (unwind-protect
        (progn
          (orajs-test--load-fake-cache)
          (setq orajs--dictionary '(("ALL_TABLES" . "tables") ("DUAL"))
                orajs--dictionary-server "23.26.3.3.0")
          (puthash "DUAL" '(:owner "SYS" :name "DUAL" :type "TABLE" :columns (("DUMMY" . "VARCHAR2")))
                   orajs--described)
          (puthash "NOSUCH" 'none orajs--described)
          (orajs--merge-objects [["HR" "EMP_API" "PACKAGE" "2026-09-01T00:00:00"]] orajs--programs)
          (orajs--put-members [["HR" "EMP_API" "HIRE" "PROCEDURE" 1]])
          (setq orajs--stamp '(5 . "2026-09-01T00:00:00")
                orajs--declined nil
                orajs--oracle-packages '("DBMS_OUTPUT"))
          (orajs--save-cache)
          (should (string-suffix-p "my_db_1-HR.eld" (orajs--cache-file)))
          (let ((orajs--container "MYPDB"))
            (should (string-suffix-p "my_db_1-HR-MYPDB.eld" (orajs--cache-file))))
          (should (= (file-modes (orajs--cache-file)) #o600))
          (orajs--reset-cache)
          (should (= (hash-table-count orajs--tables) 0))
          (should (orajs--load-disk-cache))
          (should (= (hash-table-count orajs--tables) 4))
          (should (equal (plist-get (gethash "HR.EMP" orajs--tables) :columns)
                         '(("EMPNO" . "NUMBER") ("ENAME" . "VARCHAR2") ("DEPTNO" . "NUMBER"))))
          (should (equal orajs--schemas '("HR" "SALES")))
          (should (equal orajs--dictionary-server "23.26.3.3.0"))
          (should (equal (car orajs--dictionary) '("ALL_TABLES" . "tables")))
          (should (equal (plist-get (gethash "DUAL" orajs--described) :name) "DUAL"))
          (should-not (gethash "NOSUCH" orajs--described))   ; misses are not kept
          (should (equal (plist-get (gethash "HR.EMP_API" orajs--programs) :members)
                         '(("HIRE" "PROCEDURE" 1))))
          (should (equal orajs--stamp '(5 . "2026-09-01T00:00:00")))
          (should (equal orajs--oracle-packages '("DBMS_OUTPUT")))
          ;; A cache in the old format is ignored (and rebuilt by the next sync).
          (with-temp-file (orajs--cache-file) (prin1 '(:version 1 :tables (("X.Y" :name "Y"))) (current-buffer)))
          (orajs--reset-cache)
          (should-not (orajs--load-disk-cache))
          (should (= (hash-table-count orajs--tables) 0)))
      (delete-directory orajs-cache-directory t))))

;;;; PL/SQL completion and the download limit (fake database)

(defun orajs-test--load-fake-programs ()
  (orajs--merge-objects [["HR" "EMP_API" "PACKAGE" "2026-09-01T00:00:00"]
                          ["HR" "RAISE_ALL" "PROCEDURE" "2026-09-01T00:00:00"]
                          ["SALES" "ORDER_PKG" "PACKAGE" "2026-09-01T00:00:00"]]
                         orajs--programs)
  (orajs--put-members [["HR" "EMP_API" "HIRE" "PROCEDURE" 1]
                        ["HR" "EMP_API" "SALARY_OF" "FUNCTION" 2]
                        ["SALES" "ORDER_PKG" "PLACE" "PROCEDURE" 1]])
  (setq orajs--oracle-packages '("DBMS_LOB" "DBMS_OUTPUT" "UTL_FILE")))

(ert-deftest orajs-merge-all-splits-tables-and-programs ()
  (orajs-test--load-fake-cache)
  (orajs-test--load-fake-programs)
  (pcase-let ((`(,tables . ,packages)
               (orajs--merge-all [["HR" "DEPT" "TABLE" "2026-09-01T00:00:00"]
                                  ["HR" "EMP" "TABLE" "2026-09-30T00:00:00"]      ; altered
                                  ["HR" "EMP_API" "PACKAGE" "2026-09-30T00:00:00"] ; altered
                                  ["HR" "RAISE_ALL" "PROCEDURE" "2026-09-30T00:00:00"]
                                  ["HR" "NEW_FN" "FUNCTION" "2026-09-30T00:00:00"]])))
    (should (equal tables '("HR.EMP")))
    (should (equal packages '("HR.EMP_API")))          ; standalone units have no members
    (should (gethash "HR.NEW_FN" orajs--programs))
    (should-not (gethash "SALES.ORDER_PKG" orajs--programs))
    (should-not (gethash "SALES.ORDERS" orajs--tables))))

(ert-deftest orajs-complete-plsql ()
  (orajs-test--with-fake-db
   (orajs-test--load-fake-programs)
   ;; Members after pkg.
   (orajs-test--with-sql "begin\n  emp_api.|\nend;"
     (should (equal (orajs-test--complete) '("hire" "salary_of")))
     (let ((props (nthcdr 3 (orajs-completion-at-point))))
       (should (equal (funcall (plist-get props :annotation-function) "salary_of")
                      " function (2 overloads)"))
       (should (eq (funcall (plist-get props :company-kind) "hire") 'method))))
   (orajs-test--with-sql "begin sales.order_pkg.p| end;"
     (should (equal (orajs-test--complete) '("place"))))
   ;; Bare names in PL/SQL: own units and Oracle's packages, once typed.
   (orajs-test--with-sql "begin\n  emp_a|"
     (should (equal (orajs-test--complete) '("emp_api"))))
   (orajs-test--with-sql "begin\n  dbms_|"
     (should (equal (orajs-test--complete) '("dbms_lob" "dbms_output"))))
   (orajs-test--with-sql "begin |"
     (should (null (orajs-completion-at-point))))
   ;; A ; ends a PL/SQL statement: the SELECT before it does not decide.
   (orajs-test--with-sql "begin\n  select ename into v from emp;\n  rai|"
     (should (equal (orajs-test--complete) '("raise_all"))))
   ;; In SQL: a function in the select list, once typed.
   (orajs-test--with-sql "select emp_api.salary_of(empno), e| from emp"
     (should (equal (orajs-test--complete) '("emp_api" "empno" "ename"))))
   ;; schema. lists tables, views and PL/SQL units.
   (orajs-test--with-sql "begin hr.|"
     (should (equal (orajs-test--complete) '("dept" "emp" "emp_api" "raise_all"))))))

(ert-deftest orajs-complete-oracle-package-on-demand ()
  (orajs-test--with-fake-db
   (orajs-test--load-fake-programs)
   (let ((orajs--describe-function
          (lambda (names)
            (push names orajs-test--describe-calls)
            (mapcar (lambda (n)
                      (cons n (when (equal (upcase n) "DBMS_OUTPUT")
                                '(:owner "SYS" :name "DBMS_OUTPUT" :type "PACKAGE"
                                  :members (("GET_LINE" "PROCEDURE" 1)
                                            ("PUT_LINE" "PROCEDURE" 1))))))
                    names))))
     (orajs-test--with-sql "begin dbms_output.put|"
       (should (equal (orajs-test--complete) '("put_line"))))
     (orajs-test--with-sql "begin dbms_output.|"
       (should (equal (orajs-test--complete) '("get_line" "put_line"))))
     ;; Looked up once.
     (should (equal orajs-test--describe-calls '(("dbms_output"))))
     ;; A known schema is not looked up.
     (orajs-test--with-sql "begin sales.|"
       (should (equal (orajs-test--complete) '("order_pkg" "order_v" "orders"))))
     (should (= (length orajs-test--describe-calls) 1)))))

(defmacro orajs-test--with-fake-bridge (replies &rest body)
  "Run BODY with `orajs--send' answering from REPLIES, an alist (OP . OK).
Requests are recorded in `orajs-test--sent'."
  (declare (indent 1))
  `(let ((orajs-test--sent nil)
         (orajs-cache-directory (make-temp-file "orajs-cache" t))
         (orajs--connection "fake") (orajs--server "23.26"))
     (cl-letf (((symbol-function 'orajs-connected-p) #'always)
               ((symbol-function 'orajs--send)
                (lambda (op args cb)
                  (push (cons op args) orajs-test--sent)
                  (funcall cb (cdr (assoc op ,replies)) nil))))
       (unwind-protect (progn ,@body)
         (delete-directory orajs-cache-directory t)))))
(defvar orajs-test--sent nil)

(defun orajs-test--ops () (reverse (mapcar #'car orajs-test--sent)))

(ert-deftest orajs-download-limit ()
  (let ((replies '(("summary" :count 5000 :ddl "2026-09-30T10:00:00")
                   ("objects" :schemas ["HR"] :objects [["HR" "EMP" "TABLE" "2026-09-30T10:00:00"]
                                                        ["HR" "EMP_API" "PACKAGE" "2026-09-30T10:00:00"]])
                   ("columns" :rows [["HR" "EMP" "EMPNO" "NUMBER"]])
                   ("members" :rows [["HR" "EMP_API" "HIRE" "PROCEDURE" 1]])
                   ("dictionary" :server "23.26" :rows [["DUAL" nil]] :packages ["DBMS_OUTPUT"])))
        (asked 0) (answer nil))
    (orajs-test--with-fake-bridge replies
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf asked) answer)))
        (orajs--reset-cache)
        (setq orajs--user "HR")
        ;; Over the limit, first time: asked; "no" downloads nothing.
        (orajs--sync-cache)
        (orajs-test--wait (lambda () (not orajs--syncing)) 5)
        (should (= asked 1))
        (should (equal orajs--declined 5000))
        (should-not (member "objects" (orajs-test--ops)))
        (should (= (hash-table-count orajs--tables) 0))
        ;; Connecting again: not asked again, still nothing downloaded.
        (setq orajs-test--sent nil)
        (orajs--sync-cache)
        (orajs-test--wait (lambda () (not orajs--syncing)) 5)
        (should (= asked 1))
        (should (string-match-p "5000 objects not downloaded" (orajs-test--message)))
        ;; The quiet sync after DDL never asks.
        (orajs--sync-cache 'quiet)
        (orajs-test--wait (lambda () (not orajs--syncing)) 5)
        (should (= asked 1))
        ;; The command asks again; "yes" downloads names, columns, members.
        (setq answer t orajs-test--sent nil)
        (orajs-download-schemas)
        (orajs-test--wait (lambda () (not orajs--syncing)) 5)
        (should (= asked 2))
        (should-not orajs--declined)
        (should (equal (orajs-test--ops) '("summary" "objects" "columns" "members")))
        (should (equal (plist-get (gethash "HR.EMP" orajs--tables) :columns) '(("EMPNO" . "NUMBER"))))
        (should (equal (plist-get (gethash "HR.EMP_API" orajs--programs) :members)
                       '(("HIRE" "PROCEDURE" 1))))
        ;; Downloaded once: later syncs neither ask nor re-list when nothing changed.
        (setq orajs-test--sent nil)
        (orajs--sync-cache)
        (orajs-test--wait (lambda () (not orajs--syncing)) 5)
        (should (= asked 2))
        (should (equal (orajs-test--ops) '("summary")))
        (should (string-match-p "up to date" (orajs-test--message)))))))

(ert-deftest orajs-download-under-limit-no-question ()
  (orajs-test--with-fake-bridge
      '(("summary" :count 3 :ddl "2026-09-30T10:00:00")
        ("objects" :schemas ["HR"] :objects [["HR" "EMP" "TABLE" "2026-09-30T10:00:00"]])
        ("columns" :rows [["HR" "EMP" "EMPNO" "NUMBER"]])
        ("dictionary" :server "23.26" :rows [] :packages []))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Asked"))))
      (orajs--reset-cache)
      (orajs--sync-cache)
      (orajs-test--wait (lambda () (not orajs--syncing)) 5)
      (should (equal (orajs-test--ops) '("summary" "objects" "columns" "dictionary")))
      (should (gethash "HR.EMP" orajs--tables)))))

(defun orajs-test--complete ()
  "Completions offered at point for the text before it."
  (pcase-let ((`(,beg ,end ,table . ,_) (orajs-completion-at-point)))
    (and beg
         (sort (all-completions (buffer-substring-no-properties beg end) table) #'string<))))

(ert-deftest orajs-complete-alias-columns ()
  (orajs-test--load-fake-cache)
  (orajs-test--with-sql "select e.| from hr.emp e join dept d on d.deptno = e.deptno"
    (should (equal (orajs-test--complete) '("deptno" "empno" "ename"))))
  (orajs-test--with-sql "select * from emp x, dept y where y.|"
    (should (equal (orajs-test--complete) '("deptno" "dname"))))
  ;; "join" must not be swallowed as an alias of emp.
  (orajs-test--with-sql "select * from emp join dept on dept.| "
    (should (equal (orajs-test--complete) '("deptno" "dname"))))
  (orajs-test--with-sql "select * from emp join dept on emp.EN|"
    (should (equal (orajs-test--complete) '("ENAME")))))

(ert-deftest orajs-complete-bare-names-and-case ()
  (orajs-test--load-fake-cache)
  (orajs-test--with-sql "select * from de|"
    (should (equal (orajs-test--complete) '("dept"))))
  (orajs-test--with-sql "select * from DE|"
    (should (equal (orajs-test--complete) '("DEPT"))))
  ;; Columns of tables named in the statement come without a qualifier too.
  (orajs-test--with-sql "select dn| from dept"
    (should (equal (orajs-test--complete) '("dname"))))
  (orajs-test--with-sql "select * from sa|"
    (should (equal (orajs-test--complete) '("sales")))))

(ert-deftest orajs-setup-modes ()
  (let ((auto-mode-alist auto-mode-alist) (sql-mode-hook nil))
    (orajs-setup)
    (dolist (f '("x.sql" "x.pkb" "x.pks" "x.pkh" "x.pls" "x.plb"))
      (should (eq (assoc-default f auto-mode-alist #'string-match) 'sql-mode)))
    (with-temp-buffer (sql-mode) (should orajs-mode) (should (eq sql-product 'oracle))))
  ;; A SQL buffer opened before `orajs-setup' gets orajs-mode too.
  (let ((auto-mode-alist auto-mode-alist) (sql-mode-hook nil))
    (with-temp-buffer
      (sql-mode)
      (should-not orajs-mode)
      (orajs-setup)
      (should orajs-mode)
      (should (eq (key-binding (kbd "C-c C-c")) #'orajs-execute)))))

;;;; Context and on-demand lookup (fake database)

(defvar orajs-test--describe-calls nil)

(defmacro orajs-test--with-fake-db (&rest body)
  "Fake cache plus a fake `describe' that knows DUAL and ALL_TAB_COLUMNS."
  `(let ((orajs--describe-function
          (lambda (names)
            (push names orajs-test--describe-calls)
            (mapcar (lambda (n)
                      (cons n (pcase (upcase n)
                                ((or "DUAL" "SYS.DUAL")
                                 '(:owner "SYS" :name "DUAL" :type "TABLE"
                                   :columns (("DUMMY" . "VARCHAR2"))))
                                ("ALL_TAB_COLUMNS"
                                 '(:owner "SYS" :name "ALL_TAB_COLUMNS" :type "VIEW"
                                   :columns (("OWNER" . "VARCHAR2") ("TABLE_NAME" . "VARCHAR2")
                                             ("COLUMN_NAME" . "VARCHAR2")))))))
                    names))))
     (orajs-test--load-fake-cache)
     (setq orajs--dictionary '(("ALL_TABLES" . "Description of relational tables")
                                ("ALL_TAB_COLUMNS" . "Columns of user's tables")
                                ("DUAL")))
     (setq orajs-test--describe-calls nil)
     ,@body))

(ert-deftest orajs-context ()
  (dolist (case '(("select |" . column)
                  ("select a, | from t" . column)
                  ("select * from |" . table)
                  ("select * from a, |" . table)
                  ("select * from a join |" . table)
                  ("select * from a where |" . column)
                  ("select * from a where x = 1 and |" . column)
                  ("select * from a order by |" . column)
                  ("update |" . table)
                  ("update t set |" . column)
                  ("insert into |" . table)
                  ("select from_date, | from t" . column)   ; from_date is not FROM
                  ("select 'from', | from t" . column)       ; nor is 'from'
                  ("x := |" . nil)))
    (orajs-test--with-sql (car case)
      (should (equal (cons (car case) (orajs--context (point)))
                     case)))))

(ert-deftest orajs-complete-dual-on-demand ()
  (orajs-test--with-fake-db
   (orajs-test--with-sql "select t.| from dual t"
     (should (equal (orajs-test--complete) '("dummy"))))
   (orajs-test--with-sql "select | from dual"
     (should (equal (orajs-test--complete) '("dummy"))))
   (orajs-test--with-sql "select * from dual where |"
     (should (equal (orajs-test--complete) '("dummy"))))
   (orajs-test--with-sql "select c.col| from all_tab_columns c"
     (should (equal (orajs-test--complete) '("column_name"))))
   ;; Looked up once, then remembered (hits and misses alike).
   (should (equal (length orajs-test--describe-calls) 2))
   (should (equal orajs-test--describe-calls '(("all_tab_columns") ("dual"))))))

(ert-deftest orajs-complete-batches-unknown-names ()
  (orajs-test--with-fake-db
   (orajs-test--with-sql "select | from dual d, nosuch n, emp e"
     (should (equal (orajs-test--complete) '("deptno" "dummy" "empno" "ename"))))
   ;; One round trip for both unknown names; EMP was already cached.
   (should (equal (mapcar (lambda (c) (sort (copy-sequence c) #'string<))
                          orajs-test--describe-calls)
                  '(("dual" "nosuch"))))
   (orajs-test--with-sql "select | from nosuch"
     (should (null (orajs-completion-at-point))))
   (should (= (length orajs-test--describe-calls) 1))))

(ert-deftest orajs-complete-nothing-where-nothing-fits ()
  (orajs-test--with-fake-db
   ;; No table in the statement yet: no column to offer.
   (orajs-test--with-sql "select |"
     (should (null (orajs-completion-at-point))))
   ;; Can't tell the clause and nothing typed: stay quiet.
   (orajs-test--with-sql "x := |"
     (should (null (orajs-completion-at-point))))
   ;; ... but with a prefix, offer names.
   (orajs-test--with-sql "x := em|"
     (should (equal (orajs-test--complete) '("emp"))))))

(ert-deftest orajs-complete-dictionary-after-from ()
  (orajs-test--with-fake-db
   (orajs-test--with-sql "select * from all_t|"
     (should (equal (orajs-test--complete) '("all_tab_columns" "all_tables"))))
   (orajs-test--with-sql "SELECT * FROM ALL_T|"
     (should (equal (orajs-test--complete) '("ALL_TABLES" "ALL_TAB_COLUMNS"))))
   (orajs-test--with-sql "select * from all_tables| "
     (let ((props (nthcdr 3 (orajs-completion-at-point))))
       (should (equal (funcall (plist-get props :annotation-function) "all_tables")
                      " Description of relational tables"))))
   ;; Nothing typed after FROM: own tables and schemas, not 5000 views.
   (orajs-test--with-sql "select * from |"
     (should (equal (orajs-test--complete) '("dept" "emp" "hr" "order_v" "orders" "sales"))))
   ;; Dictionary names are for FROM, not for the select list.
   (orajs-test--with-sql "select all_t| from emp"
     (should (null (orajs-test--complete))))))

;;;; JavaScript (MLE), connections, output, grid header

(ert-deftest orajs-statements-mle ()
  ;; MLE modules end at "/" like PL/SQL; their JavaScript is not parsed
  ;; as SQL, so ";", blank lines and stray quotes inside do not matter.
  (orajs-test--with-sql "create or replace mle module calc language javascript as
// don't split me; ever
export function add(a, b) {
  const s = a + b;

  return s;   // it's fine
}
/
create mle env calc_env imports ('calc' module calc);
create mle module m2 using bfile(js_dir, 'm2.js');
create or replace function add2(a number, b number) return number
as mle language javascript
{{
  // won't break either
  return a + b;
}};
/
select 'after' from dual;"
    (should (equal (mapcar (lambda (s) (nth 2 s)) (orajs--statements))
                   '(t nil nil t nil)))
    (should (equal (orajs-test--texts)
                   '("create or replace mle module calc language javascript as
// don't split me; ever
export function add(a, b) {
  const s = a + b;

  return s;   // it's fine
}"
                     "create mle env calc_env imports ('calc' module calc)"
                     "create mle module m2 using bfile(js_dir, 'm2.js')"
                     "create or replace function add2(a number, b number) return number
as mle language javascript
{{
  // won't break either
  return a + b;
}};"
                     "select 'after' from dual")))))

(ert-deftest orajs-connect-args ()
  (let ((orajs-server-output t)
        (wallet-dir (make-temp-file "orajs-wallet" t))
        (plain-dir (make-temp-file "orajs-tns" t)))
    (unwind-protect
        (progn
          (write-region "" nil (expand-file-name "ewallet.pem" wallet-dir))
          ;; Easy Connect: no directory, no wallet, no empty keys.
          (let ((spec '(:name "ez" :user "SCOTT" :service "db:1521/pdb1")))
            (should-not (orajs--wallet-p spec nil))
            (should (equal (orajs--connect-args spec "pw" nil)
                           '(:user "SCOTT" :password "pw"
                             :connectString "db:1521/pdb1" :serverOutput t))))
          ;; tnsnames.ora without a wallet: no wallet password asked.
          (should-not (orajs--wallet-p '(:tns-admin "x") plain-dir))
          ;; mTLS wallet.
          (should (orajs--wallet-p '(:tns-admin "x") wallet-dir))
          (let ((args (orajs--connect-args
                       `(:user "ADMIN" :service "db_low" :tns-admin ,wallet-dir)
                       "pw" "wpw")))
            (should (equal (plist-get args :walletLocation) (expand-file-name wallet-dir)))
            (should (equal (plist-get args :walletPassword) "wpw")))
          (let ((orajs-server-output nil))
            (should (eq (plist-get (orajs--connect-args '(:user "U") "pw" nil)
                                   :serverOutput)
                        :false)))
          ;; json-serialize accepts what we build.
          (should (json-serialize (orajs--connect-args
                                   '(:user "U" :service "s") "pw" nil))))
      (delete-directory wallet-dir t)
      (delete-directory plain-dir t))))

(ert-deftest orajs-deploy-sends-module ()
  (with-temp-buffer
    (insert "export function f() {\n  return 1;\n}\n")
    (let (sent)
      (cl-letf (((symbol-function 'orajs-connected-p) #'always)
                ((symbol-function 'orajs--send)
                 (lambda (op args cb) (setq sent (list op args cb)))))
        (orajs-deploy-module "calc")
        (should (equal (car sent) "exec"))
        (should (string-prefix-p "create or replace mle module calc language javascript as\nexport function f()"
                                 (plist-get (nth 1 sent) :sql)))
        (should (equal orajs-module-name "calc"))
        ;; An error at offset N of the DDL lands in the JavaScript.
        (let ((header (cdr (orajs--module-sql "calc" ""))))
          (goto-char (point-min))
          (funcall (nth 2 sent) nil (list :message "ORA-04045: bad"
                                          :offset (+ header 25)))
          (should (= (point) 26))
          (should (string-match-p "ORA-04045" (orajs-test--message))))
        ;; Compile errors: line and column of the JavaScript.
        (goto-char (point-min))
        (funcall (nth 2 sent)
                 '(:compileErrors (:type "MLE MODULE" :object "U.CALC"
                                   :errors [(:line 2 :position 3 :text "boom")]))
                 nil)
        ;; MLE positions count from 0 (checked against Oracle 23ai).
        (should (equal (list (line-number-at-pos) (current-column)) '(2 3)))
        (funcall (nth 2 sent) '(:output ["hello from js"]) nil)
        (should (string-match-p "deployed" (orajs-test--message)))))
    (let ((out (get-buffer "*orajs-output*")))
      (should out)
      (should (string-match-p "hello from js"
                              (with-current-buffer out (buffer-string))))
      (kill-buffer out))))

(ert-deftest orajs-grid-header-and-unload ()
  (unwind-protect
      (progn
        (orajs--show-grid '(:columns [(:name "ID" :type "NUMBER")
                                      (:name "NAME" :type "VARCHAR2")]
                            :rows [["1" "x"] ["2" nil]] :more nil)
                          "select" 0.1)
        (with-current-buffer "*orajs-results*"
          (should (advice-member-p #'orajs--header-line 'vtable--set-header-line))
          ;; Redrawn with :align-to positions, not vtable's padding.
          (should (text-property-search-forward 'display)) ; buffer has a table
          (should (string-match-p "ID.*NAME" (format "%s" header-line-format)))
          (should (get-text-property 0 'display header-line-format)))
        ;; What `unload-feature' calls.
        (orajs-unload-function)
        (should-not (advice-member-p #'orajs--header-line 'vtable--set-header-line)))
    (when (get-buffer "*orajs-results*") (kill-buffer "*orajs-results*"))))

;;;; Compile error list and next-error (no database)

(ert-deftest orajs-compile-errors-list ()
  (let ((src (generate-new-buffer "unit.pkb")))
    (unwind-protect
        (with-current-buffer src
          (insert "-- header\ncreate or replace package body p as\n  procedure a is begin x; end;\n"
                  "  procedure b is begin y; end;\nend;\n/\n")
          (let ((beg (save-excursion (goto-char (point-min)) (forward-line 1) (point))))
            (orajs--show-compile-errors
             '(:type "PACKAGE BODY" :object "HR.P"
               :errors [(:line 2 :position 24 :attribute "ERROR" :text "PLS-00201: identifier 'X' must be declared")
                        (:line 2 :position 24 :attribute "ERROR" :text "PL/SQL: Statement ignored")
                        (:line 3 :position 24 :attribute "WARNING" :text "PLS-06010: y\nsecond line")])
             src beg "PACKAGE BODY HR.P")
            ;; Point on the first error, summary in the echo area.
            (should (eq (current-buffer) src))
            (should (looking-at-p "x; end"))
            (should (string-match-p "\\`3 errors; line 2: PLS-00201" (orajs-test--message)))
            (with-current-buffer "*orajs-errors*"
              (should (string-match-p "\\`PACKAGE BODY HR.P: 3 errors\n    2:24  PLS-00201: identifier 'X' must be declared\n    2:24  PL/SQL: Statement ignored\n    3:24  PLS-06010: y\n\\'"
                                      (buffer-substring-no-properties (point-min) (point-max)))))
            ;; next-error / previous-error, from the source buffer.
            (next-error)
            (should (looking-at-p "x; end"))
            ;; The list shows which error this is (next-error's own message
            ;; replaces the echo area).
            (with-current-buffer "*orajs-errors*"
              (should (string-match-p "Statement ignored"
                                      (buffer-substring (line-beginning-position) (line-end-position))))
              (should (= (marker-position overlay-arrow-position) (line-beginning-position))))
            ;; Markers follow edits above the error.
            (save-excursion (goto-char (point-min)) (insert "-- another line\n"))
            (next-error)
            (should (looking-at-p "y; end"))
            (should-error (next-error) :type 'user-error)
            (previous-error)
            (previous-error)
            (should (looking-at-p "x; end"))
            ;; RET in the list.
            (with-current-buffer "*orajs-errors*"
              (goto-char (point-min)) (forward-line 3)
              (orajs-goto-error))
            (should (looking-at-p "y; end"))
            (should (string-match-p "second line" (orajs-test--message)))  ; RET: full text
            ;; A clean compile empties the list and detaches next-error.
            (orajs--clear-compile-errors)
            (should-not next-error-last-buffer)
            (with-current-buffer "*orajs-errors*"
              (should (string-match-p "No compile errors" (buffer-string))))))
      (kill-buffer src)
      (when (get-buffer "*orajs-errors*") (kill-buffer "*orajs-errors*")))))

;;;; Jump to definition (no database)

(ert-deftest orajs-xref-identifier-at-point ()
  (dolist (case '(("select e.en|ame from emp e" . "e.ename")
                  ("begin emp_a|pi.hire(1); end;" . "emp_api")
                  ("begin emp_api.hi|re(1); end;" . "emp_api.hire")
                  ("begin hr.emp_api.hi|re; end;" . "hr.emp_api.hire")
                  ("select * from |dual" . "dual")
                  ("select * from \"Mixed\".|t" . "\"Mixed\".t")))
    (orajs-test--with-sql (car case)
      (orajs-mode 1)
      (let ((id (xref-backend-identifier-at-point 'orajs)))
        (should (equal (substring-no-properties id) (cdr case)))
        (should (markerp (get-text-property 0 'orajs-marker id)))))))

(ert-deftest orajs-recreatable-source ()
  (should (equal (orajs--recreatable-source "package body           emp_api as\n  x;\nend;" "HR" "EMP_API")
                 "CREATE OR REPLACE package body HR.EMP_API as\n  x;\nend;\n/\n"))
  ;; Owner already written, quoted names, mixed case.
  (should (equal (orajs--recreatable-source "PROCEDURE \"Hr\".\"doIt\" IS\nBEGIN NULL; END;\n" "Hr" "doIt")
                 "CREATE OR REPLACE PROCEDURE \"Hr\".\"doIt\" IS\nBEGIN NULL; END;\n/\n"))
  (should (equal (orajs--recreatable-source "type body t as\nend;\n" "HR" "T")
                 "CREATE OR REPLACE type body HR.T as\nend;\n/\n"))
  (should (equal (orajs--recreatable-source "trigger trg\n before insert on t\nbegin null; end;" "HR" "TRG")
                 "CREATE OR REPLACE trigger HR.TRG\n before insert on t\nbegin null; end;\n/\n")))

(ert-deftest orajs-member-and-column-positions ()
  (with-temp-buffer
    (insert "CREATE OR REPLACE package body HR.P as\n"
            "  -- procedure hire is the old name\n"
            "  procedure hire(n varchar2) is begin null; end;\n"
            "  function sal_of(e number) return number is begin return 1; end;\n"
            "  FUNCTION SAL_OF(e varchar2) return number is begin return 2; end;\n"
            "  procedure hired is begin null; end;\n"
            "end;\n/\n")
    (let ((sql-mode-hook nil)) (sql-mode))
    (let ((hire (orajs--member-positions (current-buffer) "HIRE"))
          (sal (orajs--member-positions (current-buffer) "sal_of")))
      (should (= (length hire) 1))                  ; not the comment, not HIRED
      (goto-char (car hire)) (should (looking-at-p "procedure hire("))
      (should (= (length sal) 2))                   ; both overloads
      (goto-char (cadr sal)) (should (looking-at-p "FUNCTION SAL_OF(e varchar2)"))))
  (with-temp-buffer
    (insert "CREATE TABLE \"HR\".\"ENAME\"\n   (\t\"EMPNO\" NUMBER,\n\t\"ENAME\" VARCHAR2(20)\n   );\n")
    (goto-char (orajs--column-position (current-buffer) "ename"))
    (should (looking-at-p "\"ENAME\" VARCHAR2"))       ; the column, not the table
    (should-not (orajs--column-position (current-buffer) "nope"))))

;;;; Jump to definition through TAGS (no database)

(defconst orajs-test--tags-dir
  (expand-file-name "tags/" (file-name-directory (or load-file-name buffer-file-name)))
  "SQL files and the TAGS file Universal Ctags made of them.")

(defmacro orajs-test--in-tags-dir (dir &rest body)
  "BODY with `default-directory' DIR, then forget its TAGS and buffers."
  (declare (indent 1))
  `(let ((default-directory ,dir)
         (tags-file-name nil) (tags-table-list nil))
     (unwind-protect (progn ,@body)
       (setq tags-file-name nil tags-table-list nil)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p ,dir (buffer-file-name b)))
           (kill-buffer b)))
       (when (get-buffer "TAGS") (kill-buffer "TAGS")))))

(defun orajs-test--tag-defs (text)
  "Tag definitions for the identifier at \"|\" in TEXT: (FILE . LINE) each."
  (orajs-test--with-sql text
    (orajs-mode 1)
    (mapcar (lambda (x)
              (let ((loc (xref-item-location x)))
                (cons (file-name-nondirectory (xref-location-group loc))
                      (xref-location-line loc))))
            (xref-backend-definitions 'orajs (xref-backend-identifier-at-point 'orajs)))))

(defun orajs-test--check-tags ()
  "Check M-. against the TAGS file of the files in `orajs-test--tags-dir'."
  (orajs-test--load-fake-cache)                  ; HR.EMP, for the alias
  ;; Not connected: all of these come from TAGS.
  (should-not (orajs-connected-p))
  (should (equal (orajs-test--tag-defs "begin emp_api.hi|re('x'); end;") '(("emp_api.pkb" . 3))))
  (should (equal (orajs-test--tag-defs "begin other_api.hi|re; end;") '(("other_api.pkb" . 2))))
  (should (equal (orajs-test--tag-defs "begin hr.emp_api.hi|re('x'); end;") '(("emp_api.pkb" . 3))))
  (should (equal (sort (mapcar #'car (orajs-test--tag-defs "begin hi|re; end;")) #'string<)
                 '("emp_api.pkb" "other_api.pkb")))
  (should (equal (orajs-test--tag-defs "begin emp_a|pi.hire('x'); end;") '(("emp_api.pkb" . 1))))
  (should (equal (orajs-test--tag-defs "select e.ena|me from emp e") '(("schema.sql" . 3))))
  (should (equal (orajs-test--tag-defs "select * from emp_|v") '(("schema.sql" . 5))))
  ;; Not in TAGS and not connected: the database is needed.
  (should-error (orajs-test--tag-defs "select * from no_such_th|ing") :type 'user-error))

(ert-deftest orajs-tags-first ()
  ;; The TAGS file in the repository: no ctags needed.
  (orajs-test--in-tags-dir orajs-test--tags-dir
    (orajs-test--check-tags)))

(ert-deftest orajs-make-tags-with-universal-ctags ()
  (skip-unless (orajs--ctags))
  (let ((dir (file-name-as-directory (make-temp-file "orajs-tags" t))))
    (unwind-protect
        (orajs-test--in-tags-dir dir
          (dolist (f '("emp_api.pkb" "other_api.pkb" "schema.sql"))
            (copy-file (expand-file-name f orajs-test--tags-dir) f))
          (orajs-make-tags dir)
          (should (file-exists-p "TAGS"))
          (orajs-test--check-tags))
      (delete-directory dir t))))

(ert-deftest orajs-make-tags-without-universal-ctags ()
  (let ((dir (file-name-as-directory (make-temp-file "orajs-tags" t))))
    (unwind-protect
        (let ((default-directory dir))
          (let ((exec-path nil) (orajs-ctags-program nil))
            (should (string-match-p "none found"
                                    (cadr (should-error (orajs-make-tags dir)
                                                        :type 'user-error)))))
          (let ((orajs-ctags-program "orajs-no-such-ctags"))
            (should (string-match-p "orajs-no-such-ctags. is not it"
                                    (cadr (should-error (orajs-make-tags dir)
                                                        :type 'user-error)))))
          (should-not (file-exists-p "TAGS")))
      (delete-directory dir t))))

;;;; MLE error positions and SET SERVEROUTPUT (no database)

(ert-deftest orajs-mle-error-position ()
  ;; As Oracle 23ai numbers them: from the first non-blank after AS,
  ;; columns from 0.  (Probed: "as\n", "as\n\n", "as " all store the same.)
  (dolist (case '(("create mle module m language javascript as\nconst a = 1;\nreturn 1 +;" 2 0 "return")
                  ("create mle module m language javascript as\n\n  const a = 1;\nreturn 1 +;" 2 0 "return")
                  ("create mle module m language javascript as   let x = +;" 1 9 ";")
                  ("create or replace mle module mass_calc language javascript AS\nfoo;\n  bar +;" 2 7 ";")))
    (with-temp-buffer
      (insert (nth 0 case))
      (let ((pos (orajs--mle-error-position (orajs--mle-body-start (point-min))
                                             (nth 1 case) (nth 2 case))))
        (goto-char pos)
        (should (looking-at-p (regexp-quote (nth 3 case)))))))
  ;; A deployed buffer: blank lines before the code do not count.
  (with-temp-buffer
    (insert "\n\nexport function f() {\n  return 1 +;\n}\n")
    (goto-char (orajs--mle-error-position (point-min) 2 12))
    (should (looking-at-p ";"))))

;;;; Live: orajs.el, the real bridge and a real database

(defun orajs-test--live-p ()
  "Non-nil if a live database is configured and not past ORAJS_TEST_CUTOFF."
  (let ((cutoff (getenv "ORAJS_TEST_CUTOFF")))
    (and (getenv "ORAJS_SERVICE")
         (not (and cutoff (string> (format-time-string "%F") cutoff))))))

(defun orajs-test--live-spec ()
  "The live connection from the environment, as in `orajs-connections'."
  (let (spec)
    (pcase-dolist (`(,key . ,var) '((:user . "ORAJS_USER")
                                    (:service . "ORAJS_SERVICE")
                                    (:tns-admin . "ORAJS_TNS_ADMIN")
                                    (:password-file . "ORAJS_PASSWORD_FILE")
                                    (:wallet-password-file . "ORAJS_WALLET_PASSWORD_FILE")))
      (let ((value (getenv var)))
        (when (and value (not (string-empty-p value)))
          (setq spec (plist-put spec key value)))))
    spec))

(defmacro orajs-test--live (&rest body)
  "Connect with `orajs-connect', let the schema cache sync, run BODY, disconnect."
  (declare (indent 0))
  `(progn
     (skip-unless (orajs-test--live-p))
     (let ((orajs-connections (list (cons "live" (orajs-test--live-spec))))
           (orajs-cache-directory (make-temp-file "orajs-cache" t))
           (orajs-download-limit most-positive-fixnum))
       (unwind-protect
           (progn
             (setq orajs-test--message nil)
             (orajs-connect "live")
             (orajs-test--wait (lambda () (or (orajs-connected-p)
                                              (string-match-p "failed" (orajs-test--message))))
                               60)
             (should (orajs-connected-p))
             (orajs-test--wait (lambda () (not orajs--syncing)) 120)
             ,@body)
         (orajs-disconnect)
         (delete-directory orajs-cache-directory t)))))

(defun orajs-test--live-exec (sql)
  "Run SQL on the live connection; return the bridge's reply."
  (orajs--request-sync "exec" (list :sql sql) 60))

(ert-deftest orajs-live-connect-and-cache ()
  (orajs-test--live
    (should (equal orajs--user (upcase (getenv "ORAJS_USER"))))
    (should (string-match-p "\\`[0-9]+\\." orajs--server))
    ;; Oracle's dictionary came down for completion.
    (should (assoc "DUAL" orajs--dictionary))
    (should (assoc "ALL_TAB_COLUMNS" orajs--dictionary))))

(ert-deftest orajs-live-execute ()
  (orajs-test--live
    ;; A query: rows in the grid.
    (orajs-test--with-sql "select level n from dual connect by level <= 3|"
      (orajs-execute)
      (orajs-test--wait (lambda () (string-match-p "rows? (\\|ORA-" (orajs-test--message))) 30)
      (should (string-match-p "\\`orajs: 3 rows" (orajs-test--message))))
    (with-current-buffer "*orajs-results*"
      (should (equal orajs--grid-rows '(["1"] ["2"] ["3"]))))
    ;; An error: Oracle's message, point where Oracle says.
    (orajs-test--with-sql "select * from no_such_table_xyz|"
      (orajs-execute)
      (orajs-test--wait (lambda () (string-match-p "ORA-" (orajs-test--message))) 30)
      (should (string-match-p "ORA-00942" (orajs-test--message)))
      (should (looking-at-p "no_such_table_xyz")))))

(ert-deftest orajs-live-complete-on-demand ()
  (orajs-test--live
    ;; Not in the user's schema: described by the database through synonyms.
    (orajs-test--with-sql "select | from dual"
      (should (equal (orajs-test--complete) '("dummy"))))
    (orajs-test--with-sql "select c.col| from all_tab_columns c"
      (should (member "column_name" (orajs-test--complete))))))

;;;; Test support

;; Batch Emacs keeps no echo area, so remember the last message.
(defvar orajs-test--message nil)
(advice-add 'message :after
            (lambda (fmt &rest args)
              (when fmt (setq orajs-test--message (apply #'format-message fmt args)))))
(defun orajs-test--message () (or orajs-test--message ""))

(defun orajs-test--wait (pred &optional secs)
  (with-timeout ((or secs 60) (error "Timed out waiting; last message %S" orajs-test--message))
    (while (not (funcall pred)) (accept-process-output nil 0.1))))

;;; orajs-test.el ends here
