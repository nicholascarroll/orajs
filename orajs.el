;;; orajs.el --- Oracle SQL worksheet: results grid, completion  -*- lexical-binding: t; -*-

;; Author: Nick Carroll <nicholascarroll@tutanota.com>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/nicholascarroll/orajs
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: sql, languages, tools
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A minor mode for `sql-mode' buffers (.sql, and .pks/.pkb/.pkh/.pls/.plb
;; package files) that talks to Oracle through a small Node.js bridge
;; (orajs-bridge.js, node-oracledb Thin mode: no Instant Client needed).
;;
;;   C-c C-c   run the statement at point (or the region); queries go to a
;;             vtable grid in *orajs-results*, 100 rows at a time
;;
;; The other commands live in `orajs-command-map', which you bind to a
;; prefix of your choice (below it is C-c o):
;;
;;   c  connect (then the schema cache is synced in the background)
;;   s  download / sync the names completion uses (asks above
;;      `orajs-download-limit' objects); r does the same
;;   k  cancel the running statement
;;   d  disconnect
;;   o  show DBMS_OUTPUT (and JavaScript console.log) in *orajs-output*
;;   t  build a TAGS file of your SQL files, searched first on M-.
;;
;; Jump to definition (M-., back with M-,) finds the name at point in the
;; TAGS file if there is one, else in the database (source, or DDL).
;; M-x orajs-find-object opens one from the database, from any buffer;
;; with % in the name it searches, and you choose among the matches.
;; An MLE module (Oracle 23ai) opens as JavaScript in `js-mode', with its
;; CREATE statement shown above the code: C-c C-e edits that statement,
;; C-c C-c compiles.  Saved to a .sql file it becomes the whole script
;; (CREATE ... AS, the JavaScript, /); saved to a .js file, just the code.
;;
;; Completion (`completion-at-point', so company picks it up through
;; `company-capf'): table, view, schema and PL/SQL unit names, by clause;
;; after "x." the columns of the table or alias x, the procedures and
;; functions of package x, or the objects of schema x.
;;
;; Needs Node.js 18 or later (and npm).  The Oracle driver, node-oracledb,
;; is installed by npm into `orajs-driver-directory' the first time you
;; connect (or with M-x orajs-install-driver), so package upgrades keep it.
;;
;; Setup:
;;
;;   (require 'orajs)
;;   (orajs-setup)
;;   (keymap-global-set "C-c o" 'orajs-command-map)
;;   (setq orajs-connections
;;         '(("mydb" :user "SCOTT" :service "mydb_low"
;;            :tns-admin "~/wallets/mydb")))
;;
;; Passwords come from :password-file / :wallet-password-file if given, else
;; auth-source (machine = connection name, login = user, and login =
;; "wallet" for the wallet password), else a prompt.  Statements run in one
;; session with autocommit off: COMMIT is yours to type.

;;; Code:

(require 'sql)
(require 'vtable)
(require 'cl-lib)
(require 'subr-x)
(require 'auth-source)
(require 'pulse)
(require 'xref)
(require 'project)
(require 'map)

(defgroup orajs nil
  "Oracle SQL worksheet for `sql-mode'."
  :group 'sql
  :prefix "orajs-")

(defcustom orajs-connections nil
  "Named Oracle connections.
An alist of (NAME . PLIST).  PLIST keys:
  :user                  database user
  :service               TNS alias from tnsnames.ora (e.g. \"mydb_low\")
                         or an Easy Connect string (\"host:1521/service\")
  :tns-admin             optional: directory holding tnsnames.ora and,
                         for mTLS, the wallet (ewallet.pem)
  :password-file         optional file holding the password
  :wallet-password-file  optional file holding the wallet password
                         (asked for only when there is an ewallet.pem)"
  :type '(alist :key-type string :value-type plist))

(defcustom orajs-node-program "node"
  "The Node.js executable (version 18 or later) used to run the bridge."
  :type 'string)

(defcustom orajs-npm-program "npm"
  "The npm executable used by `orajs-install-driver'."
  :type 'string)

(defcustom orajs-driver-directory (locate-user-emacs-file "orajs-driver/")
  "Directory whose node_modules holds node-oracledb.
`orajs-install-driver' installs it here."
  :type 'directory)

(defcustom orajs-page-size 100
  "Rows fetched per page into the results grid."
  :type 'natnum)

(defcustom orajs-max-column-width 40
  "Widest a results grid column starts out, in characters."
  :type 'natnum)

(defcustom orajs-completion-case 'match
  "Letter case of inserted completions.
`match' follows the typed prefix (lower case when it has no upper-case
letters), `upper' and `lower' force a case."
  :type '(choice (const match) (const upper) (const lower)))

(defcustom orajs-cache-directory (locate-user-emacs-file "orajs-cache/")
  "Where each connection's schema cache is kept between sessions.
One file per connection and user; names only, no data.  Safe to delete."
  :type 'directory)

(defcustom orajs-server-output t
  "Non-nil to show DBMS_OUTPUT after each statement, in *orajs-output*.
This includes `console.log' from JavaScript (MLE) code.  Read when
connecting; costs one extra round trip per statement."
  :type 'boolean)

(defconst orajs--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Where orajs.el and orajs-bridge.js live.")

;;;; Connection state (one connection per Emacs)

(defvar orajs--process nil "The bridge process.")
(defvar orajs--callbacks (make-hash-table) "Request id -> callback.")
(defvar orajs--next-id 0)
(defvar orajs--partial "" "Bridge output not yet ended by a newline.")
(defvar orajs--connection nil "Name of the connected entry in `orajs-connections'.")
(defvar orajs--user nil "Database user of the connection, upper case.")
(defvar orajs--server nil "Database version of the connection, e.g. \"23.26.3.3.0\".")
(defvar orajs--container nil "The connected database's own name (CON_NAME).")
(defvar orajs--syncing nil "Non-nil while the schema cache is being brought up to date.")
(defvar orajs--sync-quiet nil
  "Non-nil while a sync runs that reports only failures (the one after DDL).")

;;;; Schema cache

(defvar orajs--tables (make-hash-table :test #'equal)
  "\"OWNER.TABLE\" -> plist (:owner :name :type :ddl :columns ((NAME . TYPE) ...)).
Every table and view of the user schemas; :ddl is its LAST_DDL_TIME.")
(defvar orajs--schemas nil "Schema names worth completing.")
(defvar orajs--dictionary nil
  "Data dictionary views: list of (NAME . DESCRIPTION), e.g. ALL_TABLES, V$SESSION.")
(defvar orajs--dictionary-server nil
  "Database version `orajs--dictionary' (and `orajs--described') came from.")
(defvar orajs--described (make-hash-table :test #'equal)
  "Tables looked up on demand: upper-cased name as written -> entry, or `none'.")
(defvar orajs--describe-function #'orajs--describe-remote
  "Function that looks up table names in the database.
It takes a list of names as written and returns an alist
\(NAME . ENTRY-OR-NIL); ENTRY as in `orajs--tables'.")

;;;; Bridge process

(defun orajs--start ()
  "Start the bridge process."
  (let ((script (expand-file-name "orajs-bridge.js" orajs--directory))
        ;; The driver: next to the script in a development checkout, else in
        ;; `orajs-driver-directory' (NODE_PATH is searched after the former).
        (process-environment
         (cons (concat "NODE_PATH="
                       (expand-file-name "node_modules" orajs-driver-directory))
               process-environment)))
    ;; Each bridge gets its own callback table, so a previous bridge's
    ;; late sentinel fails only its own requests (see `orajs--sentinel').
    (setq orajs--partial ""
          orajs--callbacks (make-hash-table)
          orajs--process
          (make-process
           :name "orajs"
           :command (list orajs-node-program script)
           :connection-type 'pipe
           :coding 'utf-8
           :noquery t
           :stderr (get-buffer-create " *orajs-stderr*")
           :filter #'orajs--filter
           :sentinel #'orajs--sentinel))
    (process-put orajs--process 'orajs-callbacks orajs--callbacks)
    orajs--process))

(defun orajs--filter (proc output)
  "Split bridge OUTPUT into lines and dispatch each reply.
Output from a bridge PROC that has since been replaced is ignored."
  (when (eq proc orajs--process)
    (setq orajs--partial (concat orajs--partial output))
    (let ((lines (split-string orajs--partial "\n")))
      (setq orajs--partial (car (last lines)))
      (dolist (line (butlast lines))
        (unless (string-empty-p line)
          (orajs--dispatch
           (json-parse-string line :object-type 'plist
                              :null-object nil :false-object nil)))))))

(defun orajs--dispatch (reply)
  "Hand REPLY to the callback waiting for its id."
  (let* ((id (plist-get reply :id))
         (cb (gethash id orajs--callbacks)))
    (remhash id orajs--callbacks)
    (when cb
      (condition-case err
          (funcall cb (plist-get reply :ok) (plist-get reply :error))
        (error (message "orajs: %s" (error-message-string err)))))))

(defun orajs--sentinel (proc _event)
  "Clean up when the bridge PROC exits.
Fail PROC's pending requests.  Reset the connection state only if PROC
is still the current bridge: Emacs may run the sentinel of a bridge that
`orajs-disconnect' stopped after `orajs-connect' has started the next
one, and that must not touch the new connection."
  (unless (process-live-p proc)
    (let ((pending (or (process-get proc 'orajs-callbacks)
                       (make-hash-table))))
      (process-put proc 'orajs-callbacks nil)
      (when (eq proc orajs--process)
        (setq orajs--callbacks (make-hash-table)
              orajs--process nil
              orajs--connection nil
              orajs--user nil))
      (maphash (lambda (_id cb)
                 (ignore-errors (funcall cb nil '(:message "bridge exited"))))
               pending))
    (force-mode-line-update t)))

(defun orajs--send (op args callback)
  "Send OP with ARGS (a plist) to the bridge; call CALLBACK with (OK ERROR)."
  (unless (process-live-p orajs--process)
    (user-error "Not connected; use M-x orajs-connect"))
  (let ((id (cl-incf orajs--next-id)))
    (puthash id callback orajs--callbacks)
    (process-send-string
     orajs--process
     (concat (json-serialize (append (list :id id :op op) args)) "\n"))
    id))

(defun orajs--request-sync (op args &optional timeout)
  "Send OP with ARGS and wait up to TIMEOUT seconds for the reply.
Return OK, or signal an error.  For tests and scripting."
  (let (done ok err)
    (orajs--send op args (lambda (o e) (setq done t ok o err e)))
    (with-timeout ((or timeout 60) (error "orajs: %s timed out" op))
      (while (not done)
        (accept-process-output orajs--process 0.1)))
    (when err (error "orajs: %s" (plist-get err :message)))
    ok))

(defun orajs-connected-p ()
  "Non-nil when a database connection is open."
  (and orajs--connection (process-live-p orajs--process)))

;;;; Installing the driver

(defun orajs--driver-installed-p ()
  "Non-nil if node-oracledb is where the bridge will look for it."
  (seq-some (lambda (dir)
              (file-exists-p (expand-file-name "node_modules/oracledb/package.json" dir)))
            (list orajs--directory orajs-driver-directory)))

(defun orajs--driver-version ()
  "The node-oracledb version range the package asks for, from package.json."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "package.json" orajs--directory))
    (let ((deps (plist-get (json-parse-buffer :object-type 'plist) :dependencies)))
      (or (plist-get deps :oracledb) (error "No oracledb dependency in package.json")))))

(defun orajs--check-node ()
  "Signal a `user-error' unless Node.js 18+ and npm are available."
  (unless (executable-find orajs-node-program)
    (user-error "Node.js 18 or later is needed by orajs: `%s' not found (see `orajs-node-program')"
                orajs-node-program))
  (let ((major (with-temp-buffer
                 (call-process orajs-node-program nil t nil "-p" "process.versions.node")
                 (string-to-number (buffer-string)))))
    (when (< major 18)
      (user-error "Node.js 18 or later is needed by orajs; `%s' is version %d"
                  orajs-node-program major)))
  (unless (executable-find orajs-npm-program)
    (user-error "The npm program installs the orajs Oracle driver: `%s' not found"
                orajs-npm-program)))

;;;###autoload
(defun orajs-install-driver ()
  "Install (or update) node-oracledb into `orajs-driver-directory' with npm.
The version is the one in the package's package.json.  Output goes to
the *orajs-install* buffer, which is shown if npm fails."
  (interactive)
  (orajs--check-node)
  (let* ((dir (file-name-as-directory (expand-file-name orajs-driver-directory)))
         (spec (concat "oracledb@" (orajs--driver-version)))
         (buf (get-buffer-create "*orajs-install*")))
    (make-directory dir t)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "$ %s install --prefix %s %s\n\n" orajs-npm-program dir spec))))
    (message "orajs: installing %s into %s..." spec dir)
    (let ((status (call-process orajs-npm-program nil buf nil
                                "install" "--prefix" dir "--no-audit" "--no-fund"
                                "--omit=dev" spec)))
      (unless (and (eql status 0) (orajs--driver-installed-p))
        (display-buffer buf)
        (user-error "Installing the Oracle driver failed (npm exit %s); see *orajs-install*" status))
      (message "orajs: installed %s into %s" spec dir))))

(defun orajs--ensure-driver ()
  "Offer to install node-oracledb if it is missing; signal if declined."
  (unless (orajs--driver-installed-p)
    (if (y-or-n-p "Install the orajs Oracle driver now (node-oracledb, ~5 MB, via npm)? ")
        (orajs-install-driver)
      (user-error "Not connecting: the Oracle driver is not installed (M-x orajs-install-driver)"))))

;;;; Connecting

(defun orajs--secret (spec file-key auth-user prompt)
  "A secret for connection SPEC.
From the file under FILE-KEY, else auth-source with login AUTH-USER on
the connection's name, else PROMPT."
  (let ((file (plist-get spec file-key)))
    (cond
     (file (with-temp-buffer
             (insert-file-contents (expand-file-name file))
             (string-trim (buffer-string))))
     ((when-let* ((found (car (auth-source-search
                               :host (plist-get spec :name) :user auth-user
                               :max 1)))
                  (secret (plist-get found :secret)))
        (if (functionp secret) (funcall secret) secret)))
     (t (read-passwd prompt)))))

(defun orajs--wallet-p (spec tns)
  "Return non-nil if connection SPEC has an mTLS wallet in directory TNS."
  (or (plist-get spec :wallet-password-file)
      (and tns (file-exists-p (expand-file-name "ewallet.pem" tns)))))

(defun orajs--connect-args (spec password wallet)
  "Bridge arguments to open connection SPEC with PASSWORD and WALLET password.
Keys without a value are left out (JSON has no use for them)."
  (let ((tns (when-let* ((dir (plist-get spec :tns-admin)))
               (expand-file-name dir)))
        (args nil))
    (dolist (kv `((:user . ,(plist-get spec :user))
                  (:password . ,password)
                  (:connectString . ,(plist-get spec :service))
                  (:configDir . ,tns)
                  (:walletLocation . ,(and wallet tns))
                  (:walletPassword . ,wallet)
                  (:serverOutput . ,(if orajs-server-output t :false))))
      (when (cdr kv) (setq args (append args (list (car kv) (cdr kv))))))
    args))

;;;###autoload
(defun orajs-connect (name)
  "Connect to the connection NAME from `orajs-connections'."
  (interactive
   (list (completing-read "Oracle connection: " orajs-connections nil t)))
  (unless (assoc name orajs-connections)
    (user-error "No connection named %s in `orajs-connections'" name))
  ;; Before any password prompt: no point asking if we cannot connect.
  (orajs--ensure-driver)
  (let* ((spec (append (list :name name) (cdr (assoc name orajs-connections))))
         (user (plist-get spec :user))
         (tns (when-let* ((dir (plist-get spec :tns-admin)))
                (expand-file-name dir)))
         (password (orajs--secret spec :password-file user
                                   (format "Password for %s@%s: " user name)))
         ;; Only mTLS wallets (ewallet.pem) have a password; a TLS or plain
         ;; connection (Easy Connect, tnsnames.ora only) has none.
         (wallet (and (orajs--wallet-p spec tns)
                      (orajs--secret spec :wallet-password-file "wallet"
                                     (format "Wallet password for %s: " name)))))
    (orajs-disconnect)
    (orajs--start)
    (message "orajs: connecting to %s..." name)
    (orajs--send
     "connect"
     (orajs--connect-args spec password wallet)
     (lambda (ok err)
       (if err
           (progn (orajs-disconnect)
                  (message "orajs: connect to %s failed: %s"
                           name (plist-get err :message)))
         (setq orajs--connection name
               orajs--user (plist-get ok :user)
               orajs--server (plist-get ok :server)
               orajs--container (plist-get ok :container))
         (orajs--reset-cache)
         (let ((cached (orajs--load-disk-cache)))
           (message "orajs: connected to %s as %s%s" name orajs--user
                    (if cached
                        (format " (%d tables/views from cache; checking for changes)"
                                (hash-table-count orajs--tables))
                      "; loading schema names...")))
         (orajs--sync-cache))))))

(defun orajs-disconnect ()
  "Close the connection (uncommitted work is rolled back)."
  (interactive)
  (when (process-live-p orajs--process)
    (ignore-errors (process-send-eof orajs--process))
    (let ((proc orajs--process))
      (with-timeout (5 (delete-process proc))
        (while (process-live-p proc)
          (accept-process-output proc 0.1)))))
  (setq orajs--process nil orajs--connection nil orajs--user nil
        orajs--container nil)
  (force-mode-line-update t))

(defun orajs-cancel ()
  "Interrupt the running statement."
  (interactive)
  (orajs--send "break" nil (lambda (&rest _) nil)))

;;;; Schema cache

;;;; What a connection's schema cache holds

(defvar orajs--programs (make-hash-table :test #'equal)
  "\"OWNER.NAME\" -> plist (:owner :name :type :ddl :members) of PL/SQL units.
TYPE is PACKAGE, PROCEDURE or FUNCTION; a package's :members are
\(NAME KIND OVERLOADS) with KIND \"FUNCTION\" or \"PROCEDURE\".")
(defvar orajs--oracle-packages nil
  "Names of Oracle's packages (public synonyms: DBMS_OUTPUT, UTL_FILE ...).")
(defvar orajs--stamp nil
  "(COUNT . DDL-TIME) of the user schemas when the cache was last synced.")
(defvar orajs--declined nil
  "COUNT of objects the user declined to download for this connection.")

(defun orajs--reset-cache ()
  "Forget all schema names (in memory; the disk cache is kept)."
  (setq orajs--tables (make-hash-table :test #'equal)
        orajs--programs (make-hash-table :test #'equal)
        orajs--schemas nil
        orajs--dictionary nil
        orajs--oracle-packages nil
        orajs--dictionary-server nil
        orajs--stamp nil
        orajs--declined nil)
  (clrhash orajs--described))

(defun orajs--downloaded-p ()
  "Non-nil if this connection's schemas have been downloaded (and not declined)."
  (and orajs--stamp t))

;;;###autoload
(defun orajs-download-schemas (&optional full)
  "Download (or bring up to date) the names orajs completes, for this connection.
Every table, view and PL/SQL unit of the schemas that are not Oracle's,
with their columns and package members.  Above `orajs-download-limit'
objects you are asked first; if you decline, names are still looked up
one at a time as you use them.  Later syncs fetch only what changed
\(by LAST_DDL_TIME).  With prefix argument FULL, throw the cache away
and fetch everything, including the data dictionary names."
  (interactive "P")
  (unless (orajs-connected-p) (user-error "Not connected; use M-x orajs-connect"))
  (when full (orajs--reset-cache))
  (orajs--sync-cache nil 'ask))

(defalias 'orajs-refresh-cache #'orajs-download-schemas)

;;;; Incremental sync

(defconst orajs--table-types '("TABLE" "VIEW" "MATERIALIZED VIEW"))

(defun orajs--merge-objects (objects &optional hash)
  "Update HASH (default `orajs--tables') from OBJECTS, rows [OWNER NAME TYPE DDL].
Entries not listed are dropped.  Return the keys whose details (columns,
members) must be (re)fetched: new ones and ones whose DDL time changed."
  (let ((hash (or hash orajs--tables))
        (seen (make-hash-table :test #'equal))
        changed)
    (seq-doseq (o objects)
      (let* ((key (concat (aref o 0) "." (aref o 1)))
             (e (gethash key hash)))
        (puthash key t seen)
        (cond
         ((null e)
          (puthash key (list :owner (aref o 0) :name (aref o 1) :type (aref o 2)
                             :ddl (aref o 3) :columns nil :members nil)
                   hash)
          (push key changed))
         ((not (equal (plist-get e :ddl) (aref o 3)))
          (plist-put e :type (aref o 2))
          (plist-put e :ddl (aref o 3))
          (push key changed)))))
    (let (gone)
      (maphash (lambda (k _) (unless (gethash k seen) (push k gone))) hash)
      (dolist (k gone) (remhash k hash)))
    (nreverse changed)))

(defun orajs--merge-all (objects)
  "Merge OBJECTS into tables and programs.
Return (CHANGED-TABLES . CHANGED-PACKAGES), keys to fetch details for."
  (let (tables programs)
    (seq-doseq (o objects)
      (if (member (aref o 2) orajs--table-types) (push o tables) (push o programs)))
    (cons (orajs--merge-objects (nreverse tables) orajs--tables)
          (seq-filter (lambda (k) (equal (plist-get (gethash k orajs--programs) :type)
                                         "PACKAGE"))
                      (orajs--merge-objects (nreverse programs) orajs--programs)))))

(defun orajs--put-details (rows hash key detail)
  "Set DETAIL (:columns or :members) of entries of HASH from ROWS.
Each row is [OWNER NAME ...]; KEY makes the list item from a row.
Rows of one entry are consecutive and in order."
  (let ((touched (make-hash-table :test #'equal)))
    (seq-doseq (r rows)
      (let* ((k (concat (aref r 0) "." (aref r 1)))
             (e (gethash k hash)))
        (when e
          (unless (gethash k touched)
            (puthash k t touched)
            (plist-put e detail nil))
          (plist-put e detail (cons (funcall key r) (plist-get e detail))))))
    (maphash (lambda (k _)
               (let ((e (gethash k hash)))
                 (plist-put e detail (nreverse (plist-get e detail)))))
             touched)))

(defun orajs--put-columns (rows)
  "Set the columns of tables in ROWS, [OWNER NAME COLUMN TYPE] in column order."
  (orajs--put-details rows orajs--tables
                      (lambda (r) (cons (aref r 2) (aref r 3))) :columns))

(defun orajs--put-members (rows)
  "Set package members from ROWS, [OWNER PACKAGE NAME KIND OVERLOADS]."
  (orajs--put-details rows orajs--programs
                      (lambda (r) (list (aref r 2) (aref r 3) (aref r 4))) :members))

(defun orajs--forget-misses ()
  "Forget failed lookups: the object may exist now."
  (let (misses)
    (maphash (lambda (k v) (when (eq v 'none) (push k misses))) orajs--described)
    (dolist (k misses) (remhash k orajs--described))))

(defconst orajs--detail-batch-limit 500
  "Above this many changed objects, fetch all details in one go instead.")

(defcustom orajs-download-limit 2000
  "Ask before downloading more than this many objects' names.
Objects are the tables, views and PL/SQL units of the schemas that are
not Oracle's.  Declining is remembered for the connection; names are
then looked up one at a time as you use them, and
\\[orajs-download-schemas] asks again."
  :type 'natnum)

(defun orajs--sync-cache (&optional quiet ask)
  "Bring the schema cache up to date, in the background.
QUIET: report only failures (after DDL run from orajs, where a message
would hide the statement's own result, such as its compile errors).
ASK: the user asked (`orajs-download-schemas'), so ask again even if a
download was declined before.
1. One cheap query (object count and latest DDL time) tells whether
   anything changed since the last sync.
2. Before a first download of more than `orajs-download-limit' objects,
   ask.
3. List the objects with their DDL times; fetch columns and package
   members only for new or changed ones; drop the vanished.
4. Fetch the data dictionary names if missing or the database version
   changed.  Then save the cache to disk."
  (setq orajs--syncing t
        orajs--sync-quiet quiet)
  (force-mode-line-update t)
  (orajs--forget-misses)
  (orajs--send
   "summary" nil
   (lambda (ok err)
     (if err
         (orajs--sync-done (format "schema check failed: %s" (plist-get err :message)))
       (let ((stamp (cons (plist-get ok :count) (plist-get ok :ddl))))
         (cond
          ((equal stamp orajs--stamp)
           (orajs--sync-dictionary (orajs--summary "up to date") nil))
          ((or (orajs--downloaded-p) (<= (car stamp) orajs-download-limit))
           (orajs--sync-objects stamp))
          ;; Declined before, or a quiet sync (after DDL): never prompt.
          ((and (or orajs--declined quiet) (not ask))
           (orajs--sync-dictionary
            (substitute-command-keys
             (format "%d objects not downloaded (\\[orajs-download-schemas] to)"
                     (car stamp)))
            nil))
          (t
           ;; Ask from the command loop, not from inside the process filter.
           (run-at-time
            0 nil
            (lambda ()
              (if (condition-case nil
                      (y-or-n-p
                       (format "Download the names of %d tables, views and PL/SQL units? "
                               (car stamp)))
                    (quit nil))
                  (progn (setq orajs--declined nil)
                         (orajs--sync-objects stamp))
                (setq orajs--declined (car stamp))
                (orajs--sync-dictionary
                 "not downloaded; names are looked up as you use them" t)))))))))))

(defun orajs--summary (what)
  "A sync summary: cached counts, then WHAT."
  (format "%d tables/views, %d PL/SQL units, %s"
          (hash-table-count orajs--tables) (hash-table-count orajs--programs) what))

(defun orajs--detail-keys (keys hash)
  "KEYS of HASH as a vector of [OWNER NAME] pairs for the bridge."
  (vconcat (mapcar (lambda (k) (let ((e (gethash k hash)))
                                 (vector (plist-get e :owner) (plist-get e :name))))
                   keys)))

(defun orajs--sync-objects (stamp)
  "List objects, fetch details of the changed ones, then the dictionary.
STAMP, the (COUNT . DDL) just read, is recorded when all went well."
  (orajs--sync-progress "listing objects...")
  (orajs--send
   "objects" nil
   (lambda (ok err)
     (if err
         (orajs--sync-done (format "schema check failed: %s" (plist-get err :message)))
       (setq orajs--schemas (append (plist-get ok :schemas) nil))
       (pcase-let* ((`(,tables . ,packages) (orajs--merge-all (plist-get ok :objects)))
                    (summary (orajs--summary (format "%d new or changed"
                                                     (+ (length tables) (length packages))))))
         (orajs--sync-progress "fetching columns of %d tables/views..." (length tables))
         (orajs--fetch-details
          "columns" :tables tables orajs--tables #'orajs--put-columns
          (lambda ()
            (orajs--sync-progress "fetching members of %d packages..." (length packages))
            (orajs--fetch-details
             "members" :packages packages orajs--programs #'orajs--put-members
             (lambda ()
               (setq orajs--stamp stamp)
               (orajs--sync-dictionary summary t))))))))))

(defun orajs--fetch-details (op arg keys hash put then)
  "Ask the bridge OP for details of KEYS of HASH (argument ARG), store with PUT.
No request when KEYS is empty; all of them in one go above
`orajs--detail-batch-limit'.  Then call THEN."
  (if (null keys)
      (funcall then)
    (orajs--send
     op (unless (> (length keys) orajs--detail-batch-limit)
          (list arg (orajs--detail-keys keys hash)))
     (lambda (ok err)
       (if err
           (orajs--sync-done (format "%s fetch failed: %s" op (plist-get err :message)))
         (funcall put (plist-get ok :rows))
         (funcall then))))))

(defun orajs--sync-dictionary (summary dirty)
  "Fetch dictionary names if needed, save if DIRTY or fetched, report SUMMARY."
  (if (and orajs--dictionary (equal orajs--dictionary-server orajs--server))
      (progn (when dirty (orajs--save-cache))
             (orajs--sync-done summary))
    (orajs--sync-progress "%s; fetching data dictionary names..." summary)
    (orajs--send
     "dictionary" nil
     (lambda (ok err)
       (if err
           (orajs--sync-done (format "%s; dictionary fetch failed: %s"
                                      summary (plist-get err :message)))
         (unless (equal orajs--dictionary-server (plist-get ok :server))
           (clrhash orajs--described))
         (setq orajs--dictionary (mapcar (lambda (r) (cons (aref r 0) (aref r 1)))
                                          (plist-get ok :rows))
               orajs--oracle-packages (append (plist-get ok :packages) nil)
               orajs--dictionary-server (plist-get ok :server))
         (orajs--save-cache)
         (orajs--sync-done (format "%s; %d dictionary views, %d Oracle packages" summary
                                    (length orajs--dictionary)
                                    (length orajs--oracle-packages))))))))

(defun orajs--sync-progress (format-string &rest args)
  "Show a sync progress message (FORMAT-STRING with ARGS), unless quiet."
  (unless orajs--sync-quiet
    (let ((message-log-max nil))
      (apply #'message (concat "orajs: " format-string) args))))

(defun orajs--sync-done (summary)
  "End a sync: clear the mode-line indicator and report SUMMARY.
Not if the sync is quiet and SUMMARY is no failure, nor if the
connection went away meanwhile (a disconnect mid-sync)."
  (setq orajs--syncing nil)
  (force-mode-line-update t)
  (when (and (orajs-connected-p)
             (or (not orajs--sync-quiet) (string-match-p "failed" summary)))
    (let ((message-log-max nil))
      (message "orajs: %s" summary))))

;;;; Disk cache

(defun orajs--cache-file ()
  "The cache file of the current connection: one per connection, user and database.
The database's own name is part of it, so pointing a connection name at
another database starts a fresh cache instead of reusing the wrong one."
  (expand-file-name
   (concat (replace-regexp-in-string
            "[^A-Za-z0-9_.-]" "_"
            (string-join (delq nil (list orajs--connection orajs--user orajs--container))
                         "-"))
           ".eld")
   orajs-cache-directory))

(defconst orajs--cache-version 2
  "Format of the disk cache; files of another version are ignored.")

(defun orajs--save-cache ()
  "Write the schema cache of this connection to disk."
  (let ((file (orajs--cache-file))
        tables programs described)
    (maphash (lambda (k v) (push (cons k v) tables)) orajs--tables)
    (maphash (lambda (k v) (push (cons k v) programs)) orajs--programs)
    (maphash (lambda (k v) (unless (eq v 'none) (push (cons k v) described)))
             orajs--described)
    (make-directory (file-name-directory file) t)
    (with-file-modes #o600
      (with-temp-file file
        (let ((print-length nil) (print-level nil) (print-circle nil))
          (insert ";; orajs schema cache: names only.  Safe to delete.\n")
          (prin1 (list :version orajs--cache-version
                       :server orajs--dictionary-server
                       :stamp orajs--stamp
                       :declined orajs--declined
                       :schemas orajs--schemas
                       :tables tables
                       :programs programs
                       :dictionary orajs--dictionary
                       :oracle-packages orajs--oracle-packages
                       :described described)
                 (current-buffer)))))))

(defun orajs--load-disk-cache ()
  "Load this connection's cache from disk; non-nil if there was one."
  (let ((file (orajs--cache-file)))
    (when (file-readable-p file)
      (condition-case err
          (let ((data (with-temp-buffer
                        (insert-file-contents file)
                        (read (current-buffer)))))
            (when (eql (plist-get data :version) orajs--cache-version)
              (dolist (kv (plist-get data :tables))
                (puthash (car kv) (cdr kv) orajs--tables))
              (dolist (kv (plist-get data :programs))
                (puthash (car kv) (cdr kv) orajs--programs))
              (dolist (kv (plist-get data :described))
                (puthash (car kv) (cdr kv) orajs--described))
              (setq orajs--schemas (plist-get data :schemas)
                    orajs--stamp (plist-get data :stamp)
                    orajs--declined (plist-get data :declined)
                    orajs--dictionary (plist-get data :dictionary)
                    orajs--oracle-packages (plist-get data :oracle-packages)
                    orajs--dictionary-server (plist-get data :server))
              t))
        (error (message "orajs: ignoring unreadable cache %s: %s"
                        file (error-message-string err))
               nil)))))

(defun orajs--ident (s)
  "Return Oracle's name for identifier S: as quoted, else upper-cased."
  (if (string-prefix-p "\"" s)
      (string-trim s "\"" "\"")
    (upcase s)))

(defun orajs--find-table (name)
  "Cache entry for table NAME (\"T\" or \"OWNER.T\"), without asking the database.
Unqualified names prefer the connected user's schema; then anything
already looked up by `orajs--lookup-tables' (DUAL, ALL_TABLES, ...)."
  (let* ((parts (split-string name "\\." t))
         (cached
          (if (cdr parts)
              (gethash (concat (orajs--ident (car parts)) "." (orajs--ident (cadr parts)))
                       orajs--tables)
            (let ((n (orajs--ident (car parts))))
              (or (and orajs--user (gethash (concat orajs--user "." n) orajs--tables))
                  (catch 'found
                    (maphash (lambda (_k e)
                               (when (equal (plist-get e :name) n) (throw 'found e)))
                             orajs--tables)
                    nil)))))
         (described (gethash (upcase name) orajs--described)))
    (or cached
        (and (consp described)
             (member (plist-get described :type) orajs--table-types)
             described))))

(defun orajs--find-program (name)
  "Cache entry for PL/SQL unit NAME (\"PKG\" or \"OWNER.PKG\"), without asking.
Like `orajs--find-table': the user's own first, then any schema, then
anything looked up before (DBMS_OUTPUT ...)."
  (let* ((parts (split-string name "\\." t))
         (cached
          (if (cdr parts)
              (gethash (concat (orajs--ident (car parts)) "." (orajs--ident (cadr parts)))
                       orajs--programs)
            (let ((n (orajs--ident (car parts))))
              (or (and orajs--user (gethash (concat orajs--user "." n) orajs--programs))
                  (catch 'found
                    (maphash (lambda (_k e)
                               (when (equal (plist-get e :name) n) (throw 'found e)))
                             orajs--programs)
                    nil)))))
         (described (gethash (upcase name) orajs--described)))
    (or cached
        (and (consp described)
             (member (plist-get described :type) '("PACKAGE" "PROCEDURE" "FUNCTION"))
             described))))

(defun orajs--describe-remote (names)
  "Ask the database for the columns of NAMES; nil if not connected or slow."
  (when (orajs-connected-p)
    (condition-case nil
        (let ((reply (orajs--request-sync "describe" (list :names (vconcat names)) 3)))
          (mapcar (lambda (n)
                    (let ((d (plist-get reply (intern (concat ":" n)))))
                      (cons n (and d (list :owner (plist-get d :owner)
                                           :name (plist-get d :name)
                                           :type (plist-get d :type)
                                           :columns (mapcar (lambda (c) (cons (aref c 0) (aref c 1)))
                                                            (plist-get d :columns))
                                           :members (mapcar (lambda (m) (append m nil))
                                                            (plist-get d :members)))))))
                  names))
      (error nil))))

(defun orajs--lookup-tables (names)
  "Make sure every one of NAMES (as written) is resolved, in one round trip.
Names neither cached nor looked up before are described by the database
\(own objects, then private and public synonyms); misses are remembered."
  (let ((missing (seq-uniq
                  (seq-filter (lambda (n) (and (not (orajs--find-table n))
                                               (not (orajs--find-program n))
                                               (not (gethash (upcase n) orajs--described))))
                              names))))
    (when missing
      (let (found)
        (pcase-dolist (`(,n . ,entry) (funcall orajs--describe-function missing))
          (when entry (setq found t))
          (puthash (upcase n) (or entry 'none) orajs--described))
        (when (and found orajs--connection (not orajs--syncing))
          (ignore-errors (orajs--save-cache)))))))

;;;; Statements

(defconst orajs--plsql-re
  (rx (or (seq "create" (+ space)
               (? "or" (+ space) "replace" (+ space))
               (? (or "editionable" "noneditionable") (+ space))
               (or "package" "procedure" "function" "trigger" "type"))
          ;; CREATE MLE MODULE m LANGUAGE JAVASCRIPT AS <JavaScript> (but
          ;; not ... USING BFILE/CLOB/BLOB (...), which is plain SQL).
          (seq "create" (+ space)
               (? "or" (+ space) "replace" (+ space))
               "mle" (+ space) "module" word-boundary
               (*? (not (in ";"))) word-boundary "as" word-boundary)
          (seq (or "declare" "begin") word-boundary)))
  "How a PL/SQL unit or MLE module (ended by a line holding only \"/\") starts.")

(defconst orajs--slash-line-re "^[ \t]*/[ \t]*$")

(defun orajs--in-string-or-comment-p (pos &optional from)
  "Non-nil if POS is inside a string or comment.
Parsed from FROM, the start of the statement, when given; else from the
start of the buffer."
  (save-excursion
    (nth 8 (if from
               (progn (syntax-propertize pos) (parse-partial-sexp from pos))
             (syntax-ppss pos)))))

(defun orajs--search-code (regexp bound from)
  "Search forward for REGEXP up to BOUND, skipping strings and comments.
Strings and comments are parsed from FROM, the start of the statement:
parsing each statement on its own keeps a stray quote in an earlier one
\(say, in JavaScript: // don't) from turning the rest of the buffer into
a string."
  (syntax-propertize (or bound (point-max)))
  (let ((pos from) state found)
    (while (and (not found) (re-search-forward regexp bound t))
      (let ((m (match-beginning 0)))
        (when (> m pos)
          (setq state (save-excursion (parse-partial-sexp pos m nil nil state))
                pos m))
        (unless (nth 8 state) (setq found m))))
    found))

(defun orajs--statements ()
  "Statements in the buffer: a list of (START END PLSQLP), in order.
SQL ends at \";\", a blank line, or a \"/\" line; PL/SQL units (CREATE
PACKAGE/PROCEDURE/..., DECLARE, BEGIN) and MLE modules (CREATE MLE
MODULE ... AS) end at the first line holding only \"/\", as in SQL*Plus:
their bodies are not parsed, so JavaScript cannot confuse them."
  (save-excursion
    (goto-char (point-min))
    (let (stmts)
      (while (progn (forward-comment (buffer-size)) (not (eobp)))
        (let* ((start (point))
               (plsql (let ((case-fold-search t)) (looking-at-p orajs--plsql-re)))
               (term (if plsql
                         (and (re-search-forward orajs--slash-line-re nil t)
                              (match-beginning 0))
                       (orajs--search-code
                        (concat ";\\|\n[ \t]*\n\\|" orajs--slash-line-re) nil start)))
               (end (or term (point-max))))
          (push (list start end plsql) stmts)
          ;; Resume after the terminator: past a ";" or the newline that
          ;; starts a blank line, or at the end of a "/" line.
          (goto-char (cond ((null term) (point-max))
                           ((memq (char-after term) '(?\; ?\n)) (1+ term))
                           (t (save-excursion (goto-char term) (line-end-position)))))))
      (nreverse stmts))))

(defun orajs--statement-at-point ()
  "The statement at or before point: (TEXT START END), or nil."
  (let ((pos (point)) best)
    (dolist (s (orajs--statements))
      (when (<= (car s) pos) (setq best s)))
    (when best
      (pcase-let* ((`(,start ,end ,_plsql) best)
                   (text (string-trim-right (buffer-substring-no-properties start end))))
        (list text start (+ start (length text)))))))

(defun orajs--region-statement (beg end)
  "Statement text for region BEG..END.
Trimmed, without a trailing \";\" on SQL or a closing \"/\" line."
  (let* ((text (string-trim (buffer-substring-no-properties beg end)))
         (text (string-trim-right (replace-regexp-in-string "\n[ \t]*/[ \t]*\\'" "" text))))
    (if (let ((case-fold-search t)) (string-match-p (concat "\\`" orajs--plsql-re) text))
        text
      (string-trim-right (string-remove-suffix ";" text)))))

;;;; Running statements

(defconst orajs--ddl-re
  (rx bos (* (in space "\n")) (or "create" "alter" "drop" "rename" "truncate") word-boundary)
  "Statements after which the schema cache is synced.")

(defconst orajs--serveroutput-re
  (rx bos (* space) "set" (+ space) "serverout" (* alpha) (+ space)
      (group (or "on" "off")) word-boundary)
  "SQL*Plus's SET SERVEROUTPUT ON|OFF, handled by orajs rather than sent.")

(defun orajs--set-serveroutput (on)
  "Turn DBMS_OUTPUT collection ON or off for this session."
  (orajs--send "serverOutput" (list :on (if on t :false))
               (lambda (_ok err)
                 (message "orajs: %s" (if err (plist-get err :message)
                                        (format "serveroutput %s" (if on "on" "off")))))))

(defun orajs-execute ()
  "Run the statement at point, or the active region."
  (interactive)
  (unless (orajs-connected-p) (user-error "Not connected; use M-x orajs-connect"))
  (pcase-let ((`(,sql ,beg ,end)
               (if (use-region-p)
                   (list (orajs--region-statement (region-beginning) (region-end))
                         (region-beginning) (region-end))
                 (or (orajs--statement-at-point) (user-error "No statement here")))))
    (pulse-momentary-highlight-region beg end)
    (let ((case-fold-search t))
      (when (string-match orajs--serveroutput-re sql)
        (orajs--set-serveroutput (equal (downcase (match-string 1 sql)) "on"))
        (setq sql nil)))
    (when sql
      (let ((source (current-buffer))
            (start (float-time)))
        (message "orajs: running...")
        (orajs--send "exec" (list :sql sql :maxRows orajs-page-size)
                     (lambda (ok err)
                       (if err
                           (orajs--report-error err source beg)
                         (orajs--report-result ok sql source beg
                                               (- (float-time) start))
                         ;; New, changed or dropped tables: catch up quietly.
                         (when (and (not orajs--syncing)
                                    (let ((case-fold-search t))
                                      (string-match-p orajs--ddl-re sql)))
                           (orajs--sync-cache 'quiet)))
                       ;; After the grid, so the two get a window each.
                       (orajs--show-output (plist-get (or err ok) :output) sql)))))))

(defun orajs--report-error (err source beg)
  "Show ERR; put point at its offset in SOURCE when Oracle gave one.
BEG is where the statement starts."
  (let ((offset (plist-get err :offset)))
    (when (and offset (> offset 0) (buffer-live-p source))
      (with-current-buffer source
        (let ((pos (min (point-max) (+ beg offset))))
          (dolist (w (get-buffer-window-list source nil t))
            (set-window-point w pos))
          (goto-char pos))))
    (message "%s" (propertize (string-trim (plist-get err :message)) 'face 'error))))

(defun orajs--report-result (ok sql source beg seconds)
  "Show OK, the result of SQL from SOURCE (statement at BEG) after SECONDS."
  (cond
   ((plist-get ok :columns) (orajs--show-grid ok sql seconds))
   ((plist-get ok :compileErrors)
    (let ((ce (plist-get ok :compileErrors)))
      (orajs--show-compile-errors
       ce source
       (if (equal (plist-get ce :type) "MLE MODULE")
           (orajs--mle-body-start beg)   ; JavaScript: counted from after AS
         beg)                            ; PL/SQL: from the CREATE line
       (format "%s %s" (plist-get ce :type) (plist-get ce :object)))))
   ((plist-get ok :rowsAffected)
    (let ((n (plist-get ok :rowsAffected)))
      (message "orajs: %d row%s (%.2fs)" n (if (= n 1) "" "s") seconds)))
   (t (when (let ((case-fold-search t))
              (string-match-p (concat "\\`" orajs--plsql-re) sql))
        (orajs--clear-compile-errors))   ; a unit compiled cleanly
      (message "orajs: done (%.2fs)" seconds))))

;;;; Compile errors: *orajs-errors* and `next-error'

(defun orajs--compile-error-position (type body-start line position)
  "Source position of a compile error of an object of TYPE.
BODY-START is where Oracle's line 1 starts: the CREATE line for PL/SQL,
the code after AS (or a module buffer's start) for an MLE module.
LINE and POSITION are ALL_ERRORS's."
  (if (equal type "MLE MODULE")
      (orajs--mle-error-position body-start line position)
    (save-excursion
      (goto-char body-start)
      (forward-line (1- line))
      (move-to-column (max 0 (1- position)))   ; PL/SQL columns count from 1
      (point))))

(defvar-keymap orajs-errors-mode-map
  "RET" #'orajs-goto-error
  "n" #'next-error-no-select
  "p" #'previous-error-no-select)

(define-derived-mode orajs-errors-mode special-mode "Orajs-Errors"
  "Major mode listing compile errors of the last PL/SQL unit or MLE module.
\\<orajs-errors-mode-map>\\[orajs-goto-error] jumps to the error; from anywhere,
\\[next-error] and \\[previous-error] step through them."
  (setq-local next-error-function #'orajs--next-error)
  (setq-local overlay-arrow-position nil))

(defun orajs--show-compile-errors (ce source body-start label)
  "List compile errors CE of the code in SOURCE, and go to the first.
BODY-START is where Oracle's line 1 starts in SOURCE; LABEL names the
object, e.g. \"PACKAGE BODY HR.EMP_API\".  The list is in *orajs-errors*;
`next-error' (\\[next-error]) steps through it."
  (let* ((errors (append (plist-get ce :errors) nil))
         (type (plist-get ce :type))
         (buf (get-buffer-create "*orajs-errors*")))
    (with-current-buffer buf
      (orajs-errors-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "%s: %d error%s\n" label (length errors)
                                    (if (= (length errors) 1) "" "s"))
                            'face 'bold))
        (dolist (e errors)
          (let* ((text (string-trim (plist-get e :text)))
                 (pos (and (buffer-live-p source)
                           (with-current-buffer source
                             (save-restriction
                               (widen)
                               (copy-marker
                                (orajs--compile-error-position
                                 type body-start (plist-get e :line)
                                 (plist-get e :position))))))))
            (insert (propertize
                     (format "%5d:%-3d %s\n" (plist-get e :line) (plist-get e :position)
                             (car (split-string text "\n")))
                     'orajs-error (cons pos text)
                     'mouse-face 'highlight
                     'face (if (equal (plist-get e :attribute) "WARNING")
                               'warning 'error))))))
      (goto-char (point-min))
      (setq next-error-last-buffer buf))
    ;; Tall enough for every error, the header and the mode line (plus
    ;; one spare, for an echo area that wraps), up to a third of the frame.
    (display-buffer buf `(display-buffer-at-bottom
                          (window-height . ,(min (+ 3 (length errors))
                                                 (max 4 (/ (frame-height) 3))))))
    ;; Like `next-error' on the first one, then the summary.
    (with-current-buffer buf
      (goto-char (point-min))
      (orajs--next-error 1))
    (let ((first (car errors)))
      (message "%s" (propertize
                     ;; Short, so the echo area stays one line (a taller one
                     ;; would take a line from the list); the list's first
                     ;; line names the object.
                     (format "%d error%s; line %d: %s%s"
                             (length errors) (if (cdr errors) "s" "")
                             (plist-get first :line)
                             (car (split-string (string-trim (plist-get first :text)) "\n"))
                             (if (cdr errors) "  (M-g n for the next)" ""))
                     'face 'error)))))

(defun orajs--clear-compile-errors ()
  "After a clean compile: empty *orajs-errors*, so `next-error' stops there."
  (when-let* ((buf (get-buffer "*orajs-errors*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "No compile errors.\n" 'face 'shadow))))
    (when (eq next-error-last-buffer buf)
      (setq next-error-last-buffer nil))))

(defun orajs--visit-error (err)
  "Go to ERR, a (MARKER . TEXT) from *orajs-errors*, and show its text."
  (let ((marker (car err)))
    (unless (and (markerp marker) (buffer-live-p (marker-buffer marker)))
      (user-error "The source of this error is gone"))
    (pop-to-buffer (marker-buffer marker))
    (widen)
    (goto-char marker)
    (message "%s" (propertize (cdr err) 'face 'error))))

(defun orajs--next-error (n &optional reset)
  "The `next-error-function' of *orajs-errors*: move N errors and visit it.
RESET means count from before the first error."
  (let (err)
    (with-current-buffer (get-buffer "*orajs-errors*")
      (let* ((lines (let (acc)                ; start of each error line
                      (save-excursion
                        (goto-char (point-min))
                        (while (not (eobp))
                          (when (get-text-property (point) 'orajs-error)
                            (push (point) acc))
                          (forward-line 1)))
                      (nreverse acc)))
             (here (and (not reset) (seq-position lines (line-beginning-position))))
             (target (+ (or here -1) n)))
        (unless (and lines (<= 0 target) (< target (length lines)))
          (user-error "No more compile errors"))
        (goto-char (nth target lines))
        (setq err (get-text-property (point) 'orajs-error))
        (orajs--mark-current-error)))
    (orajs--visit-error err)))

(defun orajs--mark-current-error ()
  "In *orajs-errors*, point the overlay arrow at the current line and show it.
`next-error' replaces the echo area text with \"Next locus from ...\", so
the list stays in view, as compilation buffers do."
  (setq overlay-arrow-position (copy-marker (line-beginning-position)))
  (let ((win (or (get-buffer-window (current-buffer))
                 (display-buffer (current-buffer)
                                 '(display-buffer-at-bottom
                                   (window-height . fit-window-to-buffer))))))
    (when win (set-window-point win (point)))))

(defun orajs-goto-error ()
  "Go to the compile error on this line of *orajs-errors*."
  (interactive)
  (let ((err (get-text-property (point) 'orajs-error)))
    (unless err (user-error "No error on this line"))
    (setq next-error-last-buffer (current-buffer))
    (orajs--mark-current-error)
    (orajs--visit-error err)))

;;;; Where an MLE module's compile error is

(defun orajs--mle-body-start (beg)
  "Return the start of the JavaScript in the CREATE MLE MODULE statement at BEG.
That is, the position just after its AS keyword."
  (save-excursion
    (goto-char beg)
    (let ((case-fold-search t))
      (if (re-search-forward (rx (or bos (not (in "A-Za-z0-9_$#\"")))
                                 (group "as")
                                 (or eos (not (in "A-Za-z0-9_$#\""))))
                             nil t)
          (match-end 1)
        beg))))

(defun orajs--mle-error-position (body-start line position)
  "Buffer position of an MLE module error at LINE and POSITION.
BODY-START is where the JavaScript begins (after AS, or the start of a
module buffer).  Oracle stores the code from its first non-blank
character and numbers lines from there, so line 1 may start mid-line;
POSITION counts from 0 (PL/SQL's count from 1)."
  (save-excursion
    (goto-char body-start)
    (skip-chars-forward " \t\n\r\f")
    ;; Not (forward-line 0) for line 1: that would go to the line's start.
    (when (> line 1) (forward-line (1- line)))
    (min (line-end-position) (+ (point) position))))

;;;; DBMS_OUTPUT (and console.log from JavaScript)

(define-derived-mode orajs-output-mode special-mode "Orajs-Output"
  "Major mode for DBMS_OUTPUT, including `console.log' from MLE JavaScript.
Each statement's lines follow a dim line naming the statement.
\\{orajs-output-mode-map}"
  (setq-local truncate-lines nil))

(defun orajs--show-output (lines statement)
  "Append DBMS_OUTPUT LINES (a sequence of strings) from STATEMENT and show them.
Nothing happens when there are no LINES."
  (when (and lines (> (length lines) 0))
    (with-current-buffer (get-buffer-create "*orajs-output*")
      (unless (derived-mode-p 'orajs-output-mode) (orajs-output-mode))
      (let ((inhibit-read-only t)
            (label (truncate-string-to-width
                    (replace-regexp-in-string "[ \t\n]+" " " (string-trim statement))
                    60 nil nil "…")))
        (goto-char (point-max))
        (unless (bobp) (insert "\n"))
        (insert (propertize (format "-- %s  %s\n" (format-time-string "%T") label)
                            'face 'shadow))
        (seq-doseq (line lines) (insert line "\n")))
      (let ((win (display-buffer (current-buffer))))
        (when win (set-window-point win (point-max)))))))

(defun orajs-show-output ()
  "Show *orajs-output*: DBMS_OUTPUT and JavaScript `console.log' lines.
They are collected after every statement while `orajs-server-output' is
on (it is read when connecting)."
  (interactive)
  (if-let* ((buf (get-buffer "*orajs-output*")))
      (pop-to-buffer buf)
    (message "orajs: no output yet%s"
             (if orajs-server-output "" " (`orajs-server-output' is off)"))))

;;;; JavaScript (MLE) modules, Oracle 23ai

;; M-. on an MLE module opens its JavaScript, exactly as Oracle stores it,
;; in `js-mode'.  The CREATE statement is not JavaScript, so it is drawn
;; above the code rather than kept in the buffer: line N of the buffer is
;; Oracle's line N.

(defvar-local orajs--module-declaration nil
  "The CREATE statement, up to and including AS, of this MLE module buffer.
Shown above the code; `orajs-module-compile' sends it before the code.
Permanent, so it survives the change to `sql-mode' that saving the
buffer to a .sql file brings (see `orajs--module-save-as-script').")
(put 'orajs--module-declaration 'permanent-local t)

(defun orajs--module-declaration-for (owner name version)
  "CREATE OR REPLACE ... AS for MLE module OWNER.NAME, with VERSION if any."
  (format "CREATE OR REPLACE MLE MODULE %s.%s LANGUAGE JAVASCRIPT%s AS"
          (orajs--quote-ident owner) (orajs--quote-ident name)
          (if (or (null version) (string-empty-p version))
              ""
            (format " VERSION '%s'" (string-replace "'" "''" version)))))

(defun orajs--module-show-declaration ()
  "Draw the declaration and a key hint above the code."
  (remove-overlays (point-min) (point-max) 'orajs-module t)
  (let ((ov (make-overlay (point-min) (point-min))))
    (overlay-put ov 'orajs-module t)
    (overlay-put ov 'before-string
                 (concat orajs--module-declaration "\n"
                         (propertize
                          (substitute-command-keys
                           "\\<orajs-module-mode-map>\\[orajs-module-edit-declaration] edit declaration · \\[orajs-module-compile] compile")
                          'face 'shadow)
                         "\n"))))

(defvar-keymap orajs-module-mode-map
  "C-c C-c" #'orajs-module-compile
  "C-c C-e" #'orajs-module-edit-declaration)

(define-minor-mode orajs-module-mode
  "Edit an MLE module fetched from the database.
Its declaration (CREATE ... AS) is shown above the code.  Saved to a
file that would open in `sql-mode' (a .sql file, say), the buffer
becomes the whole script: declaration, JavaScript and a closing /, as
Oracle's DDL export has it.  Saved to any other file (a .js file), it is
just the JavaScript.
\\{orajs-module-mode-map}"
  :lighter (:eval (orajs--lighter))
  :keymap orajs-module-mode-map
  (if orajs-module-mode
      (progn
        (orajs--module-show-declaration)
        ;; Global: `set-visited-file-name' kills a buffer-local value.
        (add-hook 'write-file-functions #'orajs--module-save-as-script))
    (remove-overlays (point-min) (point-max) 'orajs-module t)))

(defun orajs--sql-file-p (file)
  "Non-nil if FILE would open in `sql-mode', or a mode derived from it."
  (let ((mode (assoc-default file auto-mode-alist #'string-match)))
    (and mode (symbolp mode) (provided-mode-derived-p mode 'sql-mode))))

(defun orajs--module-save-as-script ()
  "Before a module buffer is written to a SQL file, make it the script.
That is its declaration, the JavaScript and a closing /, in `sql-mode'.
Returns nil, so the buffer is then written as usual.  For
`write-file-functions', which runs once the file name is known; by
then Emacs has usually switched the buffer to `sql-mode' itself (see
`change-major-mode-with-file-name')."
  (when (and orajs--module-declaration buffer-file-name
             (orajs--sql-file-p buffer-file-name))
    (let ((header (concat orajs--module-declaration "\n"))
          (pos (point)))
      (when orajs-module-mode (orajs-module-mode -1))
      (remove-overlays (point-min) (point-max) 'orajs-module t)
      (setq orajs--module-declaration nil)
      (save-restriction
        (widen)
        (goto-char (point-min))
        (insert header)
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert "/\n"))
      (orajs--sql-buffer-setup)
      (goto-char (+ pos (length header)))))
  nil)

(defun orajs--module-setup (owner name version)
  "Mode for MLE module OWNER.NAME of VERSION: `js-mode', `orajs-module-mode'."
  (funcall (alist-get 'js-mode major-mode-remap-alist #'js-mode))
  (setq orajs--module-declaration (orajs--module-declaration-for owner name version))
  (orajs-module-mode 1))

(defun orajs-module-edit-declaration ()
  "Edit this module's declaration (its CREATE statement) in the minibuffer.
It takes effect on the next \\[orajs-module-compile]."
  (interactive)
  (let ((new (string-trim (read-string "Declaration: " orajs--module-declaration))))
    (when (string-empty-p new) (user-error "No declaration"))
    (unless (equal new orajs--module-declaration)
      (setq orajs--module-declaration new)
      (set-buffer-modified-p t)
      (orajs--module-show-declaration))))

(defun orajs--module-replaces-p (declaration)
  "Non-nil if DECLARATION is CREATE OR REPLACE (so it can be run again)."
  (let ((case-fold-search t))
    (and (string-match-p "\\`create[[:space:]]+or[[:space:]]+replace[[:space:]]" declaration)
         (not (string-match-p "\\bif[[:space:]]+not[[:space:]]+exists\\b" declaration)))))

(defun orajs--module-replacing (declaration)
  "DECLARATION as CREATE OR REPLACE, without IF NOT EXISTS."
  (let ((case-fold-search t))
    (replace-regexp-in-string
     "\\`create[[:space:]]+\\(?:or[[:space:]]+replace[[:space:]]+\\)?" "CREATE OR REPLACE "
     (replace-regexp-in-string "\\bif[[:space:]]+not[[:space:]]+exists[[:space:]]+" ""
                               declaration t t)
     t t)))

(defun orajs-module-compile ()
  "Compile this MLE module: its declaration, then the buffer's JavaScript.
On an error, point goes where Oracle says."
  (interactive)
  (unless (orajs-connected-p) (user-error "Not connected; use M-x orajs-connect"))
  (unless (orajs--module-replaces-p orajs--module-declaration)
    (unless (y-or-n-p "Without OR REPLACE, compiling an existing module fails or does nothing.  Make it CREATE OR REPLACE? ")
      (user-error "Not compiled"))
    (setq orajs--module-declaration (orajs--module-replacing orajs--module-declaration))
    (orajs--module-show-declaration))
  (let* ((header (concat orajs--module-declaration "\n"))
         (sql (concat header (save-restriction
                               (widen)
                               (buffer-substring-no-properties (point-min) (point-max)))))
         (source (current-buffer))
         (tick (buffer-chars-modified-tick))
         (start (float-time)))
    (message "orajs: compiling...")
    (orajs--send "exec" (list :sql sql :maxRows orajs-page-size)
                 (lambda (ok err)
                   (orajs--report-module ok err source (length header) tick
                                         (- (float-time) start))
                   (orajs--show-output (plist-get (or err ok) :output)
                                       orajs--module-declaration)))))

(defun orajs--report-module (ok err source header-length tick seconds)
  "Report compiling the module in SOURCE: result OK or error ERR.
HEADER-LENGTH is the length of the DDL before the JavaScript; TICK was
SOURCE's `buffer-chars-modified-tick' when it was sent; SECONDS is how
long it took."
  (cond
   (err
    (let ((offset (plist-get err :offset)))
      (when (and offset (> offset header-length))
        (orajs--goto-in source (with-current-buffer source
                                 (+ (point-min) (- offset header-length))))))
    (message "%s" (propertize (string-trim (plist-get err :message)) 'face 'error)))
   ((plist-get ok :compileErrors)
    (let ((ce (plist-get ok :compileErrors)))
      (orajs--show-compile-errors
       ce source (with-current-buffer source (point-min))
       (format "MLE MODULE %s" (plist-get ce :object)))))
   (t (orajs--clear-compile-errors)
      (when (buffer-live-p source)
        (with-current-buffer source
          ;; Unless edited while it compiled: then those edits are not in.
          ;; Once visiting a file, modified means unsaved, not uncompiled.
          (when (and (null buffer-file-name)
                     (= tick (buffer-chars-modified-tick)))
            (set-buffer-modified-p nil))))
      (message "orajs: MLE module compiled (%.2fs)" seconds))))

(defun orajs--goto-in (buffer pos)
  "Move point to POS in BUFFER and in the windows showing it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((pos (max (point-min) (min (point-max) pos))))
        (dolist (w (get-buffer-window-list buffer nil t))
          (set-window-point w pos))
        (goto-char pos)))))

;;;; Results grid

(defvar-local orajs--grid-columns nil)
(defvar-local orajs--grid-rows nil)
(defvar-local orajs--grid-more nil)
(defvar-local orajs--grid-sql nil)

(defvar-keymap orajs-results-mode-map
  "n" #'orajs-fetch-more
  "RET" #'orajs-show-cell
  "w" #'orajs-copy-cell
  "q" #'quit-window)

(define-derived-mode orajs-results-mode special-mode "Orajs-Results"
  "Major mode for query results.
\\<orajs-results-mode-map>\\[orajs-fetch-more] fetch more rows, \\[orajs-show-cell] show the cell in full,
\\[orajs-copy-cell] copy the cell.  From the vtable library: S sort by
column, { and } narrow/widen column, M-<left>/M-<right> move between
columns."
  ;; Only affects `orajs-results-mode' buffers; removed on unload.
  (advice-add 'vtable--set-header-line :after #'orajs--header-line)
  (setq truncate-lines t)
  (setq-local mode-line-process '(:eval (orajs--grid-status))))

(defun orajs--grid-status ()
  "Mode-line text: rows fetched, and whether there are more."
  (format " %d row%s%s" (length orajs--grid-rows)
          (if (= (length orajs--grid-rows) 1) "" "s")
          (if orajs--grid-more ", more: n" "")))

(defconst orajs--null (propertize "" 'orajs-null t)
  "Sort key for NULL in text columns (compared with `eq').")

(defun orajs--sort-value (value numeric)
  "Return the key to sort VALUE (a string or nil) by; NUMERIC for number columns.
vtable sorts a column numerically only when every key in it is a number,
so numeric columns get exact numbers where Emacs can hold them exactly
\(any integer; decimals up to 15 significant digits) and NULL becomes
+infinity: last when ascending, first when descending, as in Oracle."
  (cond
   ((null value) (if numeric 1.0e+INF orajs--null))
   ((not numeric) value)
   ((string-match-p "\\`-?[0-9]+\\'" value) (string-to-number value))
   ((and (string-match-p "\\`-?[0-9]*\\.[0-9]+\\'" value)
         (<= (length (string-trim-left (replace-regexp-in-string "[-.]" "" value) "0+"))
             15))
    (string-to-number value))
   (t value)))

(defun orajs--format-cell (value)
  "Return grid text for sort key VALUE: NULL as a dim ∅, newlines as ⏎."
  (cond
   ((or (null value) (eq value orajs--null) (eql value 1.0e+INF))
    (propertize "∅" 'face 'shadow))
   ((numberp value) (number-to-string value))
   (t (replace-regexp-in-string "\n" "⏎" value t t))))

(defun orajs--format-opaque (value)
  "Return grid text for placeholder VALUE, e.g. \"(CLOB 50000 chars)\": dim."
  (if (or (null value) (eq value orajs--null))
      (propertize "∅" 'face 'shadow)
    (propertize value 'face 'shadow)))

(defconst orajs--numeric-types
  '("NUMBER" "BINARY_FLOAT" "BINARY_DOUBLE" "FLOAT"))

(defun orajs--show-grid (ok sql seconds)
  "Show query result OK for SQL, which took SECONDS, in the results buffer."
  (with-current-buffer (get-buffer-create "*orajs-results*")
    (orajs-results-mode)
    (setq orajs--grid-columns (plist-get ok :columns)
          orajs--grid-rows (append (plist-get ok :rows) nil)
          orajs--grid-more (plist-get ok :more)
          orajs--grid-sql sql)
    (orajs--render-grid)
    (goto-char (point-min))
    ;; The window keeps its own point: put it on the first row too, or
    ;; C-x o lands below the table where RET finds no cell.
    (when-let* ((win (display-buffer (current-buffer))))
      (set-window-point win (point-min))
      (set-window-start win (point-min)))
    (message "orajs: %d row%s%s (%.2fs)%s" (length orajs--grid-rows)
             (if (= (length orajs--grid-rows) 1) "" "s")
             (if orajs--grid-more ", more with n in the grid" "") seconds
             (orajs--json-decoded-note ok))))

(defun orajs--json-decoded-note (ok)
  "Return a warning if result OK had JSON decoded (a document over 32 KB)."
  (if (plist-get ok :jsonDecoded)
      (propertize "; JSON over 32 KB: numbers beyond ~15 digits may be rounded"
                  'face 'warning)
    ""))

(defun orajs--render-grid ()
  "Draw the grid from the buffer's rows."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (if (null orajs--grid-rows)
        (insert (propertize "(no rows)" 'face 'shadow))
      (make-vtable
       :face 'default
       :columns (seq-map-indexed
                 (lambda (col i)
                   (list :name (plist-get col :name)
                         :align (if (member (plist-get col :type) orajs--numeric-types)
                                    'right 'left)
                         ;; vtable sizes columns to their data; keep the
                         ;; header readable ("DUMMY" over a column of "X").
                         :min-width (min (string-width (plist-get col :name))
                                         orajs-max-column-width)
                         :max-width orajs-max-column-width
                         :getter (let ((numeric (member (plist-get col :type)
                                                        orajs--numeric-types)))
                                   (lambda (row _table)
                                     (orajs--sort-value (aref row i) numeric)))
                         :formatter (if (plist-get col :opaque)
                                        #'orajs--format-opaque
                                      #'orajs--format-cell)))
                 orajs--grid-columns)
       :objects orajs--grid-rows))))

(defun orajs--limit-string (string pixels)
  "STRING shortened from the end until it is at most PIXELS wide."
  (while (and (length> string 0) (> (string-pixel-width string) pixels))
    (setq string (substring string 0 -1)))
  string)

(defun orajs--header-line (table widths spacer &rest _)
  "Redraw TABLE's header line with each name at its column's absolute position.
Emacs 29's vtable pads each header by a width that is off by half a
character plus the separator, so names drift away from their columns;
`:align-to' positions cannot drift.  WIDTHS and SPACER are in pixels.
Runs after vtable's own header code (see `orajs-results-mode'), so if
vtable's internals change and this fails, vtable's header stays."
  (when (and (derived-mode-p 'orajs-results-mode)
             (fboundp 'vtable--indicator))
    (ignore-errors
      (let ((x 0) parts)
        (seq-do-indexed
         (lambda (column index)
           (let* ((width (elt widths index))
                  (label (concat (vtable-column-name column)
                                 (vtable--indicator table index))))
             (push (propertize " " 'display `(space :align-to (,x))) parts)
             (push (propertize (orajs--limit-string label width) 'face 'header-line)
                   parts)
             (setq x (+ x width spacer))))
         (vtable-columns table))
        (setq header-line-format
              (string-replace "%" "%%" (apply #'concat (nreverse parts))))))))

(defun orajs-unload-function ()
  "Remove the vtable header advice when orajs is unloaded."
  (advice-remove 'vtable--set-header-line #'orajs--header-line)
  ;; Continue with the standard unloading.
  nil)

(defun orajs-fetch-more ()
  "Fetch the next page of rows into the grid."
  (interactive)
  (unless orajs--grid-more (user-error "No more rows"))
  (let ((buf (current-buffer))
        (line (line-number-at-pos)))
    (orajs--send "fetch" (list :maxRows orajs-page-size)
                  (lambda (ok err)
                    (if err
                        (message "orajs: %s" (plist-get err :message))
                      (with-current-buffer buf
                        (setq orajs--grid-rows
                              (append orajs--grid-rows (append (plist-get ok :rows) nil))
                              orajs--grid-more (plist-get ok :more))
                        (orajs--render-grid)
                        (goto-char (point-min))
                        (forward-line (1- line))
                        (message "orajs: %d rows%s%s" (length orajs--grid-rows)
                                 (if orajs--grid-more ", more with n" "")
                                 (orajs--json-decoded-note ok)))
                      (orajs--show-output (plist-get ok :output) orajs--grid-sql))))))

(defun orajs--cell-at-point ()
  "(COLUMN-NAME VALUE COLUMN) under point in the grid; COLUMN is its plist."
  (let ((row (vtable-current-object))
        (col (vtable-current-column)))
    (unless (and row col) (user-error "No cell here"))
    (let ((column (aref orajs--grid-columns col)))
      (list (plist-get column :name) (aref row col) column))))

(defun orajs--refuse-opaque (value column)
  "Signal that VALUE of COLUMN is only a placeholder, when it is."
  (when (and value (plist-get column :opaque))
    (user-error "Not fetched by orajs: %s contents, %s"
                (plist-get column :type) value)))

(defun orajs--json-pretty (text)
  "Compact JSON TEXT indented two spaces per level.
Works on the characters, not a parse, so numbers stay exactly as Oracle
wrote them (`json-pretty-print' would round long decimals)."
  (with-temp-buffer
    (let ((depth 0) (i 0) (n (length text)) in-string)
      (cl-flet ((newline () (insert "\n" (make-string (* 2 depth) ?\s))))
        (while (< i n)
          (let ((c (aref text i)))
            (cond
             (in-string
              (insert c)
              (cond ((eq c ?\\) (setq i (1+ i)) (when (< i n) (insert (aref text i))))
                    ((eq c ?\") (setq in-string nil))))
             ((eq c ?\") (insert c) (setq in-string t))
             ((memq c '(?{ ?\[))
              (if (and (< (1+ i) n) (memq (aref text (1+ i)) '(?} ?\])))
                  (progn (insert c (aref text (1+ i))) (setq i (1+ i)))   ; {} []
                (setq depth (1+ depth))
                (insert c)
                (newline)))
             ((memq c '(?} ?\]))
              (setq depth (1- depth))
              (newline)
              (insert c))
             ((eq c ?,) (insert c) (newline))
             ((eq c ?:) (insert ": "))
             ((memq c '(?\s ?\t ?\n ?\r)))          ; whitespace outside strings
             (t (insert c))))
          (setq i (1+ i)))))
    (buffer-string)))

(defun orajs-show-cell ()
  "Show the cell under point in full, in its own buffer.
JSON is pretty-printed in `js-json-mode'.  LOB, XMLTYPE, object (e.g.
SDO_GEOMETRY) and cursor columns are not fetched, so not shown."
  (interactive)
  (pcase-let ((`(,name ,value ,column) (orajs--cell-at-point)))
    (orajs--refuse-opaque value column)
    (with-current-buffer (get-buffer-create "*orajs-cell*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (and value (plist-get column :json))
            (progn (insert (orajs--json-pretty value))
                   (if (fboundp 'js-json-mode) (js-json-mode) (js-mode)))
          (insert (or value ""))
          (fundamental-mode)))
      (setq buffer-read-only t)
      (use-local-map (make-composed-keymap (define-keymap "q" #'quit-window)
                                           (current-local-map)))
      (setq header-line-format
            (format "%s%s  (q to close)" name (if value "" " (NULL)")))
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))

(defun orajs-copy-cell ()
  "Copy the cell under point to the kill ring (JSON compact, as stored)."
  (interactive)
  (pcase-let ((`(,name ,value ,column) (orajs--cell-at-point)))
    (orajs--refuse-opaque value column)
    (kill-new (or value ""))
    (message "Copied %s%s" name (if value "" " (NULL, as empty)"))))

;;;; Completion

(defconst orajs--ident-chars "A-Za-z0-9_$#")

(defconst orajs--not-aliases
  '("WHERE" "JOIN" "INNER" "LEFT" "RIGHT" "FULL" "OUTER" "CROSS" "NATURAL" "ON"
    "USING" "GROUP" "ORDER" "HAVING" "CONNECT" "START" "UNION" "MINUS"
    "INTERSECT" "EXCEPT" "FETCH" "OFFSET" "FOR" "PIVOT" "UNPIVOT" "MODEL"
    "SET" "VALUES" "WHEN" "THEN" "RETURNING" "LOG" "PARTITION" "SAMPLE" "AS" "FROM"))

(defun orajs--statement-bounds ()
  "Bounds (START . END) of the statement around point, for alias lookup."
  (let ((pos (point)) best)
    (dolist (s (orajs--statements))
      (when (<= (car s) pos) (setq best s)))
    (if best
        (cons (car best) (max pos (cadr best)))
      (cons (point-min) (point-max)))))

(defun orajs--aliases ()
  "Alist (ALIAS . TABLE-ENTRY) for tables named in the statement at point.
A table's own name counts as an alias for it."
  (pcase-let ((`(,beg . ,end) (orajs--statement-bounds))
              (case-fold-search t)
              (mentions nil)
              (found nil))
    (save-excursion
      (goto-char beg)
      (while (re-search-forward
              (rx (or (seq (or bol (not (in "A-Za-z0-9_$#\"")))
                           (or "from" "join" "update" "into"))
                      ",")
                  (+ (in space "\n"))
                  (group (? (+ (in "A-Za-z0-9_$#\"")) ".") (+ (in "A-Za-z0-9_$#\"")))
                  (? (+ (in space "\n")) (? "as" (+ (in space "\n")))
                     (group (+ (in "A-Za-z0-9_$#")))))
              end t)
        (let ((name (match-string-no-properties 1))
              (alias (match-string-no-properties 2)))
          (if (and alias (member (upcase alias) orajs--not-aliases))
              ;; A keyword taken for an alias ("from t join u") may start
              ;; the next match, so resume right after the table name.
              (progn (push (cons name nil) mentions)
                     (goto-char (match-end 1)))
            (push (cons name alias) mentions)))))
    (orajs--lookup-tables (mapcar #'car mentions))
    (pcase-dolist (`(,name . ,alias) (nreverse mentions))
      (when-let* ((entry (orajs--find-table name)))
        (push (cons (upcase (car (last (split-string name "\\.")))) entry) found)
        (when alias (push (cons (upcase alias) entry) found))))
    (nreverse found)))

(defun orajs--qualifier (beg)
  "The identifier chain before a dot ending just before BEG, e.g. (\"HR\" \"EMP\")."
  (save-excursion
    (goto-char beg)
    (let (parts)
      (while (eq (char-before) ?.)
        (backward-char)
        (let ((e (point)))
          (skip-chars-backward (concat orajs--ident-chars "\""))
          (push (buffer-substring-no-properties (point) e) parts)))
      parts)))

(defun orajs--case-function (prefix)
  "`upcase' or `downcase', as `orajs-completion-case' and PREFIX ask."
  (pcase orajs-completion-case
    ('upper #'upcase)
    ('lower #'downcase)
    (_ (if (let ((case-fold-search nil))
             (and (string-match-p "[A-Z]" prefix)
                  (not (string-match-p "[a-z]" prefix))))
           #'upcase
         #'downcase))))

(defun orajs--case (candidate prefix)
  "CANDIDATE in the letter case asked for by `orajs-completion-case' and PREFIX."
  (funcall (orajs--case-function prefix) candidate))

(defconst orajs--clause-re
  (rx (or (group-n 2 ";")
          (seq (or bos (not (in "A-Za-z0-9_$#.\"")))
               (or (group-n 1 (or "select" "from" "join" "into" "update" "where" "and"
                                  "or" "on" "by" "set" "having" "when" "then" "else"
                                  "distinct"))
                   (group-n 2 (or "begin" "loop" "declare" "exception")))
               (or eos (not (in "A-Za-z0-9_$#\""))))))
  "What tells whether a table name or a column name comes next.
Group 1: a clause keyword.  Group 2: the end of a PL/SQL statement or
the start of a block, after which it can't be told.")

(defun orajs--context (beg)
  "What is being typed at BEG: `table', `column', or nil (can't tell).
Decided by the nearest clause keyword before BEG in the statement; in
PL/SQL, not looking past the previous \";\", BEGIN, LOOP, DECLARE or
EXCEPTION."
  (let ((start (car (orajs--statement-bounds)))
        (case-fold-search t))
    (save-excursion
      (goto-char beg)
      (catch 'context
        (while (re-search-backward orajs--clause-re start t)
          (let ((kw (match-string 1)))
            (unless (orajs--in-string-or-comment-p (match-beginning (if kw 1 2)) start)
              (throw 'context
                     (cond ((null kw) nil)
                           ((member (downcase kw) '("from" "join" "into" "update")) 'table)
                           (t 'column))))))
        nil))))

(defun orajs--qualified-entry (qualifier)
  "What the identifier chain QUALIFIER (before a dot) names.
Returns (table . ENTRY), (program . ENTRY) or (schema . OWNER), or nil.
An alias or table wins over a package, which wins over a schema; a name
known to none of them is looked up in the database once."
  (let* ((q (mapconcat #'identity qualifier "."))
         (single (null (cdr qualifier)))
         (found
          (lambda ()
            (let ((table (or (and single (cdr (assoc (upcase (car qualifier)) (orajs--aliases))))
                             (orajs--find-table q))))
              (cond (table (cons 'table table))
                    ((orajs--find-program q) (cons 'program (orajs--find-program q)))
                    ((and single (member (orajs--ident (car qualifier)) orajs--schemas))
                     (cons 'schema (orajs--ident (car qualifier)))))))))
    (or (funcall found)
        (progn (orajs--lookup-tables (list q))
               (funcall found)))))

(defun orajs--candidates (qualifier &optional context prefix)
  "Alist (NAME . (KIND . ANNOTATION)) of completions.
QUALIFIER is nil or the identifier chain before a dot: then the columns
of that table or alias, the procedures and functions of that package, or
the tables, views and PL/SQL units of that schema.  Without one, CONTEXT
\(see `orajs--context') and PREFIX decide: after SELECT, WHERE ... the
columns of the statement's tables (and, once something is typed,
packages and functions); after FROM, JOIN ... tables, schemas and
dictionary views; when it can't tell (PL/SQL code), all names, but only
once something has been typed."
  (let ((first (and prefix (not (string-empty-p prefix)) (upcase (aref prefix 0))))
        out)
    ;; Every completion style keeps the first letter, so names starting
    ;; with anything else are skipped before any work is done on them.
    (cl-labels ((add (name kind note)
                  (when (or (null first) (eq (aref name 0) first))
                    (push (cons name (cons kind note)) out)))
                (add-columns (entry)
                  (dolist (c (plist-get entry :columns))
                    (add (car c) 'field (concat " " (cdr c)))))
                (add-members (entry)
                  (pcase-dolist (`(,name ,kind ,overloads) (plist-get entry :members))
                    (add name 'method
                         (format " %s%s" (downcase kind)
                                 (if (and overloads (> overloads 1))
                                     (format " (%d overloads)" overloads) "")))))
                (add-statement-columns ()
                  (let (seen)
                    (dolist (a (orajs--aliases))
                      (unless (memq (cdr a) seen)
                        (push (cdr a) seen)
                        (add-columns (cdr a))))))
                (add-table (e &optional owner)
                  (add (plist-get e :name)
                       (if (equal (plist-get e :type) "VIEW") 'interface 'struct)
                       (format " %s%s" (downcase (plist-get e :type))
                               (if owner (concat " " (plist-get e :owner)) ""))))
                (add-program (e &optional owner)
                  (add (plist-get e :name)
                       (if (equal (plist-get e :type) "PACKAGE") 'module 'function)
                       (format " %s%s" (downcase (plist-get e :type))
                               (if owner (concat " " (plist-get e :owner)) ""))))
                (add-tables ()
                  (maphash (lambda (_k e) (add-table e t)) orajs--tables)
                  (dolist (s orajs--schemas) (add s 'module " schema")))
                (add-programs ()
                  (maphash (lambda (_k e) (add-program e t)) orajs--programs)
                  (dolist (p orajs--oracle-packages) (add p 'module " Oracle package"))))
      (cond
       (qualifier
        (pcase (orajs--qualified-entry qualifier)
          (`(table . ,e) (add-columns e))
          (`(program . ,e) (add-members e))
          (`(schema . ,owner)
           (maphash (lambda (_k e) (when (equal (plist-get e :owner) owner) (add-table e)))
                    orajs--tables)
           (maphash (lambda (_k e) (when (equal (plist-get e :owner) owner) (add-program e)))
                    orajs--programs))))
       ((eq context 'column)
        (add-statement-columns)
        ;; Functions and packages in a select list or condition, once typed.
        (when first (add-programs)))
       ((eq context 'table)
        (add-tables)
        ;; Thousands of dictionary views: only once a letter narrows them.
        (when first
          (pcase-dolist (`(,name . ,note) orajs--dictionary)
            (add name 'interface (concat " " (or note "dictionary"))))))
       (first
        (add-statement-columns)
        (add-programs)
        (add-tables))))
    ;; First one wins: columns of a named table over same-named tables etc.
    ;; (A hash, not `cl-remove-duplicates': thousands of dictionary names.)
    (let ((seen (make-hash-table :test #'equal :size (length out)))
          result)
      (dolist (c (nreverse out))
        (unless (gethash (car c) seen)
          (puthash (car c) t seen)
          (push c result)))
      (nreverse result))))

(defun orajs-completion-at-point ()
  "Complete Oracle table, view, schema and column names at point."
  (when (or (orajs-connected-p) (> (hash-table-count orajs--tables) 0))
    (let* ((end (point))
           (beg (save-excursion (skip-chars-backward orajs--ident-chars) (point)))
           (prefix (buffer-substring-no-properties beg end))
           (qualifier (orajs--qualifier beg))
           (cands (orajs--candidates qualifier
                                      (unless qualifier (orajs--context beg))
                                      prefix)))
      (when cands
        (let* ((case-fn (orajs--case-function prefix))
               (table (make-hash-table :test #'equal :size (length cands)))
               (names (mapcar (lambda (c)
                                (let ((n (funcall case-fn (car c))))
                                  (puthash n (cdr c) table)
                                  n))
                              cands)))
          (list beg end
                (completion-table-case-fold names)
                :exclusive 'no
                :annotation-function (lambda (c) (cdr (gethash c table)))
                :company-kind (lambda (c) (car (gethash c table)))))))))

;;;; Jump to definition (xref: M-. and M-,)

;; Objects as stored in the database: PL/SQL source from ALL_SOURCE, tables,
;; views and sequences as DBMS_METADATA DDL.  Names resolve as Oracle
;; resolves them (own object, private synonym, public synonym).

(defvar orajs-mode)   ; defined below, with the minor mode

(defun orajs--xref-backend ()
  "The xref backend of `orajs-mode' buffers."
  (and orajs-mode 'orajs))

(defconst orajs--ident-or-quote (concat orajs--ident-chars "\""))

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql orajs)))
  "The dotted name at point, up to the end of the part point is on.
On \"hire\" in \"emp_api.hire\" that is \"emp_api.hire\"; on \"emp_api\",
\"emp_api\".  It remembers where it was, for aliases."
  (save-excursion
    (skip-chars-forward orajs--ident-or-quote)
    (let ((end (point)))
      (skip-chars-backward (concat orajs--ident-or-quote "."))
      (skip-chars-forward ".")
      (when (< (point) end)
        (propertize (buffer-substring-no-properties (point) end)
                    'orajs-marker (copy-marker (point)))))))

(cl-defmethod xref-backend-identifier-completion-table ((_backend (eql orajs)))
  "Names of the cached tables, views and PL/SQL units, for \\[xref-find-definitions]'s prompt."
  (let (names)
    (maphash (lambda (_k e) (push (downcase (plist-get e :name)) names)) orajs--tables)
    (maphash (lambda (_k e) (push (downcase (plist-get e :name)) names)) orajs--programs)
    (delete-dups names)))

(defun orajs--resolve (name)
  "What NAME, as written in SQL, is in the database.
A plist (:owner :name :type :via), :via the synonyms followed; or nil."
  (plist-get (orajs--request-sync "resolve" (list :name name) 10) :object))

(defun orajs--quote-ident (name)
  "NAME as an Oracle identifier: bare if it can be, else double-quoted."
  (let ((case-fold-search nil))
    (if (string-match-p "\\`[A-Z][A-Z0-9_$#]*\\'" name) name (format "\"%s\"" name))))

(defconst orajs--unit-head-re
  (rx bos (* space)
      (group (or (seq "package" (+ space) "body") "package" "procedure" "function"
                 "trigger" (seq "type" (+ space) "body") "type"))
      (+ space)
      (? (or (seq "\"" (+ (not (in "\""))) "\"") (+ (in "A-Za-z0-9_$#"))) (* space) "." (* space))
      (or (seq "\"" (+ (not (in "\""))) "\"") (+ (in "A-Za-z0-9_$#"))))
  "How ALL_SOURCE's first line names the unit (without CREATE OR REPLACE).")

(defun orajs--recreatable-source (text owner name)
  "ALL_SOURCE TEXT of OWNER.NAME as DDL that recreates it.
Oracle stores it without CREATE OR REPLACE and often without the owner;
both go back, so running the buffer recompiles the right object."
  (let ((case-fold-search t))
    (concat
     (if (string-match orajs--unit-head-re text)
         (concat "CREATE OR REPLACE " (match-string 1 text) " "
                 (orajs--quote-ident owner) "." (orajs--quote-ident name)
                 (substring text (match-end 0)))
       text)
     (if (string-suffix-p "\n" text) "" "\n")
     "/\n")))

(defun orajs--object-buffer (owner name kind fetch setup)
  "Buffer showing OWNER.NAME's KIND (e.g. \"package body\", \"DDL\").
FETCH returns its text, or nil if there is none (then this returns nil);
SETUP sets up the buffer's mode.  A buffer you have edited is reused as
it is, not fetched again."
  (let* ((bufname (format "*orajs: %s.%s %s*" owner name kind))
         (buf (get-buffer bufname)))
    (if (and buf (buffer-modified-p buf))
        buf
      (when-let* ((text (funcall fetch)))
        (with-current-buffer (get-buffer-create bufname)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert text))
          (funcall setup)
          (set-buffer-modified-p nil)
          (goto-char (point-min))
          (current-buffer))))))

(defun orajs--sql-buffer-setup ()
  "Mode for fetched PL/SQL or DDL: `sql-mode' with `orajs-mode'."
  (unless (derived-mode-p 'sql-mode) (sql-mode))
  (unless orajs-mode (orajs-mode 1)))

(defun orajs--source-buffer (owner name type)
  "Buffer with the stored source of OWNER.NAME of TYPE, or nil if none."
  (let ((mle (equal type "MLE MODULE"))
        version)
    (orajs--object-buffer
     owner name (downcase type)
     (lambda ()
       (let ((reply (orajs--request-sync
                     "source" (list :owner owner :name name :type type) 30)))
         (setq version (plist-get reply :version))
         (when-let* ((text (plist-get reply :text)))
           (if mle text (orajs--recreatable-source text owner name)))))
     (if mle
         (lambda () (orajs--module-setup owner name version))
       #'orajs--sql-buffer-setup))))

(defun orajs--ddl-buffer (owner name type)
  "Buffer with DBMS_METADATA's DDL of OWNER.NAME of TYPE (a table, view ...)."
  (orajs--object-buffer
   owner name "DDL"
   (lambda ()
     (when-let* ((text (plist-get (orajs--request-sync
                                   "ddl" (list :owner owner :name name :type type) 30)
                                  :text)))
       (concat (string-trim text) ";\n")))
   #'orajs--sql-buffer-setup))

(defun orajs--member-positions (buffer member)
  "Where BUFFER's PL/SQL declares procedure or function MEMBER (one per overload)."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search t) found)
        (while (re-search-forward
                (rx bol (* space) (or "procedure" "function") (+ space)
                    (literal member) (not (in "A-Za-z0-9_$#")))
                nil t)
          (let ((pos (match-beginning 0)))
            ;; (Not bare `syntax-ppss': it leaves point at POS, and the
            ;; search would find this match again, forever.)
            (unless (orajs--in-string-or-comment-p pos)
              (push (save-excursion (goto-char pos) (skip-chars-forward " \t") (point))
                    found))))
        (nreverse found)))))

(defun orajs--column-position (buffer column)
  "Where BUFFER's DDL lists COLUMN, or nil: its first quoted mention after the \"(\"."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search nil))
        (and (search-forward "(" nil t)
             (search-forward (format "\"%s\"" (orajs--ident column)) nil t)
             (match-beginning 0))))))

(defun orajs--xref (buffer pos)
  "An xref item for POS in BUFFER, summarised by its line."
  (xref-make (with-current-buffer buffer
               (save-excursion
                 (goto-char pos)
                 (format "%s: %s" (buffer-name)
                         (string-trim (buffer-substring (line-beginning-position)
                                                        (line-end-position))))))
             (xref-make-buffer-location buffer pos)))

(defun orajs--object-xrefs (object &optional member)
  "Xrefs to OBJECT (from `orajs--resolve'), or to its MEMBER.
MEMBER is a package's procedure or function, or a table's or view's column."
  (pcase-let (((map (:owner owner) (:name name) (:type type)) object))
    (cond
     ((equal type "PACKAGE")
      ;; The body, where the code is; the spec when there is no body we can
      ;; see (Oracle's own packages) or the member is only declared there.
      (let* ((body (orajs--source-buffer owner name "PACKAGE BODY"))
             (spec (unless (and body (or (null member)
                                         (orajs--member-positions body member)))
                     (orajs--source-buffer owner name "PACKAGE")))
             (buf (if spec spec body)))
        (when buf
          (if member
              (mapcar (lambda (pos) (orajs--xref buf pos))
                      (orajs--member-positions buf member))
            (list (orajs--xref buf 1))))))
     ((member type '("TABLE" "VIEW" "MATERIALIZED VIEW" "SEQUENCE"))
      (when-let* ((buf (orajs--ddl-buffer owner name type)))
        (list (orajs--xref buf (or (and member (orajs--column-position buf member)) 1)))))
     ((and (null member) (member type '("PROCEDURE" "FUNCTION" "TRIGGER" "TYPE" "MLE MODULE")))
      (when-let* ((buf (orajs--source-buffer owner name type)))
        (list (orajs--xref buf 1)))))))

(defun orajs--alias-table (alias marker)
  "The cached table ALIAS stands for in the statement at MARKER, or nil."
  (when (and marker (buffer-live-p (marker-buffer marker)))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (cdr (assoc (upcase alias) (orajs--aliases)))))))

(cl-defmethod xref-backend-definitions ((_backend (eql orajs)) identifier)
  "Definitions of IDENTIFIER: from your TAGS file, else from the database.
The TAGS file is used when there is one; see `orajs-make-tags'."
  (or (orajs--tags-definitions identifier)
      (orajs--db-definitions identifier)))

;;;; Jump to definition: your own source, through a TAGS file

;; etags's variables, let-bound below: declared special so the binding is
;; dynamic (seen by etags) in this lexical-binding file.
(defvar tags-file-name)
(defvar tags-table-list)
(defvar tags-case-fold-search)

(defcustom orajs-ctags-program nil
  "Universal Ctags, used by `orajs-make-tags'.
Nil means the first of ctags-universal, uctags and ctags that is
Universal Ctags (Emacs's own ctags, for one, is not)."
  :type '(choice (const :tag "Find it" nil) string))

(defun orajs--universal-ctags-p (program)
  "Non-nil if PROGRAM can be found and is Universal Ctags."
  (and (executable-find program)
       (with-temp-buffer
         (ignore-errors (call-process program nil t nil "--version"))
         (goto-char (point-min))
         (search-forward "Universal Ctags" nil t))))

(defun orajs--ctags ()
  "Return the Universal Ctags program for `orajs-make-tags', or nil."
  (seq-find #'orajs--universal-ctags-p
            (if orajs-ctags-program
                (list orajs-ctags-program)
              '("ctags-universal" "uctags" "ctags"))))

(defun orajs--tags-file ()
  "The TAGS file for this buffer: one visited, else one in a parent directory."
  (require 'etags)
  (or tags-file-name
      (car tags-table-list)
      (when-let* ((dir (locate-dominating-file default-directory "TAGS")))
        (expand-file-name "TAGS" dir))))

(defun orajs--tag-defs (name tags)
  "Xrefs to tag NAME in TAGS (a file name), exact matches only."
  (let ((tags-file-name tags)
        (tags-table-list nil)
        (tags-case-fold-search t)
        (inhibit-message t)             ; "Starting a new list of tags tables"
        (message-log-max nil))
    (condition-case nil
        (xref-backend-definitions 'etags name)
      (error nil))))

(defun orajs--xref-file (xref)
  "The file of XREF (etags's locations are grouped by file)."
  (xref-location-group (xref-item-location xref)))

(defun orajs--tags-definitions (identifier)
  "Definitions of IDENTIFIER in this buffer's TAGS file, or nil.
TAGS files do not say which package a procedure (or which table a column)
belongs to, so for \"pkg.name\" only tags of NAME in a file that also
defines PKG count; an alias stands for its table."
  (when-let* ((tags (orajs--tags-file))
              ((file-readable-p tags)))
    (let* ((marker (get-text-property 0 'orajs-marker identifier))
           (parts (mapcar (lambda (p) (string-trim p "\"" "\""))
                          (split-string identifier "\\." t)))
           (container-name
            (lambda (name)                ; an alias's table, else NAME itself
              (let ((alias (and marker (ignore-errors (orajs--alias-table name marker)))))
                (if alias (downcase (plist-get alias :name)) name))))
           (in-files-of
            (lambda (container name)
              (let ((files (delq nil (mapcar #'orajs--xref-file (orajs--tag-defs container tags)))))
                (and files
                     (seq-filter (lambda (x) (member (orajs--xref-file x) files))
                                 (orajs--tag-defs name tags)))))))
      (pcase parts
        (`(,one) (orajs--tag-defs (funcall container-name one) tags))
        (`(,a ,b) (or (funcall in-files-of (funcall container-name a) b)
                      ;; schema.object
                      (orajs--tag-defs b tags)))
        (`(,_owner ,pkg ,member) (funcall in-files-of pkg member))))))

;;;###autoload
(defun orajs-make-tags (directory)
  "Build a TAGS file of the SQL and PL/SQL under DIRECTORY with Universal Ctags.
DIRECTORY defaults to the current project's root.  Afterwards
\\[xref-find-definitions] in an `orajs-mode' buffer looks in it first,
and in the database only for names it does not have."
  (interactive
   (list (read-directory-name
          "Tag SQL files under: "
          (if-let* ((proj (project-current))) (project-root proj) default-directory))))
  (let ((default-directory (file-name-as-directory (expand-file-name directory)))
        (ctags (orajs--ctags)))
    (unless ctags
      (user-error "Universal Ctags (https://ctags.io) is needed; %s"
                  (if orajs-ctags-program
                      (format "`%s' is not it (see `orajs-ctags-program')"
                              orajs-ctags-program)
                    "none found as ctags-universal, uctags or ctags")))
    (with-temp-buffer
      (unless (zerop (call-process ctags nil t nil
                                   "-e" "-R" "-f" "TAGS"
                                   "--langmap=SQL:+.pks.pkb.pkh.pls.plb.pck"
                                   "--languages=SQL" "."))
        (user-error "Ctags failed: %s" (string-trim (buffer-string)))))
    (visit-tags-table (expand-file-name "TAGS") t)
    (message "orajs: %s built; M-. looks there first" (abbreviate-file-name (expand-file-name "TAGS")))))

;;;; Jump to definition: the database

(defun orajs--db-definitions (identifier)
  "Definitions of IDENTIFIER in the database: the object, or a member or column."
  (unless (orajs-connected-p) (user-error "Not connected; use M-x orajs-connect"))
  (let* ((marker (get-text-property 0 'orajs-marker identifier))
         (parts (split-string identifier "\\." t))
         (table-object (lambda (e) (list :owner (plist-get e :owner) :name (plist-get e :name)
                                          :type (plist-get e :type))))
         (object nil) (member nil))
    (pcase parts
      (`(,one)
       (setq object (if-let* ((e (orajs--alias-table one marker)))
                        (funcall table-object e)
                      (orajs--resolve one))))
      (`(,a ,b)
       (let ((alias (orajs--alias-table a marker)))
         (if alias
             (setq object (funcall table-object alias) member b)
           (let ((first (orajs--resolve a)))
             (if (and first (member (plist-get first :type)
                                    '("PACKAGE" "TABLE" "VIEW" "MATERIALIZED VIEW")))
                 (setq object first member b)
               (setq object (orajs--resolve identifier)))))))   ; schema.object
      (`(,a ,b ,c)
       (setq object (orajs--resolve (concat a "." b)) member c)))
    (when-let* ((via (plist-get object :via)))
      (message "orajs: %s is a synonym for %s.%s"
               (car (append via nil)) (plist-get object :owner) (plist-get object :name)))
    (and object (orajs--object-xrefs object member))))

;;;###autoload
(defun orajs-find-object (name)
  "Open the definition of NAME as stored in the database.
NAME is as \\[xref-find-definitions] takes it (object, schema.object or
package.member), defaulting to the name at point.  With a % in it, NAME
is a LIKE pattern, [schema.]name in any case, and you choose among the
objects it matches.  Unlike \\[xref-find-definitions] it works from any
buffer and does not look in your TAGS file.  Back with \\[xref-go-back]."
  (interactive
   (progn
     (unless (orajs-connected-p) (user-error "Not connected; use M-x orajs-connect"))
     (let ((default (xref-backend-identifier-at-point 'orajs)))
       (list (read-string (format-prompt "Database object (%% wildcard)" default)
                          nil nil default)))))
  (when (string-blank-p name) (user-error "No object name"))
  (unless (orajs-connected-p) (user-error "Not connected; use M-x orajs-connect"))
  (let ((xrefs (if (string-search "%" name)
                   (orajs--object-xrefs (orajs--choose-object name))
                 (orajs--db-definitions name))))
    (unless xrefs (user-error "No definition of %s in the database" name))
    (xref-push-marker-stack)
    (funcall xref-show-definitions-function (lambda () xrefs) nil)))

(defconst orajs--search-limit 500
  "Most objects `orajs-find-object' offers for a pattern.")

(defun orajs--choose-object (pattern)
  "The object, chosen, of those whose names match PATTERN.
PATTERN is [schema.]name with LIKE wildcards; the database matches it.
A plist (:owner :name :type), as `orajs--resolve' returns."
  (let* ((parts (split-string pattern "\\."))
         (_ (when (> (length parts) 2)
              (user-error "A pattern is [schema.]name: %s" pattern)))
         (reply (orajs--request-sync
                 "search" (list :owner (if (cdr parts) (car parts) "%")
                                :name (car (last parts))
                                :limit orajs--search-limit)
                 30))
         (choices (mapcar (lambda (row)
                            (cons (format "%s.%s (%s)" (aref row 0) (aref row 1)
                                          (downcase (aref row 2)))
                                  (list :owner (aref row 0) :name (aref row 1)
                                        :type (aref row 2))))
                          (plist-get reply :rows))))
    (cond
     ((null choices) (user-error "Nothing in the database matches %s" pattern))
     ((and (null (cdr choices)) (not (plist-get reply :more))) (cdar choices))
     (t (cdr (assoc (completing-read
                     (if (plist-get reply :more)
                         (format "Object (first %d matches): " orajs--search-limit)
                       (format "Object (%d matches): " (length choices)))
                     choices nil t)
                    choices))))))

;;;; Minor mode

;;;###autoload (autoload 'orajs-command-map "orajs" nil t 'keymap)
(defvar-keymap orajs-command-map
  :doc "Orajs commands.
Not bound to a key by default; bind it to a prefix you like, e.g.
  (keymap-global-set \"C-c o\" \\='orajs-command-map)"
  :prefix 'orajs-command-map
  "c" #'orajs-connect
  "d" #'orajs-disconnect
  "e" #'orajs-execute
  "k" #'orajs-cancel
  "r" #'orajs-refresh-cache
  "s" #'orajs-download-schemas
  "o" #'orajs-show-output
  "t" #'orajs-make-tags)

(defvar-keymap orajs-mode-map
  "C-c C-c" #'orajs-execute)

(defun orajs--lighter ()
  "Mode-line lighter: the connection, with … while the cache syncs."
  (if (orajs-connected-p)
      (format " Ora[%s]%s" orajs--connection (if orajs--syncing "…" ""))
    " Ora"))

;;;###autoload
(define-minor-mode orajs-mode
  "Run Oracle SQL and PL/SQL from this buffer, with schema completion.
\\{orajs-mode-map}"
  :lighter (:eval (orajs--lighter))
  :keymap orajs-mode-map
  (if orajs-mode
      (progn
        (when (derived-mode-p 'sql-mode) (sql-set-product 'oracle))
        (add-hook 'completion-at-point-functions #'orajs-completion-at-point nil t)
        (add-hook 'xref-backend-functions #'orajs--xref-backend nil t))
    (remove-hook 'completion-at-point-functions #'orajs-completion-at-point t)
    (remove-hook 'xref-backend-functions #'orajs--xref-backend t)))

;;;###autoload
(defun orajs-setup ()
  "Open .sql and PL/SQL package files in `sql-mode' with `orajs-mode' on."
  (add-to-list 'auto-mode-alist '("\\.\\(pk[bhs]\\|pl[bs]\\)\\'" . sql-mode))
  (add-hook 'sql-mode-hook #'orajs-mode)
  ;; And in SQL buffers opened before this ran: otherwise C-c C-c there is
  ;; still sql-mode's own ("No SQL process started").
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (derived-mode-p 'sql-mode) (not orajs-mode))
        (orajs-mode 1)))))

(provide 'orajs)
;;; orajs.el ends here
