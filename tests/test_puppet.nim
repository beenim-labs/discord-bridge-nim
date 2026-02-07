## Tests for bridge/puppet.nim — puppet layer parity with puppet.go.

import std/[unittest, json, strutils, os, times]
import config/config
import database/[database, entities, store]
import bridge/runtime
import bridge/puppet

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
  cfg.bridge.usernameTemplate = "discord_{{.}}"
  cfg.bridge.displaynameTemplate = "{{or .GlobalName .Username}}"
  cfg

proc testContext(name: string): tuple[ctx: PuppetContext, db: BridgeDb, dbPath: string] =
  let opened = openTempDb(name)
  let cfg = testConfig()
  let rt = newDiscordBridgeRuntime(cfg, opened.db)
  let ctx = newPuppetContext(rt, cfg)
  (ctx, opened.db, opened.path)

suite "puppet layer":
  test "formatPuppetMXID":
    let (ctx, db, dbPath) = testContext("puppet-fmt")
    try:
      check ctx.formatPuppetMXID("123456") == "@discord_123456:example.com"
      check ctx.formatPuppetMXID("999") == "@discord_999:example.com"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "parsePuppetMXID valid":
    let (ctx, db, dbPath) = testContext("puppet-parse")
    try:
      let (discordId, ok) = ctx.parsePuppetMXID("@discord_123456:example.com")
      check ok
      check discordId == "123456"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "parsePuppetMXID invalid prefix":
    let (ctx, db, dbPath) = testContext("puppet-parse-prefix")
    try:
      let (_, ok) = ctx.parsePuppetMXID("@other_123456:example.com")
      check not ok
    finally:
      db.close()
      cleanupDb(dbPath)

  test "parsePuppetMXID invalid domain":
    let (ctx, db, dbPath) = testContext("puppet-parse-domain")
    try:
      let (_, ok) = ctx.parsePuppetMXID("@discord_123456:wrong.com")
      check not ok
    finally:
      db.close()
      cleanupDb(dbPath)

  test "parsePuppetMXID non-numeric":
    let (ctx, db, dbPath) = testContext("puppet-parse-nonnumeric")
    try:
      let (_, ok) = ctx.parsePuppetMXID("@discord_abc:example.com")
      check not ok
    finally:
      db.close()
      cleanupDb(dbPath)

  test "getMXID":
    let (ctx, db, dbPath) = testContext("puppet-getmxid")
    try:
      var rec = newPuppetRecord("42")
      check ctx.getMXID(rec) == "@discord_42:example.com"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "getDisplayname":
    var rec = newPuppetRecord("1")
    rec.name = "Test User"
    check rec.getDisplayname() == "Test User"

  test "getAvatarURL":
    var rec = newPuppetRecord("1")
    rec.avatarUrl = "mxc://example.com/abc"
    check rec.getAvatarURL() == "mxc://example.com/abc"

  test "defaultIntent returns correct mxid":
    let (ctx, db, dbPath) = testContext("puppet-intent")
    try:
      var rec = newPuppetRecord("42")
      let intent = ctx.defaultIntent(rec)
      check intent.mxid == "@discord_42:example.com"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "customIntent returns nil":
    var rec = newPuppetRecord("42")
    check rec.customIntent() == nil

  test "getPuppetByID creates if missing":
    let (ctx, db, dbPath) = testContext("puppet-getbyid")
    try:
      let (found, rec) = ctx.getPuppetByID("999")
      check found
      check rec.id == "999"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "getPuppetByMXID round-trip":
    let (ctx, db, dbPath) = testContext("puppet-getbymxid")
    try:
      # Ensure puppet exists
      discard ctx.getPuppetByID("12345")
      let (found, rec) = ctx.getPuppetByMXID("@discord_12345:example.com")
      check found
      check rec.id == "12345"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateName changes name":
    let (ctx, db, dbPath) = testContext("puppet-updatename")
    try:
      var rec = newPuppetRecord("1")
      rec.name = ""
      rec.nameSet = false
      let info = DiscordUser(
        id: "1", username: "testuser", discriminator: "0",
        globalName: "TestGlobal", avatar: "", bot: false
      )
      let changed = ctx.updateName(rec, info)
      check changed
      check rec.name == "TestGlobal"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateName no-op when unchanged":
    let (ctx, db, dbPath) = testContext("puppet-updatename-noop")
    try:
      var rec = newPuppetRecord("1")
      rec.name = "TestGlobal"
      rec.nameSet = true
      let info = DiscordUser(
        id: "1", username: "testuser", discriminator: "0",
        globalName: "TestGlobal", avatar: "", bot: false
      )
      let changed = ctx.updateName(rec, info)
      check not changed
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateContactInfo detects username change":
    let (ctx, db, dbPath) = testContext("puppet-contactinfo")
    try:
      var rec = newPuppetRecord("1")
      rec.username = "old"
      rec.globalName = "Old"
      rec.discriminator = "0"
      rec.isBot = false
      rec.contactInfoSet = true
      let info = DiscordUser(
        id: "1", username: "new", discriminator: "0",
        globalName: "Old", avatar: "", bot: false
      )
      let changed = ctx.updateContactInfo(rec, info)
      check changed
      check rec.username == "new"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateContactInfo no-op when same":
    let (ctx, db, dbPath) = testContext("puppet-contactinfo-noop")
    try:
      var rec = newPuppetRecord("1")
      rec.username = "same"
      rec.globalName = "Same"
      rec.discriminator = "0"
      rec.isBot = false
      rec.contactInfoSet = true
      let info = DiscordUser(
        id: "1", username: "same", discriminator: "0",
        globalName: "Same", avatar: "", bot: false
      )
      let changed = ctx.updateContactInfo(rec, info)
      check not changed
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateAvatar changes avatar ID":
    let (ctx, db, dbPath) = testContext("puppet-avatar")
    try:
      var rec = newPuppetRecord("1")
      rec.avatar = ""
      rec.avatarSet = false
      let info = DiscordUser(
        id: "1", username: "u", discriminator: "0",
        globalName: "", avatar: "abc123", bot: false
      )
      let changed = ctx.updateAvatar(rec, info)
      check changed
      check rec.avatar == "abc123"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateAvatar no-op when same":
    let (ctx, db, dbPath) = testContext("puppet-avatar-noop")
    try:
      var rec = newPuppetRecord("1")
      rec.avatar = "abc"
      rec.avatarSet = true
      let info = DiscordUser(
        id: "1", username: "u", discriminator: "0",
        globalName: "", avatar: "abc", bot: false
      )
      let changed = ctx.updateAvatar(rec, info)
      check not changed
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateInfo marks webhook from message":
    let (ctx, db, dbPath) = testContext("puppet-updateinfo-wh")
    try:
      var rec = newPuppetRecord("1")
      rec.username = "webhook"
      rec.discriminator = "0"
      rec.nameSet = false
      rec.avatarSet = false
      rec.contactInfoSet = true
      var info = DiscordUser(
        id: "1", username: "webhook", discriminator: "0",
        globalName: "Webhook", avatar: "", bot: false
      )
      let msg = DiscordMessage(id: "m1", webhookId: "wh1", applicationId: "")
      let changed = ctx.updateInfo(rec, info, msg, hasSource = true)
      check changed
      check rec.isWebhook
    finally:
      db.close()
      cleanupDb(dbPath)

  test "updateInfo marks application from message":
    let (ctx, db, dbPath) = testContext("puppet-updateinfo-app")
    try:
      var rec = newPuppetRecord("1")
      rec.username = "bot"
      rec.discriminator = "0"
      rec.nameSet = false
      rec.avatarSet = false
      rec.contactInfoSet = true
      var info = DiscordUser(
        id: "1", username: "bot", discriminator: "0",
        globalName: "Bot", avatar: "", bot: true
      )
      let msg = DiscordMessage(id: "m1", webhookId: "wh1", applicationId: "app1")
      let changed = ctx.updateInfo(rec, info, msg, hasSource = true)
      check changed
      check rec.isApplication
      check not rec.isWebhook  # application overrides webhook
    finally:
      db.close()
      cleanupDb(dbPath)

  test "resendContactInfo with beeper support":
    let (ctx, db, dbPath) = testContext("puppet-resend")
    try:
      ctx.supportsBeeperProfileMeta = true

      var capturedInfo: JsonNode
      ctx.beeperUpdateProfile = proc(mxid: string, info: JsonNode): BeeperUpdateProfileResult {.closure.} =
        capturedInfo = info
        (true, "")

      var rec = newPuppetRecord("42")
      rec.username = "testuser"
      rec.discriminator = "1234"
      rec.contactInfoSet = false

      ctx.resendContactInfo(rec)
      check rec.contactInfoSet
      check capturedInfo != nil
      let identifiers = capturedInfo["com.beeper.bridge.identifiers"]
      check identifiers.len == 1
      check identifiers[0].getStr() == "discord:testuser#1234"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "resendContactInfo with discriminator 0":
    let (ctx, db, dbPath) = testContext("puppet-resend-disc0")
    try:
      ctx.supportsBeeperProfileMeta = true

      var capturedInfo: JsonNode
      ctx.beeperUpdateProfile = proc(mxid: string, info: JsonNode): BeeperUpdateProfileResult {.closure.} =
        capturedInfo = info
        (true, "")

      var rec = newPuppetRecord("42")
      rec.username = "testuser"
      rec.discriminator = "0"
      rec.contactInfoSet = false

      ctx.resendContactInfo(rec)
      check rec.contactInfoSet
      let identifiers = capturedInfo["com.beeper.bridge.identifiers"]
      check identifiers.len == 1
      check identifiers[0].getStr() == "discord:testuser"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "resendContactInfo for webhook has empty identifiers":
    let (ctx, db, dbPath) = testContext("puppet-resend-wh")
    try:
      ctx.supportsBeeperProfileMeta = true

      var capturedInfo: JsonNode
      ctx.beeperUpdateProfile = proc(mxid: string, info: JsonNode): BeeperUpdateProfileResult {.closure.} =
        capturedInfo = info
        (true, "")

      var rec = newPuppetRecord("42")
      rec.username = "webhook"
      rec.discriminator = "0"
      rec.isWebhook = true
      rec.contactInfoSet = false

      ctx.resendContactInfo(rec)
      check rec.contactInfoSet
      let identifiers = capturedInfo["com.beeper.bridge.identifiers"]
      check identifiers.len == 0
    finally:
      db.close()
      cleanupDb(dbPath)

  test "getAllPuppets returns all":
    let (ctx, db, dbPath) = testContext("puppet-getall")
    try:
      db.insertPuppet(newPuppetRecord("a1"))
      db.insertPuppet(newPuppetRecord("a2"))
      db.insertPuppet(newPuppetRecord("a3"))
      let all = ctx.getAllPuppets()
      check all.len >= 3
    finally:
      db.close()
      cleanupDb(dbPath)

  test "reuploadUserAvatar builds correct URL for user avatar":
    let (ctx, db, dbPath) = testContext("puppet-reupload")
    try:
      var capturedUrl = ""
      ctx.copyAttachment = proc(mxid, url: string, encrypt: bool, attachmentId: string): CopyAttachmentResult {.closure.} =
        capturedUrl = url
        CopyAttachmentResult(ok: true, mxc: "mxc://example.com/result", err: "")

      let result = ctx.reuploadUserAvatar("@bot:example.com", "", "12345", "avatar_hash")
      check result.err == ""
      check result.mxc == "mxc://example.com/result"
      check capturedUrl.contains("/avatars/12345/avatar_hash.png")
    finally:
      db.close()
      cleanupDb(dbPath)

  test "reuploadUserAvatar animated avatar uses gif":
    let (ctx, db, dbPath) = testContext("puppet-reupload-anim")
    try:
      var capturedUrl = ""
      ctx.copyAttachment = proc(mxid, url: string, encrypt: bool, attachmentId: string): CopyAttachmentResult {.closure.} =
        capturedUrl = url
        CopyAttachmentResult(ok: true, mxc: "mxc://example.com/result", err: "")

      let result = ctx.reuploadUserAvatar("@bot:example.com", "", "12345", "a_avatar_hash")
      check result.err == ""
      check capturedUrl.contains("/avatars/12345/a_avatar_hash.gif")
    finally:
      db.close()
      cleanupDb(dbPath)

  test "reuploadUserAvatar guild member avatar":
    let (ctx, db, dbPath) = testContext("puppet-reupload-guild")
    try:
      var capturedUrl = ""
      ctx.copyAttachment = proc(mxid, url: string, encrypt: bool, attachmentId: string): CopyAttachmentResult {.closure.} =
        capturedUrl = url
        CopyAttachmentResult(ok: true, mxc: "mxc://example.com/result", err: "")

      let result = ctx.reuploadUserAvatar("@bot:example.com", "guild1", "12345", "avatar_hash")
      check result.err == ""
      check capturedUrl.contains("/guilds/guild1/users/12345/avatars/avatar_hash.png")
    finally:
      db.close()
      cleanupDb(dbPath)

  test "reuploadUserAvatar prefers directmedia":
    let (ctx, db, dbPath) = testContext("puppet-reupload-dm")
    try:
      ctx.avatarMXC = proc(guildId, userId, avatarId: string): string {.closure.} =
        "mxc://direct/media123"

      let result = ctx.reuploadUserAvatar("@bot:example.com", "", "12345", "avatar_hash")
      check result.err == ""
      check result.mxc == "mxc://direct/media123"
    finally:
      db.close()
      cleanupDb(dbPath)
