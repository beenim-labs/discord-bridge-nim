## Tests for bridge/guild.nim — guild layer parity with guildportal.go.

import std/[unittest, json, strutils, os, times]
import config/config
import database/[database, entities, store]
import bridge/runtime
import bridge/guild

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

proc testConfig(): Config =
  var cfg = defaultConfig()
  cfg.homeserver.domain = "example.com"
  cfg.bridge.guildNameTemplate = "{{.Name}}"
  cfg.bridge.federateRooms = true
  cfg

proc testContext(name: string): tuple[ctx: GuildContext, db: BridgeDb, dbPath: string] =
  let opened = openTempDb(name)
  let cfg = testConfig()
  let rt = newDiscordBridgeRuntime(cfg, opened.db)
  let ctx = newGuildContext(rt, cfg)
  ctx.botUserID = "@bot:example.com"
  ctx.botAvatarUrl = "mxc://example.com/botavatar"
  (ctx, opened.db, opened.path)

suite "guild layer":
  test "getGuildByID creates if missing":
    let (ctx, db, dbPath) = testContext("guild-getbyid")
    try:
      let (found, rec) = ctx.getGuildByID("guild1", createIfMissing = true)
      check found
      check rec.id == "guild1"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "getGuildByID returns false when not found":
    let (ctx, db, dbPath) = testContext("guild-getbyid-missing")
    try:
      let (found, _) = ctx.getGuildByID("nonexistent", createIfMissing = false)
      check not found
    finally:
      db.close()
      cleanupDb(dbPath)

  test "getBridgeInfo returns correct structure":
    let (ctx, db, dbPath) = testContext("guild-bridgeinfo")
    try:
      var rec = newGuildRecord("guild123")
      rec.name = "Test Guild"
      rec.avatarUrl = "mxc://example.com/icon"
      let (stateKey, content) = ctx.getBridgeInfo(rec)
      check stateKey == "fi.mau.discord://discord/guild123"
      check content["protocol"]["id"].getStr() == "discordgo"
      check content["channel"]["id"].getStr() == "guild123"
      check content["channel"]["displayname"].getStr() == "Test Guild"
      check content["bridgebot"].getStr() == "@bot:example.com"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateName changes name":
    let (ctx, db, dbPath) = testContext("guild-updatename")
    try:
      var rec = newGuildRecord("g1")
      rec.name = ""
      rec.plainName = ""
      rec.nameSet = false
      let meta = DiscordGuildMeta(id: "g1", name: "My Guild", icon: "", unavailable: false)
      let changed = ctx.updateName(rec, meta)
      check changed
      check rec.name == "My Guild"
      check rec.plainName == "My Guild"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateName no-op when unchanged":
    let (ctx, db, dbPath) = testContext("guild-updatename-noop")
    try:
      var rec = newGuildRecord("g1")
      rec.name = "My Guild"
      rec.plainName = "My Guild"
      rec.nameSet = true
      let meta = DiscordGuildMeta(id: "g1", name: "My Guild", icon: "", unavailable: false)
      let changed = ctx.updateName(rec, meta)
      check not changed
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateName sets room name when mxid present":
    let (ctx, db, dbPath) = testContext("guild-updatename-room")
    try:
      var capturedName = ""
      ctx.setRoomName = proc(roomId, name: string): SetRoomNameResult {.closure.} =
        capturedName = name
        (true, "")

      var rec = newGuildRecord("g1")
      rec.mxid = "!room:example.com"
      rec.name = "Old"
      rec.plainName = "Old"
      rec.nameSet = true
      let meta = DiscordGuildMeta(id: "g1", name: "New Guild", icon: "", unavailable: false)
      let changed = ctx.updateName(rec, meta)
      check changed
      check rec.nameSet
      check capturedName == "New Guild"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateAvatar changes avatar":
    let (ctx, db, dbPath) = testContext("guild-updateavatar")
    try:
      var capturedUrl = ""
      ctx.copyAttachment = proc(url: string, encrypt: bool, attachmentId: string): GuildCopyAttachmentResult {.closure.} =
        capturedUrl = url
        GuildCopyAttachmentResult(ok: true, mxc: "mxc://example.com/guildicon", err: "")

      var rec = newGuildRecord("g1")
      rec.avatar = ""
      rec.avatarSet = false
      let changed = ctx.updateAvatar(rec, "icon_hash")
      check changed
      check rec.avatar == "icon_hash"
      check rec.avatarUrl == "mxc://example.com/guildicon"
      check capturedUrl.contains("/icons/g1/icon_hash.png")
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateAvatar no-op when same":
    let (ctx, db, dbPath) = testContext("guild-updateavatar-noop")
    try:
      var rec = newGuildRecord("g1")
      rec.avatar = "icon_hash"
      rec.avatarUrl = "mxc://example.com/existing"
      rec.avatarSet = true
      let changed = ctx.updateAvatar(rec, "icon_hash")
      check not changed
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateAvatar clears when empty iconID":
    let (ctx, db, dbPath) = testContext("guild-updateavatar-clear")
    try:
      var rec = newGuildRecord("g1")
      rec.avatar = "old_hash"
      rec.avatarUrl = "mxc://example.com/old"
      rec.avatarSet = true
      let changed = ctx.updateAvatar(rec, "")
      check changed
      check rec.avatar == ""
      check rec.avatarUrl == ""
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateInfo skips unavailable guild":
    let (ctx, db, dbPath) = testContext("guild-updateinfo-unavail")
    try:
      var rec = newGuildRecord("g1")
      let meta = DiscordGuildMeta(id: "g1", name: "Guild", icon: "", unavailable: true)
      let changed = ctx.updateInfo(rec, meta)
      check not changed
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateInfo updates name and avatar":
    let (ctx, db, dbPath) = testContext("guild-updateinfo")
    try:
      ctx.copyAttachment = proc(url: string, encrypt: bool, attachmentId: string): GuildCopyAttachmentResult {.closure.} =
        GuildCopyAttachmentResult(ok: true, mxc: "mxc://example.com/icon", err: "")

      var rec = newGuildRecord("g1")
      rec.name = ""
      rec.plainName = ""
      let meta = DiscordGuildMeta(id: "g1", name: "Test", icon: "icon1", unavailable: false)
      let changed = ctx.updateInfo(rec, meta)
      check changed
      check rec.name == "Test"
      check rec.avatar == "icon1"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "createMatrixRoom creates room and sets mxid":
    let (ctx, db, dbPath) = testContext("guild-createroom")
    try:
      ctx.createRoom = proc(req: JsonNode): CreateRoomResult {.closure.} =
        (true, "!newroom:example.com", "")

      var rec = newGuildRecord("g1")
      rec.name = ""
      rec.plainName = ""
      let meta = DiscordGuildMeta(id: "g1", name: "Test Guild", icon: "", unavailable: false)
      let res = ctx.createMatrixRoom(rec, meta)
      check res.ok
      check rec.mxid == "!newroom:example.com"
      check rec.nameSet
    finally:
      db.close()
      cleanupDb(dbPath)

  test "createMatrixRoom no-op when already created":
    let (ctx, db, dbPath) = testContext("guild-createroom-exists")
    try:
      var rec = newGuildRecord("g1")
      rec.mxid = "!existing:example.com"
      let meta = DiscordGuildMeta(id: "g1", name: "Test", icon: "", unavailable: false)
      let res = ctx.createMatrixRoom(rec, meta)
      check res.ok
      check rec.mxid == "!existing:example.com"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "createMatrixRoom includes federation false when configured":
    let (ctx, db, dbPath) = testContext("guild-createroom-nofed")
    try:
      ctx.cfg.bridge.federateRooms = false
      var capturedReq: JsonNode
      ctx.createRoom = proc(req: JsonNode): CreateRoomResult {.closure.} =
        capturedReq = req
        (true, "!room:example.com", "")

      var rec = newGuildRecord("g1")
      let meta = DiscordGuildMeta(id: "g1", name: "Test", icon: "", unavailable: false)
      discard ctx.createMatrixRoom(rec, meta)
      check capturedReq["creation_content"]["m.federate"].getBool() == false
    finally:
      db.close()
      cleanupDb(dbPath)

  test "cleanup uses yeeting when supported":
    let (ctx, db, dbPath) = testContext("guild-cleanup-yeet")
    try:
      ctx.supportsBeeperRoomYeeting = true
      var deleteCalled = false
      ctx.deleteRoom = proc(roomId: string): DeleteRoomResult {.closure.} =
        deleteCalled = true
        (true, "")

      var rec = newGuildRecord("g1")
      rec.mxid = "!room:example.com"
      ctx.cleanup(rec)
      check deleteCalled
    finally:
      db.close()
      cleanupDb(dbPath)

  test "cleanup uses cleanupRoom when yeeting not supported":
    let (ctx, db, dbPath) = testContext("guild-cleanup-fallback")
    try:
      ctx.supportsBeeperRoomYeeting = false
      var cleanupCalled = false
      ctx.cleanupRoom = proc(roomId: string): CleanupRoomResult {.closure.} =
        cleanupCalled = true
        (true, "")

      var rec = newGuildRecord("g1")
      rec.mxid = "!room:example.com"
      ctx.cleanup(rec)
      check cleanupCalled
    finally:
      db.close()
      cleanupDb(dbPath)

  test "removeMXID clears mxid and resets flags":
    let (ctx, db, dbPath) = testContext("guild-removemxid")
    try:
      var rec = newGuildRecord("g1")
      rec.mxid = "!room:example.com"
      rec.avatarSet = true
      rec.nameSet = true
      rec.bridgingMode = gbmEverything
      # Insert so upsert works
      db.insertGuild(rec)
      ctx.removeMXID(rec)
      check rec.mxid == ""
      check not rec.avatarSet
      check not rec.nameSet
      check rec.bridgingMode == gbmNothing
    finally:
      db.close()
      cleanupDb(dbPath)

  test "delete removes from manager":
    let (ctx, db, dbPath) = testContext("guild-delete")
    try:
      discard ctx.getGuildByID("g1", createIfMissing = true)
      let (found1, _) = ctx.getGuildByID("g1")
      check found1
      ctx.delete(newGuildRecord("g1"))
      # After delete, should not be found (cache cleared)
      let (found2, _) = ctx.runtime.guilds.getByID("g1", createIfMissing = false)
      check not found2
    finally:
      db.close()
      cleanupDb(dbPath)
