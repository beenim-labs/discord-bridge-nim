import std/[unittest, os, strutils, sequtils]
import database/[migrations, database, sqlite_native]

proc runSqlite(dbPath, query: string): tuple[ok: bool, output: string] =
  let opened = sqliteOpen(dbPath)
  if not opened.ok:
    return (false, opened.err)
  defer:
    sqliteClose(opened.conn)
  let q = sqliteQuery(opened.conn, query)
  if not q.ok:
    return (false, q.err)
  if q.rows.len == 0 or q.rows[0].len == 0:
    return (true, "")
  (true, q.rows[0][0].strip())

suite "migrations":
  test "load sqlite scripts":
    let scripts = loadUpgradeScripts(dbSQLite)
    check scripts.len > 0
    check scripts.anyIt(it.filename == "00-latest-revision.sql")
    check scripts.allIt(not it.filename.endsWith(".postgres.sql"))

  test "apply latest sqlite schema":
    let dbPath = "tests/fixtures/test-schema.db"
    if fileExists(dbPath):
      removeFile(dbPath)

    let applied = applyLatestSqliteSchema(dbPath)
    check applied.ok

    let tableCheck = runSqlite(dbPath, "SELECT name FROM sqlite_master WHERE type='table' AND name='portal';")
    check tableCheck.ok
    check tableCheck.output == "portal"

    removeFile(dbPath)
