import std/[asyncdispatch, json, os, strutils, times, unittest]
import config/config
import database/[database, store]
import bridge/runtime

proc cleanupDb(path: string) =
  for suffix in ["", "-wal", "-shm"]:
    let p = path & suffix
    if fileExists(p):
      removeFile(p)

proc openTempDb(name: string): tuple[db: BridgeDb, path: string] =
  let dbPath = "tests/fixtures/" & name & "-" & $getTime().toUnix() & "-" & $epochTime().int64 & ".db"
  cleanupDb(dbPath)
  let db = openBridgeDb("file:" & dbPath, "sqlite")
  (db, dbPath)

suite "user runtime startup":
  test "retry delay schedule":
    check retryDelayMs(0) == 2000
    check retryDelayMs(1) == 4000
    check retryDelayMs(2) == 8000

  test "startup connects users with tokens":
    let opened = openTempDb("startup-connect")
    let db = opened.db
    let dbPath = opened.path
    try:
      db.insertUser(newUserRecord("@u1:test"))
      db.insertUser(newUserRecord("@u2:test"))
      var u2 = newUserRecord("@u2:test")
      u2.discordToken = "token-u2"
      db.updateUser(u2)

      var u1 = newUserRecord("@u1:test")
      u1.discordToken = "token-u1"
      db.updateUser(u1)

      let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
      let rt = newDiscordBridgeRuntime(cfg, db)
      rt.userStartup.maxRetries = 0
      rt.userStartup.verifyToken = proc(token: string): tuple[ok: bool, err: string] =
        if token.startsWith("token-"):
          (true, "")
        else:
          (false, "invalid token")
      rt.start()
      waitFor sleepAsync(120)

      let h = rt.health()
      check h["runtime_startup_users_total"].getInt() == 2
      check h["runtime_startup_users_connected"].getInt() == 2
      check h["runtime_startup_users_failed"].getInt() == 0
      rt.stop()
    finally:
      db.close()
      cleanupDb(dbPath)

  test "runtime stop cancels startup":
    let opened = openTempDb("startup-stop")
    let db = opened.db
    let dbPath = opened.path
    try:
      var u1 = newUserRecord("@stop:test")
      u1.discordToken = "bad-token"
      db.insertUser(u1)

      let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
      let rt = newDiscordBridgeRuntime(cfg, db)
      rt.userStartup.verifyToken = proc(token: string): tuple[ok: bool, err: string] =
        (false, "temporary error")
      rt.start()
      waitFor sleepAsync(40)
      rt.stop()

      let h = rt.health()
      check not h["runtime_startup_running"].getBool()
      check rt.userStartup.canceled
    finally:
      db.close()
      cleanupDb(dbPath)
