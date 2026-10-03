
# orajs

An Emacs minor mode for connecting an `sql-mode` buffer to an Oracle database. 
It uses **vtable**, **company** and **node-oracledb** Thin mode. 

![query results in a vtable grid and column completion in an sql-mode buffer](./IMG_6581.png)




Commands are in orajs-command-map, which you bind to a prefix of your choice (`C-c o` for example). After your prefix:

  `c`  connect   
  `k`  cancel the running statement   
  `d`  disconnect   
  `o`  show DBMS_OUTPUT (and JavaScript console.log) in `*orajs-output*`

`C-c C-c` executes the statement at point.

Jump to definition (`M-.`, back with `M-,`) first looks in the tags file
if there is one, otherwise in the database.

Company complete using completion-at-point (company-capf).

## Getting Up and Running

You need to have installed Node.js 18 or later (and npm).  The Oracle driver, node-oracledb, is installed by npm into `orajs-driver-directory' on first connect (or 
with M-x orajs-install-driver).

Setup:

```lisp
  (require 'orajs)
  (orajs-setup)
  (keymap-global-set "C-c o" 'orajs-command-map)
  (setq orajs-connections
        '(("mydb" :user "SCOTT" :service "mydb_low"
           :tns-admin "~/wallets/mydb")))
```

Then you go 

`M-x orajs-connect RET mydb` 


Passwords come from :password-file / :wallet-password-file if given, else
auth-source (machine = connection name, login = user, and login =
"wallet" for the wallet password), else a prompt. 


## How To Deploy a JavaScript buffer as an MLE module

While connected to Oracle (23ai or later), switch to your `.js` buffer, and enter:
  
 `M-x orajs-deploy-module`

You will be prompted for the module name. Then it sends Oracle 

`CREATE OR REPLACE MLE MODULE <name> LANGUAGE JAVASCRIPT AS`

followed by the contents of the current `.js` buffer. On success the echo area says "MLE module <name> deployed". Compile errors put point on the JavaScript line and column Oracle reports.


## License

GNU GPL 3.0
