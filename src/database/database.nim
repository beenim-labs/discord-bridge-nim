## Lightweight DB bootstrap layer with SQLite/Postgres migration runners.

import std/[os, strutils, osproc]
import database/migrations
import database/sqlite_native

type
  BridgeDb* = ref object
    uri*: string
    dbType*: string
    dialect*: DbDialect
    sqlitePath*: string
    sqliteConn*: SqliteConn

proc sqlPathFromUri*(uri: string): string =
  if uri.len == 0:
    return "discord-bridge.db"
  if uri.startsWith("file:"):
    var p = uri[5 .. ^1]
    let q = p.find('?')
    if q >= 0:
      p = p[0 ..< q]
    if p.len == 0:
      return "discord-bridge.db"
    return p
  uri

proc runShell(command: string): tuple[ok: bool, output: string] =
  let res = execCmdEx(command)
  (res.exitCode == 0, res.output)

proc execSqlite(conn: SqliteConn, stmt: string): tuple[ok: bool, err: string] =
  conn.sqliteExec(stmt)

proc sqliteHasColumn(
    conn: SqliteConn;
    tableName: string;
    columnName: string): tuple[ok: bool, exists: bool, err: string] =
  let queried = sqliteQuery(conn, "PRAGMA table_info(\"" & tableName & "\");")
  if not queried.ok:
    return (false, false, queried.err)
  for row in queried.rows:
    if row.len >= 2 and row[1] == columnName:
      return (true, true, "")
  (true, false, "")

proc ensureSqliteColumn(
    conn: SqliteConn;
    tableName: string;
    columnName: string;
    columnDef: string): tuple[ok: bool, err: string] =
  let hasCol = sqliteHasColumn(conn, tableName, columnName)
  if not hasCol.ok:
    return (false, "failed to inspect table " & tableName & ": " & hasCol.err)
  if hasCol.exists:
    return (true, "")
  execSqlite(conn, "ALTER TABLE \"" & tableName & "\" ADD COLUMN " & columnDef & ";")

proc applyLatestSqliteSchema*(dbPath: string): tuple[ok: bool, err: string] =
  let script = latestRevisionScript(dbSQLite)
  if script.path.len == 0:
    return (false, "00-latest-revision.sql not found")

  let dir = parentDir(dbPath)
  if dir.len > 0 and dir != ".":
    createDir(dir)

  let opened = sqliteOpen(dbPath)
  if not opened.ok:
    return (false, "failed to open sqlite db: " & opened.err)
  let conn = opened.conn
  defer:
    sqliteClose(conn)

  let pragmaRes = execSqlite(conn, "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")
  if not pragmaRes.ok:
    return (false, "failed to set sqlite pragmas: " & pragmaRes.err)

  ## If core tables already exist, schema is assumed initialized.
  let tableCheck = sqliteQuery(conn, "SELECT name FROM sqlite_master WHERE type='table' AND name='portal' LIMIT 1;")
  if not tableCheck.ok:
    return (false, "failed to inspect schema: " & tableCheck.err)
  if tableCheck.rows.len > 0:
    let ensureReadState = ensureSqliteColumn(
      conn,
      "user",
      "read_state_version",
      "read_state_version INTEGER NOT NULL DEFAULT 0",
    )
    if not ensureReadState.ok:
      return (false, "failed to backfill read_state_version column: " & ensureReadState.err)

    let ensureHeartbeat = ensureSqliteColumn(
      conn,
      "user",
      "heartbeat_session",
      "heartbeat_session jsonb",
    )
    if not ensureHeartbeat.ok:
      return (false, "failed to backfill heartbeat_session column: " & ensureHeartbeat.err)

    return (true, "")

  let scriptText = readFile(script.path)
  let applyRes = execSqlite(conn, scriptText)
  if not applyRes.ok:
    return (false, "failed to apply schema: " & applyRes.err)

  (true, "")

proc applyLatestPostgresSchema*(uri: string): tuple[ok: bool, err: string] =
  let script = latestRevisionScript(dbPostgres)
  if script.path.len == 0:
    return (false, "00-latest-revision.sql not found")

  ## We only wire the command path here; by default it is opt-in for local dev.
  if getEnv("BRIDGE_DISCORD_NIM_APPLY_PG", "0") != "1":
    return (true, "")

  let cmd = "psql " & quoteShell(uri) & " -v ON_ERROR_STOP=1 -f " & quoteShell(script.path)
  let res = runShell(cmd)
  if not res.ok:
    return (false, "failed to apply postgres schema: " & res.output)
  (true, "")

proc openBridgeDb*(uri, dbType: string): BridgeDb =
  let dialect = detectDialectFromUri(uri, dbType)
  var db = BridgeDb(uri: uri, dbType: dbType, dialect: dialect, sqlitePath: "", sqliteConn: nil)

  case dialect
  of dbSQLite:
    db.sqlitePath = sqlPathFromUri(uri)
    let applied = applyLatestSqliteSchema(db.sqlitePath)
    if not applied.ok:
      raise newException(IOError, applied.err)
    let opened = sqliteOpen(db.sqlitePath)
    if not opened.ok:
      raise newException(IOError, "failed to open sqlite db: " & opened.err)
    db.sqliteConn = opened.conn
  of dbPostgres:
    let applied = applyLatestPostgresSchema(uri)
    if not applied.ok:
      raise newException(IOError, applied.err)

  db

proc close*(db: BridgeDb) =
  if db == nil:
    return
  if db.sqliteConn != nil:
    sqliteClose(db.sqliteConn)
    db.sqliteConn = nil
