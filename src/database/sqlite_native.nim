## Minimal native SQLite bindings for bridge DB access.

type
  Sqlite3Obj {.incompleteStruct.} = object
  Sqlite3StmtObj {.incompleteStruct.} = object
  SqliteConn* = ptr Sqlite3Obj
  SqliteStmt* = ptr Sqlite3StmtObj

const
  SQLITE_OK* = 0
  SQLITE_ROW* = 100
  SQLITE_DONE* = 101

  SQLITE_OPEN_READWRITE* = 0x00000002
  SQLITE_OPEN_CREATE* = 0x00000004
  SQLITE_OPEN_URI* = 0x00000040

when defined(macosx):
  const SqliteDynlib = "libsqlite3(|.0).dylib"
elif defined(windows):
  const SqliteDynlib = "sqlite3.dll"
else:
  const SqliteDynlib = "libsqlite3.so(|.0)"

proc sqlite3_open_v2(filename: cstring, ppDb: ptr SqliteConn, flags: cint, zVfs: cstring): cint {.cdecl, importc, dynlib: SqliteDynlib.}
proc sqlite3_close_v2(db: SqliteConn): cint {.cdecl, importc, dynlib: SqliteDynlib.}
proc sqlite3_errmsg(db: SqliteConn): cstring {.cdecl, importc, dynlib: SqliteDynlib.}
proc sqlite3_exec(db: SqliteConn, sql: cstring, cb: pointer, arg: pointer, errMsg: ptr cstring): cint {.cdecl, importc, dynlib: SqliteDynlib.}
proc sqlite3_prepare_v2(db: SqliteConn, sql: cstring, nByte: cint, ppStmt: ptr SqliteStmt, pzTail: ptr cstring): cint {.cdecl, importc, dynlib: SqliteDynlib.}
proc sqlite3_step(stmt: SqliteStmt): cint {.cdecl, importc, dynlib: SqliteDynlib.}
proc sqlite3_finalize(stmt: SqliteStmt): cint {.cdecl, importc, dynlib: SqliteDynlib.}
proc sqlite3_column_count(stmt: SqliteStmt): cint {.cdecl, importc, dynlib: SqliteDynlib.}
proc sqlite3_column_text(stmt: SqliteStmt, iCol: cint): cstring {.cdecl, importc, dynlib: SqliteDynlib.}
proc sqlite3_busy_timeout(db: SqliteConn, ms: cint): cint {.cdecl, importc, dynlib: SqliteDynlib.}
proc sqlite3_free(p: pointer) {.cdecl, importc, dynlib: SqliteDynlib.}

proc connErr(db: SqliteConn, defaultMsg: string): string =
  if db != nil:
    let msgPtr = sqlite3_errmsg(db)
    if msgPtr != nil:
      return $msgPtr
  defaultMsg

proc sqliteOpen*(path: string): tuple[ok: bool, conn: SqliteConn, err: string] =
  var conn: SqliteConn = nil
  let flags = cint(SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_URI)
  let rc = sqlite3_open_v2(path, addr conn, flags, nil)
  if rc != SQLITE_OK:
    let msg = connErr(conn, "sqlite open failed with code " & $rc)
    if conn != nil:
      discard sqlite3_close_v2(conn)
    return (false, nil, msg)
  discard sqlite3_busy_timeout(conn, 5000)
  (true, conn, "")

proc sqliteClose*(conn: SqliteConn) =
  if conn != nil:
    discard sqlite3_close_v2(conn)

proc sqliteExec*(conn: SqliteConn, sql: string): tuple[ok: bool, err: string] =
  if conn == nil:
    return (false, "sqlite connection is nil")
  var rawErr: cstring = nil
  let rc = sqlite3_exec(conn, sql, nil, nil, addr rawErr)
  if rc != SQLITE_OK:
    var msg = connErr(conn, "sqlite exec failed with code " & $rc)
    if rawErr != nil:
      msg = $rawErr
      sqlite3_free(cast[pointer](rawErr))
    return (false, msg)
  (true, "")

proc sqliteQuery*(conn: SqliteConn, sql: string): tuple[ok: bool, rows: seq[seq[string]], err: string] =
  if conn == nil:
    return (false, @[], "sqlite connection is nil")

  var stmt: SqliteStmt = nil
  let prep = sqlite3_prepare_v2(conn, sql, -1, addr stmt, nil)
  if prep != SQLITE_OK:
    return (false, @[], connErr(conn, "sqlite prepare failed with code " & $prep))
  defer:
    if stmt != nil:
      discard sqlite3_finalize(stmt)

  result = (true, @[], "")
  let cols = sqlite3_column_count(stmt)
  while true:
    let rc = sqlite3_step(stmt)
    if rc == SQLITE_ROW:
      var row = newSeq[string](cols)
      for i in 0 ..< cols:
        let text = sqlite3_column_text(stmt, i)
        row[i] = if text == nil: "" else: $text
      result.rows.add(row)
    elif rc == SQLITE_DONE:
      break
    else:
      return (false, @[], connErr(conn, "sqlite step failed with code " & $rc))
