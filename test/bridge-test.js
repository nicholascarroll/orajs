// bridge-test.js — drive orajs-bridge.js over its JSON-lines protocol against a
// real database. Connection from the environment:
//   ORAJS_USER ORAJS_PASSWORD_FILE
//   ORAJS_SERVICE  Easy Connect string (host:port/service) or a tnsnames.ora alias
//   ORAJS_TNS_ADMIN ORAJS_WALLET_PASSWORD_FILE  (optional: tnsnames.ora, mTLS wallet)
// Creates and drops scratch objects named ORAJS_* in the user's own schema.
// ORAJS_TEST_CUTOFF=YYYY-MM-DD (optional): refuse to run after that day.
'use strict';
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const readline = require('readline');

const env = process.env;
const read = (f) => fs.readFileSync(f, 'utf8').trim();

const today = new Date().toLocaleDateString('sv');   // YYYY-MM-DD, local time
if (env.ORAJS_TEST_CUTOFF && today > env.ORAJS_TEST_CUTOFF) {
  console.error(`bridge-test: past ORAJS_TEST_CUTOFF (${env.ORAJS_TEST_CUTOFF}); not creating test objects`);
  process.exit(1);
}

const proc = spawn(process.execPath, [path.join(__dirname, '..', 'orajs-bridge.js')],
                   { stdio: ['pipe', 'pipe', 'inherit'] });
// If the bridge dies (e.g. node-oracledb not installed), the replies we wait
// for never come and Node would exit 0: fail instead.
let quitting = false;
proc.on('exit', (code, signal) => {
  if (quitting) return;
  console.log(`FAIL bridge exited early (${signal || `code ${code}`})`);
  process.exit(1);
});
const waiting = new Map();
readline.createInterface({ input: proc.stdout }).on('line', (l) => {
  const m = JSON.parse(l);
  waiting.get(m.id)(m);
  waiting.delete(m.id);
});
let nextId = 0;
function req(op, args = {}) {
  const id = ++nextId;
  proc.stdin.write(JSON.stringify({ id, op, ...args }) + '\n');
  return new Promise((res) => waiting.set(id, res));
}
async function ok(op, args) {
  const m = await req(op, args);
  if (m.error) {
    const what = args && args.sql ? `${op} ${args.sql.replace(/\s+/g, ' ').slice(0, 60)}` : op;
    throw new Error(`${what}: ${m.error.message}`);
  }
  return m.ok;
}

const ME = (env.ORAJS_USER || '').toUpperCase();
const mine = (rows) => rows.filter((r) => r[0] === ME && r[1].startsWith('ORAJS_'));
// Scratch objects, dropped before (leftovers from a failed run) and after.
const SCRATCH = ['view orajs_recent_orders', 'table orajs_orders purge', 'procedure orajs_broken',
                 'package orajs_pk', 'procedure orajs_tmp'];
const dropScratch = async () => { for (const o of SCRATCH) await req('exec', { sql: `drop ${o}` }); };

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test('connect', async () => {
  const args = { user: env.ORAJS_USER, password: read(env.ORAJS_PASSWORD_FILE),
                 connectString: env.ORAJS_SERVICE };
  if (env.ORAJS_TNS_ADMIN) args.configDir = env.ORAJS_TNS_ADMIN;
  if (env.ORAJS_WALLET_PASSWORD_FILE) {
    args.walletLocation = env.ORAJS_TNS_ADMIN;
    args.walletPassword = read(env.ORAJS_WALLET_PASSWORD_FILE);
  }
  const r = await ok('connect', args);
  assert.equal(r.user, env.ORAJS_USER.toUpperCase());
});

test('paging 250 rows by 100', async () => {
  const r = await ok('exec', { sql: 'select level n from dual connect by level <= 250', maxRows: 100 });
  assert.equal(r.rows.length, 100); assert.equal(r.more, true);
  assert.deepEqual(r.rows[0], ['1']);
  const p2 = await ok('fetch', { maxRows: 100 });
  assert.equal(p2.rows.length, 100); assert.equal(p2.more, true);
  const p3 = await ok('fetch', { maxRows: 100 });
  assert.equal(p3.rows.length, 50); assert.equal(p3.more, false);
  assert.deepEqual(p3.rows[49], ['250']);
  const p4 = await ok('fetch', { maxRows: 100 });
  assert.deepEqual(p4, { rows: [], more: false });
});

test('types come back as exact strings', async () => {
  const r = await ok('exec', { sql: `select 12345678901234567890.123456789 big, 0.1 tenth,
      date '2026-09-30' d, timestamp '2026-09-30 01:02:03.5' ts,
      timestamp '2026-09-30 01:02:03 +10:00' tstz,
      to_clob('long text') c, cast(null as number) nul, hextoraw('CAFE') r,
      'multi' || chr(10) || 'line' ml from dual` });
  assert.deepEqual(r.rows[0], ['12345678901234567890.123456789', '.1',
    '2026-09-30 00:00:00', '2026-09-30 01:02:03.500', '2026-09-29 15:02:03.000 UTC', '(CLOB 9 chars)', null, 'CAFE',
    'multi\nline']);
  assert.deepEqual(r.columns.map((c) => c.type),
    ['NUMBER', 'NUMBER', 'DATE', 'TIMESTAMP', 'TIMESTAMP WITH TIME ZONE', 'CLOB', 'NUMBER', 'RAW', 'VARCHAR2']);
});

test('opaque types: placeholders, contents never fetched', async () => {
  const r = await ok('exec', { sql: `select to_clob(rpad('x', 4000, 'x')) c, to_nclob('n') nc,
      to_blob(hextoraw('DEADBEEF')) b, xmltype('<a/>') x, to_clob(null) nullc,
      interval '1 02:03:04.5' day to second ids, interval '-1-2' year to month iym from dual` });
  assert.deepEqual(r.rows[0], ['(CLOB 4000 chars)', '(NCLOB 1 chars)', '(BLOB 4 bytes)',
    '(XMLTYPE)', null, '+01 02:03:04.500000', '-01-02']);
  assert.deepEqual(r.columns.map((c) => !!c.opaque), [true, true, true, true, true, false, false]);
  // A CURSOR() column used to fail the whole query ("circular structure").
  const cur = await ok('exec', { sql: 'select 1 n, cursor(select 1 from dual) cur from dual' });
  assert.deepEqual(cur.rows, [['1', '(CURSOR)']]);
  assert.equal(cur.columns[1].opaque, true);
});

test('JSON: exact text; over 32 KB falls back to decoded, flagged, paging intact', async () => {
  const small = await ok('exec', { sql: `select json('{"big":12345678901234567890.123456789,"id":9007199254740993}') j from dual` });
  assert.equal(small.rows[0][0], '{"big":12345678901234567890.123456789,"id":9007199254740993}');
  assert.equal(small.columns[0].json, true);
  assert.equal(small.jsonDecoded, undefined);
  // Rows 1..150 small, row 151 over 32 KB: the fallback happens mid-way through page 2.
  const sql = `select n, case when n = 151 then (select json_arrayagg(level returning json) from dual connect by level <= 20000)
               else json('[' || n || ']') end j from (select level n from dual connect by level <= 160) order by n`;
  const p1 = await ok('exec', { sql, maxRows: 100 });
  assert.equal(p1.rows.length, 100); assert.equal(p1.jsonDecoded, undefined);
  assert.equal(p1.rows[99][1], '[100]');
  const p2 = await ok('fetch', { maxRows: 100 });
  assert.equal(p2.jsonDecoded, true);
  assert.deepEqual(p2.rows.map((r) => r[0]).slice(0, 2), ['101', '102']);   // no row lost or repeated
  assert.equal(p2.rows.length, 60);
  assert.ok(p2.rows[50][1].startsWith('[1,2,3,'));
  // A query that is too big from its first row falls back straight away.
  const big = await ok('exec', { sql: 'select json_arrayagg(level returning json) j from dual connect by level <= 20000' });
  assert.equal(big.jsonDecoded, true);
  assert.ok(big.rows[0][0].endsWith(',20000]'));
});

test('DBMS_OUTPUT: lines after a statement, none after a query, kept with an error', async () => {
  const r = await ok('exec', { sql: "begin dbms_output.put_line('one'); dbms_output.put_line(null); dbms_output.put_line('three'); end;" });
  assert.deepEqual(r.output, ['one', '', 'three']);
  const q = await ok('exec', { sql: 'select * from dual' });
  assert.equal(q.output, undefined);    // Oracle's extra null entry is not a line
  const e = await req('exec', { sql: "begin dbms_output.put_line('before'); raise_application_error(-20001, 'boom'); end;" });
  assert.equal(e.error.code, 20001);
  assert.deepEqual(e.error.output, ['before']);
  const many = await ok('exec', { sql: "begin for i in 1 .. 2500 loop dbms_output.put_line('line ' || i); end loop; end;" });
  assert.equal(many.output.length, 2500);     // read in batches of 1000
  assert.equal(many.output[2499], 'line 2500');
  const long = await ok('exec', { sql: "begin dbms_output.put_line(rpad('x', 32767, 'x')); end;" });
  assert.equal(long.output[0].length, 32767);
  await ok('serverOutput', { on: false });
  const off = await ok('exec', { sql: "begin dbms_output.put_line('hidden'); end;" });
  assert.equal(off.output, undefined);
  await ok('serverOutput', { on: true });
});

test('SQL error carries code and offset', async () => {
  const m = await req('exec', { sql: 'select * from no_such_table_xyz' });
  assert.equal(m.error.code, 942);
  assert.equal(m.error.offset, 14);
  assert.match(m.error.message, /^ORA-00942/);
});

test('scratch objects: DDL, DML rowsAffected, PL/SQL, compile warning', async () => {
  await dropScratch();
  await ok('exec', { sql: 'create table orajs_orders (id number primary key, customer varchar2(40), placed date)' });
  await ok('exec', { sql: 'create view orajs_recent_orders as select id, placed from orajs_orders' });
  const ins = await ok('exec', { sql: "insert into orajs_orders select level, 'c' || level, sysdate from dual connect by level <= 3" });
  assert.equal(ins.rowsAffected, 3);
  const upd = await ok('exec', { sql: "-- note\nupdate orajs_orders set customer = 'x' where id = 1" });
  assert.equal(upd.rowsAffected, 1);
  const ddl = await ok('exec', { sql: 'create index orajs_ix on orajs_orders (customer)' });
  assert.equal(ddl.rowsAffected, undefined);
  const plsql = await ok('exec', { sql: 'begin null; end;' });
  assert.equal(plsql.columns, undefined);
  const bad = await ok('exec', { sql: 'create or replace procedure orajs_broken as\nbegin\n  nonsense;\nend;' });
  assert.equal(bad.compileErrors.object, `${ME}.ORAJS_BROKEN`);
  assert.equal(bad.compileErrors.type, 'PROCEDURE');
  assert.equal(bad.compileErrors.errors[0].line, 3);
  assert.match(bad.compileErrors.errors[0].text, /NONSENSE/);
  const good = await ok('exec', { sql: `create or replace package orajs_pk as
      procedure p;
      function f return number;
      procedure o(a number);
      procedure o(a varchar2);
    end;` });
  assert.equal(good.compileErrors, undefined);
  await ok('exec', { sql: 'rollback' });
});

test('objects lists user tables, views and PL/SQL units with DDL times', async () => {
  const r = await ok('objects');
  assert.ok(r.schemas.includes(ME));
  const objs = mine(r.objects);
  assert.deepEqual(objs.map((o) => o.slice(0, 3)), [
    [ME, 'ORAJS_BROKEN', 'PROCEDURE'],
    [ME, 'ORAJS_ORDERS', 'TABLE'],
    [ME, 'ORAJS_PK', 'PACKAGE'],
    [ME, 'ORAJS_RECENT_ORDERS', 'VIEW'],
  ]);
  assert.match(objs[0][3], /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$/);
});

test('summary: count and latest DDL time, moved by DDL', async () => {
  const before = await ok('summary');
  assert.ok(before.count > 0);
  assert.match(before.ddl, /^\d{4}-\d\d-\d\dT/);
  await new Promise((res) => setTimeout(res, 1100));   // LAST_DDL_TIME is to the second
  await ok('exec', { sql: 'create or replace procedure orajs_tmp as begin null; end;' });
  const after = await ok('summary');
  assert.equal(after.count, before.count + 1);
  assert.ok(after.ddl > before.ddl);
  await ok('exec', { sql: 'drop procedure orajs_tmp' });
  assert.equal((await ok('summary')).count, before.count);
});

test('members: package procedures and functions, overloads counted', async () => {
  const all = mine((await ok('members')).rows);
  assert.deepEqual(all, [
    [ME, 'ORAJS_PK', 'F', 'FUNCTION', 1],
    [ME, 'ORAJS_PK', 'O', 'PROCEDURE', 2],
    [ME, 'ORAJS_PK', 'P', 'PROCEDURE', 1],
  ]);
  const some = await ok('members', { packages: [[ME, 'ORAJS_PK'], ['X', 'NOPE']] });
  assert.deepEqual(some.rows, all);
});

test('describe: packages (own and Oracle\'s, through synonyms) and procedures', async () => {
  const r = await ok('describe', { names: ['orajs_pk', 'dbms_output', 'sys.dbms_lob', 'orajs_broken', 'dual'] });
  assert.equal(r.orajs_pk.type, 'PACKAGE');
  assert.deepEqual(r.orajs_pk.members, [['F', 'FUNCTION', 1], ['O', 'PROCEDURE', 2], ['P', 'PROCEDURE', 1]]);
  assert.equal(r.dbms_output.owner, 'SYS');
  assert.ok(r.dbms_output.members.some(([m, k]) => m === 'PUT_LINE' && k === 'PROCEDURE'));
  assert.ok(r['sys.dbms_lob'].members.some(([m, k, n]) => m === 'COMPARE' && k === 'FUNCTION' && n > 1));
  assert.deepEqual(r.orajs_broken, { owner: ME, name: 'ORAJS_BROKEN', type: 'PROCEDURE' });
  assert.equal(r.dual.type, 'TABLE');                 // tables still come with columns
  assert.deepEqual(r.dual.columns, [['DUMMY', 'VARCHAR2']]);
});

test('columns: all, or just the listed tables', async () => {
  const all = mine((await ok('columns')).rows);
  assert.deepEqual(all, [
    [ME, 'ORAJS_ORDERS', 'ID', 'NUMBER'],
    [ME, 'ORAJS_ORDERS', 'CUSTOMER', 'VARCHAR2'],
    [ME, 'ORAJS_ORDERS', 'PLACED', 'DATE'],
    [ME, 'ORAJS_RECENT_ORDERS', 'ID', 'NUMBER'],
    [ME, 'ORAJS_RECENT_ORDERS', 'PLACED', 'DATE'],
  ]);
  const some = await ok('columns', { tables: [[ME, 'ORAJS_RECENT_ORDERS'], ['X', 'NOPE']] });
  assert.deepEqual(some.rows, all.slice(3));
});

test('dictionary names, keyed by server version', async () => {
  const d = await ok('dictionary');
  const names = new Map(d.rows);
  assert.match(d.server, /^\d+\.\d+/);
  assert.ok(d.rows.length > 1000);
  assert.match(names.get('ALL_TAB_COLUMNS'), /column/i);   // Oracle's comment; wording varies by release
  assert.ok(names.has('DUAL'));
  assert.ok(names.has('V$SESSION'));
  assert.ok(d.packages.includes('DBMS_OUTPUT'));    // Oracle's packages, by public synonym
  assert.ok(d.packages.includes('UTL_FILE'));
});

test('describe resolves own tables, synonyms and qualified names', async () => {
  const r = await ok('describe', { names: ['dual', 'all_tab_columns', 'v$session', 'sys.dual',
                                            'orajs_orders', 'no_such_thing', 'a.b.c'] });
  assert.deepEqual(r.dual, { owner: 'SYS', name: 'DUAL', type: 'TABLE', columns: [['DUMMY', 'VARCHAR2']] });
  assert.equal(r.all_tab_columns.owner, 'SYS');
  assert.ok(r.all_tab_columns.columns.some(([n]) => n === 'DATA_TYPE'));
  assert.equal(r['v$session'].name, 'V_$SESSION');
  assert.equal(r['sys.dual'].name, 'DUAL');
  assert.deepEqual(r.orajs_orders.columns.map(([n]) => n), ['ID', 'CUSTOMER', 'PLACED']);
  assert.equal(r.no_such_thing, null);
  assert.equal(r['a.b.c'], null);
});

test('resolve, source and ddl (jump to definition)', async () => {
  const pk = (await ok('resolve', { name: 'orajs_pk' })).object;
  assert.deepEqual(pk, { owner: ME, name: 'ORAJS_PK', type: 'PACKAGE', via: [] });
  const dbo = (await ok('resolve', { name: 'dbms_output' })).object;
  assert.equal(dbo.owner, 'SYS');
  assert.deepEqual(dbo.via, ['PUBLIC.DBMS_OUTPUT']);          // the synonym's own owner
  assert.equal((await ok('resolve', { name: 'no_such_thing' })).object, null);
  const spec = await ok('source', { owner: ME, name: 'ORAJS_PK', type: 'PACKAGE' });
  assert.match(spec.text, /^package\s+orajs_pk\s+as/i);            // stored without CREATE OR REPLACE
  const none = await ok('source', { owner: ME, name: 'ORAJS_PK', type: 'PACKAGE BODY' });
  assert.equal(none.text, null);
  const ddl = await ok('ddl', { owner: ME, name: 'ORAJS_ORDERS', type: 'TABLE' });
  assert.ok(ddl.text.includes(`CREATE TABLE "${ME}"."ORAJS_ORDERS"`));
  assert.match(ddl.text, /"CUSTOMER" VARCHAR2\(40\)/);
});

test('break interrupts a long query', async () => {
  const t0 = Date.now();
  // A cartesian product of small row sources: slow, but light on memory
  // (one big CONNECT BY runs out, ORA-30009, on a small database).
  const running = req('exec', { sql: `select count(*) from
      (select 1 from dual connect by level <= 10000),
      (select 1 from dual connect by level <= 10000),
      (select 1 from dual connect by level <= 10000)` });
  await new Promise((r) => setTimeout(r, 1500));
  await ok('break');
  const m = await running;
  assert.equal(m.error.code, 1013);   // ORA-01013: user requested cancel
  assert.ok(Date.now() - t0 < 15000);
});

test('cleanup', dropScratch);

(async () => {
  let failed = 0;
  for (const [name, fn] of tests) {
    try { await fn(); console.log(`ok   ${name}`); }
    catch (e) { failed++; console.log(`FAIL ${name}\n     ${e.message.split('\n').join('\n     ')}`); }
  }
  quitting = true;
  await req('quit');
  console.log(failed ? `${failed} failed` : 'all passed');
  process.exit(failed ? 1 : 0);
})();
