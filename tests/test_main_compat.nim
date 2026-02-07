import std/[strutils, os, times, unittest]
import config/config
import database/[database, entities, store]
import bridge/[runtime, main_compat]

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

suite "main compat":
  test "example config and config ptr":
    let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
    let compat = newDiscordBridgeCompat(cfg, nil)
    check compat.getExampleConfig().contains("homeserver:")

    let ptrCfg = compat.getConfigPtr()
    check ptrCfg != nil
    if ptrCfg != nil:
      check ptrCfg[].appservice.id == "discord"

  test "portal and user interfaces resolve through runtime managers":
    let opened = openTempDb("compat-main")
    let db = opened.db
    let dbPath = opened.path
    try:
      let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
      let rt = newDiscordBridgeRuntime(cfg, db)
      let compat = newDiscordBridgeCompat(cfg, rt)

      var portal = newPortalRecord(PortalKey(channelId: "chan-main", receiver: ""), 0)
      portal.mxid = "!portal-main:test"
      portal.name = "main"
      rt.portals.upsert(portal)

      let gotPortal = compat.getIPortal("!portal-main:test")
      check gotPortal.found
      check gotPortal.rec.key.channelId == "chan-main"

      let missingUser = compat.getIUser("@main:test", create = false)
      check not missingUser.found

      let createdUser = compat.getIUser("@main:test", create = true)
      check createdUser.found
      check createdUser.rec.mxid == "@main:test"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "ghost parsing and ghost lookup":
    let opened = openTempDb("compat-ghost")
    let db = opened.db
    let dbPath = opened.path
    try:
      let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
      let rt = newDiscordBridgeRuntime(cfg, db)
      let compat = newDiscordBridgeCompat(cfg, rt)

      let parsed = compat.parsePuppetMXID("@discord_123456:localhost")
      check parsed.ok
      check parsed.discordId == "123456"
      check compat.isGhost("@discord_123456:localhost")
      check not compat.isGhost("@discord_123456:otherdomain")
      check not compat.isGhost("@notdiscord_123456:localhost")

      let ghost = compat.getIGhost("@discord_123456:localhost")
      check ghost.found
      check ghost.rec.id == "123456"

      let notGhost = compat.getIGhost("@alice:localhost")
      check not notGhost.found
    finally:
      db.close()
      cleanupDb(dbPath)

  test "createPrivatePortal remains explicit no-op while Go baseline TODO":
    let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
    let compat = newDiscordBridgeCompat(cfg, nil)
    check not compat.createPrivatePortal("!room:test", "@alice:test", "@discord_1:localhost")
