# Connection for the live tests: copy, fill in, and source before running them.
# The user needs DBA-level rights (the tests create and drop schema ORAJS_TEST).
export ORAJS_USER=ADMIN
export ORAJS_SERVICE=mydb_low                 # alias in $ORAJS_TNS_ADMIN/tnsnames.ora
export ORAJS_TNS_ADMIN=$HOME/wallets/mydb     # tnsnames.ora (+ ewallet.pem for mTLS)
export ORAJS_PASSWORD_FILE=$HOME/wallets/mydb/admin.pw
export ORAJS_WALLET_PASSWORD_FILE=$HOME/wallets/mydb/wallet.pw
# export ORAJS_TEST_CUTOFF=2026-12-31          # optional: bridge-test.js refuses to run after this day
