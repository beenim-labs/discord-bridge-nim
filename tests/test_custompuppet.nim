import std/[unittest, os, times, strutils, tables]
import config/config
import database/[database, entities]
import bridge/[runtime, custompuppet]

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

suite "custom puppet":
  test "switch and clear custom mxid updates mapping":
    let opened = openTempDb("custom-puppet-switch")
    let db = opened.db
    let dbPath = opened.path
    try:
      let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
      let rt = newDiscordBridgeRuntime(cfg, db)
      let custom = newCustomPuppetCoordinator(rt)

      let switched = custom.switchCustomMXID("discord-1", "token-1", "@alice:localhost")
      check switched.ok

      let byId = rt.puppets.getByID("discord-1", createIfMissing = false)
      check byId.found
      check byId.rec.customMxid == "@alice:localhost"
      check byId.rec.accessToken == "token-1"

      let byCustom = rt.puppets.getByCustomMXID("@alice:localhost")
      check byCustom.found
      check byCustom.rec.id == "discord-1"

      custom.clearCustomMXID("discord-1")
      let cleared = rt.puppets.getByID("discord-1", createIfMissing = false)
      check cleared.found
      check cleared.rec.customMxid == ""
      check cleared.rec.accessToken == ""
      check not rt.puppets.getByCustomMXID("@alice:localhost").found
    finally:
      db.close()
      cleanupDb(dbPath)

  test "start failure clears persisted custom puppet identity":
    let opened = openTempDb("custom-puppet-failure")
    let db = opened.db
    let dbPath = opened.path
    try:
      let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
      let rt = newDiscordBridgeRuntime(cfg, db)
      let custom = newCustomPuppetCoordinator(rt)

      let switched = custom.switchCustomMXID("discord-2", "fail:boom", "@bob:localhost")
      check not switched.ok
      check switched.err == "boom"

      let byId = rt.puppets.getByID("discord-2", createIfMissing = false)
      check byId.found
      check byId.rec.customMxid == ""
      check byId.rec.accessToken == ""
    finally:
      db.close()
      cleanupDb(dbPath)

  test "automatic double puppeting uses homeserver map and relogin":
    let opened = openTempDb("custom-puppet-auto")
    let db = opened.db
    let dbPath = opened.path
    try:
      var cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
      cfg.bridge.doublePuppet["server_map.localhost"] = "shared-secret"
      let rt = newDiscordBridgeRuntime(cfg, db)
      let custom = newCustomPuppetCoordinator(rt)

      let auto1 = custom.tryAutomaticDoublePuppeting("@carol:localhost", "discord-3")
      check auto1.attempted
      check auto1.ok
      let byId = rt.puppets.getByID("discord-3", createIfMissing = false)
      check byId.found
      check byId.rec.customMxid == "@carol:localhost"
      check byId.rec.accessToken.startsWith("shared-secret:")

      let auto2 = custom.tryAutomaticDoublePuppeting("@carol:localhost", "discord-3")
      check not auto2.attempted
      check auto2.ok

      let auto3 = custom.tryAutomaticDoublePuppeting("@dave:example.org", "discord-4")
      check not auto3.attempted
      check auto3.ok
      check not rt.puppets.getByID("discord-4", createIfMissing = false).found
    finally:
      db.close()
      cleanupDb(dbPath)
