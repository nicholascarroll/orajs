#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Part of orajs: https://github.com/nicholascarroll/orajs
// This is a ridge between Emacs (orajs.el) and Oracle.
//
// One process = one database connection (node-oracledb Thin mode: pure JS,
// no Instant Client). Protocol: one JSON object per line on stdin/stdout.
//
//   request:  {"id": 7, "op": "exec", ...args}
//   reply:    {"id": 7, "ok": {...}}   or   {"id": 7, "error": {"message", "code", "offset"}}
//
// exec and fetch replies carry "output": DBMS_OUTPUT lines, when there are any.
// Ops: connect, exec, fetch, serverOutput, summary, objects, columns, members,
// dictionary, describe, resolve, source, ddl, break, quit. Requests are handled as they
// arrive, so "break" can interrupt a running "exec". The connection keeps one
// open cursor (the last query); a new exec closes it.
'use strict';

const readline = require('readline');
const oracledb = require('oracledb');

// Oracle-maintained-but-not-flagged accounts every Autonomous Database has.
const ADB_INTERNAL = ['ADBSNMP', 'ADB_APP_STORE', 'DCAT_ADMIN', 'GGADMIN',
                      'RMAN$CATALOG', 'RMAN$VPC'];

let conn = null;
let cursor = null;
const session = { user: null, serverOutput: false };

// DBMS_OUTPUT, which is also where console.log from JavaScript (MLE) code
// goes: read after every exec, including failed ones (the lines logged
// before an exception are the useful ones).
const OUTPUT_BATCH = 1000;
async function drainOutput() {
  if (!conn || !session.serverOutput) return [];
  const lines = [];
  for (;;) {
    const r = await conn.execute(
      'begin dbms_output.get_lines(:lines, :n); end;',
      { lines: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 32767,
                 maxArraySize: OUTPUT_BATCH },
        n: { dir: oracledb.BIND_INOUT, type: oracledb.NUMBER, val: OUTPUT_BATCH } });
    // Only the first n entries are lines: the array Oracle returns has
    // one more (a null) than it reports, so ignoring n printed a blank
    // line after every statement.
    const n = r.outBinds.n;
    for (const l of (r.outBinds.lines || []).slice(0, n)) lines.push(l === null ? '' : l);
    if (n < OUTPUT_BATCH) break;
  }
  return lines;
}

// Everything that is not already a plain JS value comes back as a string, so
// Emacs shows exactly what Oracle has (no float rounding of NUMBERs). Thin mode
// ignores NLS when turning dates into strings, so dates are fetched as JS Dates
// and formatted here (millisecond precision; TZ types shown in UTC).
const pad = (n, w = 2) => String(n).padStart(w, '0');
function fmtLocal(d, frac) {
  if (d === null) return null;
  const s = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
            `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  return frac ? `${s}.${pad(d.getMilliseconds(), 3)}` : s;
}
const fmtUtc = (d) => (d === null ? null : d.toISOString().replace('T', ' ').replace('Z', ' UTC'));

// XMLTYPE: a converter cannot tell NULL from a value (it sees {} for both),
// so the placeholder is put in after the fetch; see page().

// Opaque columns: large or structured values orajs does not show. The grid
// gets a placeholder like "(CLOB 50000 chars)" -- LOB contents are never
// read, so a query over big LOBs costs no more than one over numbers.
const lobPlaceholder = (kind, unit) => (lob) => {
  if (lob === null) return null;
  const text = lob.length === undefined ? `(${kind})` : `(${kind} ${lob.length} ${unit})`;
  lob.destroy();   // frees a temporary LOB (to_clob(...)) on the server
  return text;
};
const OPAQUE = new Set([oracledb.DB_TYPE_CLOB, oracledb.DB_TYPE_NCLOB, oracledb.DB_TYPE_BLOB,
                        oracledb.DB_TYPE_BFILE, oracledb.DB_TYPE_XMLTYPE, oracledb.DB_TYPE_OBJECT,
                        oracledb.DB_TYPE_CURSOR]);
const isOpaque = (meta) => OPAQUE.has(meta.dbType);

// INTERVAL as Oracle prints it: +01 02:03:04.500000, +01-02.
const sign = (n) => (n < 0 ? '-' : '+');
function fmtIntervalDS(v) {
  if (v === null) return null;
  const neg = [v.days, v.hours, v.minutes, v.seconds, v.fseconds].some((n) => n < 0);
  const a = (n) => Math.abs(n || 0);
  return `${neg ? '-' : '+'}${pad(a(v.days))} ${pad(a(v.hours))}:${pad(a(v.minutes))}:` +
         `${pad(a(v.seconds))}.${String(Math.round(a(v.fseconds) / 1000)).padStart(6, '0')}`;
}
const fmtIntervalYM = (v) => (v === null ? null
  : `${sign(v.years + v.months)}${pad(Math.abs(v.years))}-${pad(Math.abs(v.months))}`);

function fetchType(meta) {
  switch (meta.dbType) {
    case oracledb.DB_TYPE_NUMBER:
    case oracledb.DB_TYPE_BINARY_FLOAT:
    case oracledb.DB_TYPE_BINARY_DOUBLE:
      return { type: oracledb.STRING };
    case oracledb.DB_TYPE_CLOB:
      return { converter: lobPlaceholder('CLOB', 'chars') };
    case oracledb.DB_TYPE_NCLOB:
      return { converter: lobPlaceholder('NCLOB', 'chars') };
    case oracledb.DB_TYPE_BLOB:
      return { converter: lobPlaceholder('BLOB', 'bytes') };
    case oracledb.DB_TYPE_BFILE:
      return { converter: (v) => (v === null ? null : '(BFILE)') };
    case oracledb.DB_TYPE_JSON:
      // As text: exact. Decoded to JS values, 12345678901234567890.1 and
      // 64-bit integers would lose digits.
      return { type: oracledb.STRING };
    case oracledb.DB_TYPE_OBJECT:   // SDO_GEOMETRY and every other object/collection type
      return { converter: (v) => (v === null ? null : `(${meta.dbTypeName})`) };
    case oracledb.DB_TYPE_CURSOR:
      return { converter: (rs) => { if (rs === null) return null; rs.close().catch(() => {}); return '(CURSOR)'; } };
    case oracledb.DB_TYPE_INTERVAL_DS:
      return { converter: fmtIntervalDS };
    case oracledb.DB_TYPE_INTERVAL_YM:
      return { converter: fmtIntervalYM };
    case oracledb.DB_TYPE_DATE:
      return { converter: (d) => fmtLocal(d, false) };
    case oracledb.DB_TYPE_TIMESTAMP:
      return { converter: (d) => fmtLocal(d, true) };
    case oracledb.DB_TYPE_TIMESTAMP_TZ:
    case oracledb.DB_TYPE_TIMESTAMP_LTZ:
      return { converter: fmtUtc };
    default:
      return undefined;
  }
}
oracledb.fetchTypeHandler = fetchType;

// Fallback when a JSON document is over 32 KB (ORA-40478: the text conversion
// goes through VARCHAR2): the driver's own decoding, which never fails but
// turns numbers into JS doubles (beyond ~15 digits they are rounded).
const fetchTypeJsonDecoded = (meta) => (meta.dbType === oracledb.DB_TYPE_JSON ? undefined : fetchType(meta));
const JSON_TOO_BIG = 40478;
const QUERY = /^\s*(?:\/\*[\s\S]*?\*\/\s*|--[^\n]*\n\s*)*(?:select|with|\()/i;

// CREATE [OR REPLACE] [EDITIONABLE] <plsql unit | MLE MODULE> [owner.]name — Thin mode does
// not report ORA-24344 "success with compilation error", so after one of these
// the bridge reads ALL_ERRORS itself.
const PLSQL_CREATE = new RegExp(String.raw`^\s*create\s+(?:or\s+replace\s+)?` +
  String.raw`(?:(?:editionable|noneditionable)\s+)?` +
  String.raw`(package\s+body|package|procedure|function|trigger|type\s+body|type|mle\s+module)\s+` +
  String.raw`(?:if\s+not\s+exists\s+)?` +
  String.raw`(?:("[^"]+"|[\w$#]+)\s*\.\s*)?("[^"]+"|[\w$#]+)`, 'i');
// Only DML has a meaningful row count (the driver reports 0 for DDL too).
const DML = /^\s*(?:\/\*[\s\S]*?\*\/\s*|--[^\n]*\n\s*)*(?:insert|update|delete|merge)\b/i;
const ident = (s) => (s.startsWith('"') ? s.slice(1, -1) : s.toUpperCase());

async function compileErrors(sql) {
  const m = PLSQL_CREATE.exec(sql);
  if (!m) return null;
  const type = m[1].toUpperCase().replace(/\s+/, ' ');
  const owner = m[2] ? ident(m[2]) : session.user;
  const name = ident(m[3]);
  const r = await conn.execute(
    `select line, position, attribute, text from all_errors
     where owner = :owner and name = :name and type = :type order by sequence`,
    { owner, name, type });
  if (!r.rows.length) return null;
  return { object: `${owner}.${name}`, type,
           errors: r.rows.map(([line, position, attribute, text]) =>
             ({ line: Number(line), position: Number(position), attribute, text })) };
}

function cell(v) {
  if (v === null || v === undefined) return null;
  if (typeof v === 'string') return v;
  if (Buffer.isBuffer(v)) return v.toString('hex').toUpperCase();          // RAW
  if (v instanceof Date) return v.toISOString();
  if (ArrayBuffer.isView(v)) return '[' + Array.from(v).join(',') + ']';  // VECTOR
  if (typeof v === 'object') {                                             // JSON
    // RAW inside JSON (a duality view's _metadata.etag) as Oracle shows it:
    // hex, not Node's {"type":"Buffer","data":[...]}.
    try {
      return JSON.stringify(v, function (k, x) {
        const orig = this[k];
        if (Buffer.isBuffer(orig) || orig instanceof Uint8Array) return Buffer.from(orig).toString('hex').toUpperCase();
        return typeof x === 'bigint' ? x.toString() : x;
      });
    }
    catch (_) { return `(${v.constructor ? v.constructor.name : 'object'})`; }
  }
  return String(v);
}

const rowOut = (r) => r.map(cell);

async function closeCursor() {
  if (!cursor) return;
  const c = cursor;
  cursor = null;
  try { await c.close(); } catch (_) { /* already gone */ }
}

let xmlColumns = [];   // indexes of XMLTYPE columns of the open cursor
// The open query, to re-run it with decoded JSON if a document is too big.
let query = null;      // { sql, fetchArraySize, seen: rows returned so far, jsonDecoded }

async function openQuery(sql, fetchArraySize, jsonDecoded) {
  return conn.execute(sql, {}, {
    resultSet: true,
    outFormat: oracledb.OUT_FORMAT_ARRAY,
    fetchArraySize,
    fetchTypeHandler: jsonDecoded ? fetchTypeJsonDecoded : fetchType,
  });
}

// Re-run the open query with decoded JSON and skip the rows already shown.
async function reopenJsonDecoded() {
  await closeCursor();
  const r = await openQuery(query.sql, query.fetchArraySize, true);
  cursor = r.resultSet;
  query.jsonDecoded = true;
  let skip = query.seen;
  while (skip > 0) {
    const got = await cursor.getRows(Math.min(skip, 1000));
    if (!got.length) break;
    skip -= got.length;
  }
}

async function page(n) {
  let raw;
  try {
    raw = await cursor.getRows(n);
  } catch (e) {
    if (e.errorNum !== JSON_TOO_BIG || !query || query.jsonDecoded) throw e;
    await reopenJsonDecoded();
    raw = await cursor.getRows(n);
  }
  const rows = raw.map(rowOut);
  query.seen += rows.length;
  const more = rows.length === n;
  const jsonDecoded = query.jsonDecoded;
  if (!more) await closeCursor();
  for (const r of rows) for (const i of xmlColumns) if (r[i] !== null) r[i] = '(XMLTYPE)';
  return jsonDecoded ? { rows, more, jsonDecoded } : { rows, more };
}

async function columnsOf(owner, name) {
  const r = await conn.execute(
    `select c.column_name, c.data_type, o.object_type
     from   all_tab_columns c
     join   all_objects o on o.owner = c.owner and o.object_name = c.table_name
                         and o.object_type in ('TABLE', 'VIEW', 'MATERIALIZED VIEW')
     where  c.owner = :owner and c.table_name = :name
     order  by c.column_id`, { owner, name });
  if (!r.rows.length) return null;
  return { owner, name, type: r.rows[0][2], columns: r.rows.map(([n, t]) => [n, t]) };
}

async function synonymTarget(owners, name) {
  const r = await conn.execute(
    `select table_owner, table_name, owner from all_synonyms
     where  owner in (${owners.map((_, i) => ':o' + i).join(',')}) and synonym_name = :name
     order  by decode(owner, 'PUBLIC', 2, 1)`,
    Object.assign({ name }, ...owners.map((o, i) => ({ ['o' + i]: o }))));
  return r.rows.length ? { owner: r.rows[0][0], name: r.rows[0][1], synonymOwner: r.rows[0][2] } : null;
}

// Procedures and functions of packages, as [owner, package, name, kind,
// overloads] rows, kind FUNCTION when any overload returns a value (a
// position-0 argument). FILTER restricts all_procedures p.
const MEMBERS = (filter) => `
  select p.owner, p.object_name, p.procedure_name,
         case when max(a.position) is not null then 'FUNCTION' else 'PROCEDURE' end,
         count(distinct p.subprogram_id)
  from   all_procedures p
  left   join all_arguments a
         on  a.owner = p.owner and a.package_name = p.object_name
         and a.object_name = p.procedure_name and a.subprogram_id = p.subprogram_id
         and a.position = 0 and a.data_level = 0
  where  p.object_type = 'PACKAGE' and p.procedure_name is not null and ${filter}
  group  by p.owner, p.object_name, p.procedure_name
  order  by 1, 2, 3`;

async function membersOf(owner, name) {
  const r = await conn.execute(MEMBERS('p.owner = :owner and p.object_name = :name'),
                               { owner, name });
  return r.rows.map(([, , m, kind, n]) => [m, kind, Number(n)]);
}

// What a name is: a table/view (with its columns), a package (with its
// procedures and functions), or a standalone procedure/function.
const DESCRIBED = "('TABLE', 'VIEW', 'MATERIALIZED VIEW', 'PACKAGE', 'PROCEDURE', 'FUNCTION')";
async function objectType(owner, name) {
  const r = await conn.execute(
    `select object_type from all_objects
     where  owner = :owner and object_name = :name and object_type in ${DESCRIBED}
     order  by decode(object_type, 'TABLE', 1, 'VIEW', 2, 'MATERIALIZED VIEW', 3, 'PACKAGE', 4, 5)`,
    { owner, name });
  return r.rows.length ? r.rows[0][0] : null;
}

async function describeObject(owner, name, type) {
  if (type === 'PACKAGE') return { owner, name, type, members: await membersOf(owner, name) };
  if (type === 'PROCEDURE' || type === 'FUNCTION') return { owner, name, type };
  return columnsOf(owner, name);
}

// Jump-to-definition: what a name written in SQL is, the way Oracle would
// resolve it (own object, private synonym, public synonym, following
// chains), including object types completion does not care about.
const DEFINED = "('TABLE', 'VIEW', 'MATERIALIZED VIEW', 'PACKAGE', 'PROCEDURE', 'FUNCTION', " +
  "'TRIGGER', 'TYPE', 'SEQUENCE', 'MLE MODULE')";
async function definedType(owner, name) {
  const r = await conn.execute(
    `select object_type from all_objects
     where  owner = :owner and object_name = :name and object_type in ${DEFINED}
     order  by decode(object_type, 'TABLE', 1, 'VIEW', 2, 'MATERIALIZED VIEW', 3,
                      'PACKAGE', 4, 'TYPE', 5, 6)`,
    { owner, name });
  return r.rows.length ? r.rows[0][0] : null;
}

async function resolve(written) {
  const parts = written.split('.');
  if (parts.length > 2 || parts.some((p) => !p)) return null;
  let owner = parts.length === 2 ? ident(parts[0]) : session.user;
  let name = ident(parts[parts.length - 1]);
  const synOwners = parts.length === 2 ? [owner] : [session.user, 'PUBLIC'];
  const via = [];
  for (let hop = 0; hop < 4; hop++) {
    const type = await definedType(owner, name);
    if (type) return { owner, name, type, via };
    const t = await synonymTarget(hop === 0 ? synOwners : [owner], name);
    if (!t) return null;
    via.push(`${t.synonymOwner}.${name}`);
    ({ owner, name } = t);
  }
  return null;
}

async function describe(written) {
  const parts = written.split('.');
  if (parts.length > 2 || parts.some((p) => !p)) return null;
  let owner = parts.length === 2 ? ident(parts[0]) : session.user;
  let name = ident(parts[parts.length - 1]);
  const synOwners = parts.length === 2 ? [owner] : [session.user, 'PUBLIC'];
  for (let hop = 0; hop < 4; hop++) {
    const type = await objectType(owner, name);
    if (type) return describeObject(owner, name, type);
    const t = await synonymTarget(hop === 0 ? synOwners : [owner], name);
    if (!t) return null;
    ({ owner, name } = t);
  }
  return null;
}

// What the schema cache holds: tables, views, and PL/SQL program units.
const CACHED = "('TABLE', 'VIEW', 'PACKAGE', 'PROCEDURE', 'FUNCTION')";

// Schemas worth caching: not Oracle's, not Autonomous Database's own.
const USERS = `select username from all_users
               where oracle_maintained = 'N'
               and username not in (${ADB_INTERNAL.map((u) => `'${u}'`).join(',')})`;

// Run one statement; a query leaves its cursor open for "fetch".
async function execStatement(a) {
  await closeCursor();
  const fetchArraySize = Math.max(a.maxRows || 100, 100);
  let r;
  let jsonDecoded = false;
  try {
    r = await openQuery(a.sql, fetchArraySize, false);
  } catch (e) {
    // Only a query may be run again: never repeat DML or PL/SQL.
    if (e.errorNum !== JSON_TOO_BIG || !QUERY.test(a.sql)) throw e;
    r = await openQuery(a.sql, fetchArraySize, true);
    jsonDecoded = true;
  }
  const out = {};
  if (r.warning) out.warning = { message: r.warning.message, code: r.warning.errorNum };
  const ce = await compileErrors(a.sql);
  if (ce) out.compileErrors = ce;
  if (r.resultSet) {
    cursor = r.resultSet;
    query = { sql: a.sql, fetchArraySize, seen: 0, jsonDecoded };
    xmlColumns = r.metaData.flatMap((m, i) => (m.dbType === oracledb.DB_TYPE_XMLTYPE ? [i] : []));
    out.columns = r.metaData.map((m) => Object.assign(
      { name: m.name, type: m.dbTypeName },
      isOpaque(m) ? { opaque: true } : {},
      m.dbType === oracledb.DB_TYPE_JSON ? { json: true } : {}));
    Object.assign(out, await page(a.maxRows || 100));
  } else if (r.rowsAffected !== undefined && DML.test(a.sql)) {
    out.rowsAffected = r.rowsAffected;
  }
  return out;
}

const ops = {
  async connect(a) {
    if (conn) { await closeCursor(); await conn.close(); conn = null; }
    conn = await oracledb.getConnection({
      user: a.user,
      password: a.password,
      connectString: a.connectString,
      configDir: a.configDir,
      walletLocation: a.walletLocation,
      walletPassword: a.walletPassword,
    });
    const r = await conn.execute(`select user, sys_context('userenv','con_name') from dual`);
    session.user = r.rows[0][0];
    session.serverOutput = a.serverOutput !== false;
    if (session.serverOutput) await conn.execute('begin dbms_output.enable(null); end;');
    return { user: r.rows[0][0], container: r.rows[0][1], server: conn.oracleServerVersionString };
  },

  async exec(a) {
    let out;
    try {
      out = await execStatement(a);
    } catch (e) {
      e.orajsOutput = await drainOutput().catch(() => []);
      throw e;
    }
    const output = await drainOutput();
    if (output.length) out.output = output;
    return out;
  },

  // SET SERVEROUTPUT ON|OFF, as typed in a worksheet (a SQL*Plus command,
  // so not something to send to the database as SQL).
  async serverOutput(a) {
    session.serverOutput = !!a.on;
    await conn.execute(a.on ? 'begin dbms_output.enable(null); end;'
                            : 'begin dbms_output.disable; end;');
    return { on: session.serverOutput };
  },

  async fetch(a) {
    if (!cursor) return { rows: [], more: false };
    const out = await page(a.maxRows || 100);
    const output = await drainOutput();   // functions called by later rows
    if (output.length) out.output = output;
    return out;
  },
  // The schema cache is kept by Emacs (on disk) and synced incrementally:
  // objects lists every table/view of the user schemas with its DDL time;
  // columns is then asked only for the ones that are new or changed.
  // Cheap change check: how many cacheable objects, and the latest DDL
  // time. Any CREATE/ALTER moves the time; any DROP moves the count.
  async summary() {
    const r = await conn.execute(
      `select count(*), to_char(max(last_ddl_time), 'YYYY-MM-DD"T"HH24:MI:SS')
       from   all_objects
       where  owner in (${USERS}) and object_type in ${CACHED}
       and    object_name not like 'BIN$%'`);
    return { count: Number(r.rows[0][0]), ddl: r.rows[0][1] };
  },

  async objects() {
    const s = await conn.execute(`${USERS} order by 1`);
    const o = await conn.execute(
      `select owner, object_name, object_type,
              to_char(last_ddl_time, 'YYYY-MM-DD"T"HH24:MI:SS')
       from   all_objects
       where  owner in (${USERS}) and object_type in ${CACHED}
       and    object_name not like 'BIN$%'
       order  by owner, object_name`,
      {}, { fetchArraySize: 1000 });
    return { schemas: s.rows.map((r) => r[0]), objects: o.rows };
  },

  // Package members as [owner, package, name, kind, overloads] rows: of the
  // given [owner, package] pairs, or of every package in the user schemas.
  async members(a) {
    const opts = { fetchArraySize: 1000 };
    const r = a.packages
      ? await conn.execute(MEMBERS(`(p.owner, p.object_name) in
          (select o, n from json_table(:j, '$[*]' columns (o varchar2(128) path '$[0]',
                                                            n varchar2(128) path '$[1]')))`),
        { j: { val: JSON.stringify(a.packages), type: oracledb.DB_TYPE_CLOB } }, opts)
      : await conn.execute(MEMBERS(`p.owner in (${USERS})`), {}, opts);
    return { rows: r.rows.map(([o, p, m, kind, n]) => [o, p, m, kind, Number(n)]) };
  },

  // Columns as [owner, table, column, type] rows, ordered by table and
  // column_id: of the given [owner, table] pairs, or of every table/view in
  // the user schemas when no list is given.
  async columns(a) {
    const opts = { fetchArraySize: 1000 };
    const r = a.tables
      ? await conn.execute(
        `select c.owner, c.table_name, c.column_name, c.data_type
         from   json_table(:j, '$[*]' columns (o varchar2(128) path '$[0]',
                                               n varchar2(128) path '$[1]')) j
         join   all_tab_columns c on c.owner = j.o and c.table_name = j.n
         order  by c.owner, c.table_name, c.column_id`,
        { j: { val: JSON.stringify(a.tables), type: oracledb.DB_TYPE_CLOB } }, opts)
      : await conn.execute(
        `select owner, table_name, column_name, data_type
         from   all_tab_columns
         where  owner in (${USERS})
         order  by owner, table_name, column_id`, {}, opts);
    return { rows: r.rows };
  },

  // Data dictionary views (ALL_*, USER_*, DBA_*, V$*, DUAL ...): names and
  // descriptions; their columns come on demand from describe. Only changes
  // with the database version, which is returned to key the cache.
  // Also the names of Oracle's packages (DBMS_OUTPUT, UTL_FILE ...): public
  // synonyms of packages. Their members come on demand from describe.
  async dictionary() {
    const d = await conn.execute(
      `select table_name, substr(comments, 1, 60) from dictionary order by 1`,
      {}, { fetchArraySize: 1000 });
    const p = await conn.execute(
      `select s.synonym_name from all_synonyms s
       where  s.owner = 'PUBLIC'
       and    exists (select 1 from all_objects o where o.owner = s.table_owner
                      and o.object_name = s.table_name and o.object_type = 'PACKAGE')
       order  by 1`, {}, { fetchArraySize: 1000 });
    return { server: conn.oracleServerVersionString, rows: d.rows,
             packages: p.rows.map((r) => r[0]) };
  },

  // Jump to definition: what NAME is ({owner, name, type, via: synonyms
  // followed}), or null.
  async resolve(a) {
    return { object: await resolve(a.name) };
  },

  // Stored source (ALL_SOURCE) of a PL/SQL unit or MLE module, as one string;
  // null when there is none (e.g. no package body).
  async source(a) {
    const r = await conn.execute(
      `select text from all_source
       where  owner = :owner and name = :name and type = :type order by line`,
      { owner: a.owner, name: a.name, type: a.type }, { fetchArraySize: 1000 });
    return { text: r.rows.length ? r.rows.map((x) => x[0]).join('') : null };
  },

  // DDL of a table, view, sequence ... from DBMS_METADATA, as text.
  async ddl(a) {
    const r = await conn.execute(
      `select dbms_metadata.get_ddl(:type, :name, :owner) from dual`,
      { type: a.type.replace(/ /g, '_'), name: a.name, owner: a.owner },
      { fetchTypeHandler: (m) => (m.dbType === oracledb.DB_TYPE_CLOB
                                    ? { type: oracledb.STRING } : undefined) });
    return { text: r.rows[0][0] };
  },

  // Columns of tables/views named as written in SQL ("dual", "hr.emp",
  // "v$session"), resolved the way Oracle would: own object, then private
  // synonym, then public synonym (following synonym chains). Unresolvable
  // names come back as null.
  async describe(a) {
    const out = {};
    for (const written of a.names) out[written] = await describe(written);
    return out;
  },

  async break() {
    if (conn) await conn.break();
    return {};
  },

  async quit() {
    await closeCursor();
    if (conn) { await conn.close(); conn = null; }
    setImmediate(() => process.exit(0));
    return {};
  },
};

function reply(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

async function handle(line) {
  let req;
  try { req = JSON.parse(line); } catch (e) { reply({ id: null, error: { message: 'bad JSON: ' + e.message } }); return; }
  const { id, op } = req;
  const fn = ops[op];
  if (!fn) { reply({ id, error: { message: `unknown op: ${op}` } }); return; }
  if (op !== 'connect' && op !== 'quit' && !conn) { reply({ id, error: { message: 'not connected' } }); return; }
  try {
    reply({ id, ok: await fn(req) });
  } catch (e) {
    const error = { message: e.message, code: e.errorNum, offset: e.offset };
    if (e.orajsOutput && e.orajsOutput.length) error.output = e.orajsOutput;
    reply({ id, error });
  }
}

const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on('line', (line) => { if (line.trim()) handle(line); });
rl.on('close', async () => {
  try { await closeCursor(); if (conn) await conn.close(); } catch (_) { /* exiting anyway */ }
  process.exit(0);
});
