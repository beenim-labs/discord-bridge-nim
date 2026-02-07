## SQLite query helpers for bridge database stores.

import std/[strutils]
import database/database
import database/migrations
import database/sqlite_native

proc requireSQLite*(db: BridgeDb) =
  if db == nil:
    raise newException(ValueError, "database handle is nil")
  if db.dialect != dbSQLite:
    raise newException(ValueError, "store operations currently support sqlite only")
  if db.sqliteConn == nil:
    raise newException(ValueError, "sqlite connection is not open")

proc q*(s: string): string =
  "'" & s.replace("'", "''") & "'"

proc qn*(s: string): string =
  if s.len == 0:
    "NULL"
  else:
    q(s)

proc b2i*(v: bool): string =
  if v: "1" else: "0"

proc parseIntOrZero*(s: string): int =
  if s.len == 0:
    return 0
  try:
    parseInt(s)
  except ValueError:
    0

proc parseInt64OrZero*(s: string): int64 =
  if s.len == 0:
    return 0'i64
  try:
    parseBiggestInt(s)
  except ValueError:
    0'i64

proc parseBool*(s: string): bool =
  let v = s.toLowerAscii()
  v == "1" or v == "true" or v == "yes" or v == "on"

proc runSql*(db: BridgeDb, stmt: string): tuple[ok: bool, output: string, err: string] =
  db.requireSQLite()
  let lower = stmt.strip().toLowerAscii()
  if lower.startsWith("select") or lower.startsWith("pragma") or lower.startsWith("with"):
    let queried = sqliteQuery(db.sqliteConn, stmt)
    if not queried.ok:
      return (false, "", queried.err)
    var lines: seq[string] = @[]
    for row in queried.rows:
      lines.add(row.join("\t"))
    return (true, lines.join("\n"), "")
  let executed = sqliteExec(db.sqliteConn, stmt)
  if not executed.ok:
    return (false, "", executed.err)
  (true, "", "")

proc execSql*(db: BridgeDb, stmt: string) =
  let r = db.runSql(stmt)
  if not r.ok:
    raise newException(IOError, "sqlite exec failed: " & r.err & " SQL=" & stmt)

proc queryRows*(db: BridgeDb, stmt: string): seq[seq[string]] =
  db.requireSQLite()
  let queried = sqliteQuery(db.sqliteConn, stmt)
  if not queried.ok:
    raise newException(IOError, "sqlite query failed: " & queried.err & " SQL=" & stmt)
  queried.rows

proc getCol*(row: seq[string], idx: int): string =
  if idx >= 0 and idx < row.len:
    row[idx]
  else:
    ""
