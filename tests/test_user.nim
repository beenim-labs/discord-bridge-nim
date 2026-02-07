## Tests for bridge/user.nim — User session management.

import std/[unittest, json, options, tables, times]
import database/[database, entities, store]
import bridge/runtime
import bridge/portal
import bridge/user

# ===========================================================================
# Test helpers
# ===========================================================================

proc makeTestDb(): BridgeDb =
  newBridgeDb(":memory:")

proc makeTestRuntime(): DiscordBridgeRuntime =
  let db = makeTestDb()
  newDiscordBridgeRuntime(newConfig(), db)

proc makeTestUserCtx(runtime: DiscordBridgeRuntime = nil, mxid = "@test:example.com"): UserContext =
  let rt = if runtime.isNil: makeTestRuntime() else: runtime
  let ctx = newUserContext(rt, mxid)
  ctx.discordToken = "test-token-123"
  ctx.discordId = "123456789"
  ctx

# ===========================================================================
# Collector types for tracking stub calls
# ===========================================================================

type
  BridgeStateLog = seq[BridgeState]
  PortalCallLog = seq[tuple[key: PortalKey, event: string]]

proc makeBridgeStateLogger(): tuple[logger: SendBridgeStateProc, log: ref BridgeStateLog] =
  var log: ref BridgeStateLog
  new(log)
  log[] = @[]
  let logRef = log
  let logger: SendBridgeStateProc = proc(state: BridgeState) =
    logRef[].add(state)
  (logger, log)

# ===========================================================================
# Tests
# ===========================================================================

suite "user: construction and record round-trip":
  test "newUserContext sets defaults":
    let ctx = newUserContext(makeTestRuntime(), "@alice:hs.tld")
    check ctx.mxid == "@alice:hs.tld"
    check ctx.discordId == ""
    check ctx.isConnected == false
    check ctx.isUser == true
    check ctx.wasLoggedOut == false
    check ctx.permissionLevel == plUser
    check ctx.bridgeName == "mautrix-discord"

  test "loadFromRecord populates fields":
    let ctx = newUserContext(makeTestRuntime(), "@blank:hs.tld")
    let rec = UserRecord(
      mxid: "@bob:hs.tld",
      discordId: "987654321",
      discordToken: "tok-abc",
      managementRoom: "!mgmt:hs.tld",
      spaceRoom: "!space:hs.tld",
      dmSpaceRoom: "!dm:hs.tld",
      readStateVersion: 42,
    )
    ctx.loadFromRecord(rec)
    check ctx.mxid == "@bob:hs.tld"
    check ctx.discordId == "987654321"
    check ctx.discordToken == "tok-abc"
    check ctx.managementRoom == "!mgmt:hs.tld"
    check ctx.spaceRoom == "!space:hs.tld"
    check ctx.dmSpaceRoom == "!dm:hs.tld"
    check ctx.readStateVersion == 42

  test "toRecord round-trips":
    let ctx = makeTestUserCtx()
    ctx.managementRoom = "!mgmt:hs.tld"
    ctx.spaceRoom = "!space:hs.tld"
    ctx.dmSpaceRoom = "!dm:hs.tld"
    ctx.readStateVersion = 7
    let rec = ctx.toRecord()
    check rec.mxid == ctx.mxid
    check rec.discordId == ctx.discordId
    check rec.discordToken == ctx.discordToken
    check rec.managementRoom == "!mgmt:hs.tld"
    check rec.spaceRoom == "!space:hs.tld"
    check rec.dmSpaceRoom == "!dm:hs.tld"
    check rec.readStateVersion == 7

suite "user: simple getters":
  test "getRemoteID returns discordId":
    let ctx = makeTestUserCtx()
    check ctx.getRemoteID() == "123456789"

  test "getRemoteName returns discordId when set":
    let ctx = makeTestUserCtx()
    check ctx.getRemoteName() == "123456789"

  test "getRemoteName returns mxid when discordId empty":
    let ctx = makeTestUserCtx()
    ctx.discordId = ""
    check ctx.getRemoteName() == "@test:example.com"

  test "isLoggedIn depends on token":
    let ctx = makeTestUserCtx()
    check ctx.isLoggedIn() == true
    ctx.discordToken = ""
    check ctx.isLoggedIn() == false

  test "connected reflects isConnected":
    let ctx = makeTestUserCtx()
    check ctx.connected() == false
    ctx.isConnected = true
    check ctx.connected() == true

  test "getCommandState returns none":
    let ctx = makeTestUserCtx()
    check ctx.getCommandState().isNone

suite "user: nextDiscordUploadID":
  test "increments by 2":
    let ctx = makeTestUserCtx()
    ctx.nextDiscordUploadId = 10
    check ctx.nextDiscordUploadID() == "12"
    check ctx.nextDiscordUploadID() == "14"
    check ctx.nextDiscordUploadID() == "16"

suite "user: management and space rooms":
  test "setManagementRoom updates field":
    let ctx = makeTestUserCtx()
    ctx.setManagementRoom("!mgmt:hs.tld")
    check ctx.managementRoom == "!mgmt:hs.tld"

  test "setSpaceRoom updates field":
    let ctx = makeTestUserCtx()
    ctx.setSpaceRoom("!space:hs.tld")
    check ctx.spaceRoom == "!space:hs.tld"

  test "setDMSpaceRoom updates field":
    let ctx = makeTestUserCtx()
    ctx.setDMSpaceRoom("!dm:hs.tld")
    check ctx.dmSpaceRoom == "!dm:hs.tld"

suite "user: viewingChannel":
  test "returns true for first view of DM channel":
    let ctx = makeTestUserCtx()
    check ctx.viewingChannel("ch1", "") == true

  test "returns false for second view of same channel":
    let ctx = makeTestUserCtx()
    discard ctx.viewingChannel("ch1", "")
    check ctx.viewingChannel("ch1", "") == false

  test "returns false for guild channels":
    let ctx = makeTestUserCtx()
    check ctx.viewingChannel("ch1", "guild123") == false

  test "returns false for bot users":
    let ctx = makeTestUserCtx()
    ctx.isUser = false
    check ctx.viewingChannel("ch1", "") == false

suite "user: connect / disconnect":
  test "connect succeeds with default stub":
    let ctx = makeTestUserCtx()
    let r = ctx.connect()
    check r.ok == true
    check ctx.isConnected == true

  test "connect fails without token":
    let ctx = makeTestUserCtx()
    ctx.discordToken = ""
    let r = ctx.connect()
    check r.ok == false
    check r.err == ErrNotLoggedIn

  test "connect with custom stub":
    let ctx = makeTestUserCtx()
    ctx.connectSession = proc(token: string): tuple[ok: bool, err: string] =
      (token == "test-token-123", "wrong token")
    let r = ctx.connect()
    check r.ok == true
    check ctx.isConnected == true

  test "connect with failing stub":
    let ctx = makeTestUserCtx()
    ctx.connectSession = proc(token: string): tuple[ok: bool, err: string] =
      (false, "connection refused")
    let r = ctx.connect()
    check r.ok == false
    check r.err == "connection refused"
    check ctx.isConnected == false

  test "disconnect fails when not connected":
    let ctx = makeTestUserCtx()
    let r = ctx.disconnect()
    check r.ok == false
    check r.err == ErrNotConnected

  test "disconnect succeeds when connected":
    let ctx = makeTestUserCtx()
    ctx.isConnected = true
    let r = ctx.disconnect()
    check r.ok == true
    check ctx.isConnected == false

suite "user: login":
  test "login succeeds with valid token":
    let ctx = makeTestUserCtx()
    ctx.discordToken = ""
    let r = ctx.login("valid-token")
    check r.ok == true
    check ctx.discordToken == "valid-token"
    check ctx.isConnected == true

  test "login retries on transient failure":
    var attempts = 0
    let ctx = makeTestUserCtx()
    ctx.discordToken = ""
    ctx.connectSession = proc(token: string): tuple[ok: bool, err: string] =
      inc attempts
      if attempts < 3:
        return (false, "temporary error")
      (true, "")
    let r = ctx.login("test-tok")
    check r.ok == true
    check attempts == 3

  test "login breaks on fatal close code 4004":
    let ctx = makeTestUserCtx()
    ctx.discordToken = ""
    ctx.connectSession = proc(token: string): tuple[ok: bool, err: string] =
      (false, "close 4004: invalid auth")
    let r = ctx.login("bad-tok")
    check r.ok == false
    check r.err.contains("4004")
    check ctx.discordToken == ""

suite "user: logout":
  test "logout clears state":
    let ctx = makeTestUserCtx()
    ctx.isConnected = true
    ctx.readStateVersion = 5
    ctx.logout(false)
    check ctx.isConnected == false
    check ctx.discordToken == ""
    check ctx.discordId == ""
    check ctx.readStateVersion == 0

suite "user: guild bridging mode":
  test "empty guildId returns gbmEverything":
    let ctx = makeTestUserCtx()
    check ctx.getGuildBridgingMode("") == gbmEverything

  test "unknown guild returns gbmNothing":
    let ctx = makeTestUserCtx()
    check ctx.getGuildBridgingMode("nonexistent") == gbmNothing

  test "existing guild returns stored mode":
    let ctx = makeTestUserCtx()
    var guild = newGuildRecord("g1")
    guild.bridgingMode = gbmCreateOnMessage
    ctx.runtime.guilds.upsert(guild)
    check ctx.getGuildBridgingMode("g1") == gbmCreateOnMessage

suite "user: channelIsBridgeable":
  test "DM channels are bridgeable":
    let ctx = makeTestUserCtx()
    check ctx.channelIsBridgeable(DiscordChannel(chanType: channelTypeDM)) == true

  test "GroupDM channels are bridgeable":
    let ctx = makeTestUserCtx()
    check ctx.channelIsBridgeable(DiscordChannel(chanType: channelTypeGroupDM)) == true

  test "Guild text channels are bridgeable":
    let ctx = makeTestUserCtx()
    check ctx.channelIsBridgeable(DiscordChannel(chanType: 0)) == true

  test "Guild news channels are bridgeable":
    let ctx = makeTestUserCtx()
    check ctx.channelIsBridgeable(DiscordChannel(chanType: 5)) == true

  test "Voice channels are not bridgeable":
    let ctx = makeTestUserCtx()
    check ctx.channelIsBridgeable(DiscordChannel(chanType: 2)) == false

  test "Category channels are not bridgeable":
    let ctx = makeTestUserCtx()
    check ctx.channelIsBridgeable(DiscordChannel(chanType: channelTypeGuildCategory)) == false

suite "user: read markers":
  test "makeReadMarkerContent sets fields":
    let ctx = makeTestUserCtx()
    let markers = ctx.makeReadMarkerContent("$evt1")
    check markers.read == "$evt1"
    check markers.fullyRead == "$evt1"
    check markers.readExtra.doublePuppetSource == "mautrix-discord"
    check markers.fullyReadExtra.doublePuppetSource == "mautrix-discord"

suite "user: addToSpace helpers":
  test "addPrivateChannelToSpace returns false without dmSpaceRoom":
    let ctx = makeTestUserCtx()
    check ctx.addPrivateChannelToSpace("!room:hs") == false

  test "addPrivateChannelToSpace calls stub":
    let ctx = makeTestUserCtx()
    ctx.dmSpaceRoom = "!dmspace:hs"
    var called = false
    ctx.addToSpace = proc(parent, child: string): tuple[ok: bool, err: string] =
      called = true
      check parent == "!dmspace:hs"
      check child == "!room:hs"
      (true, "")
    check ctx.addPrivateChannelToSpace("!room:hs") == true
    check called == true

  test "addGuildToSpace returns false without spaceRoom":
    let ctx = makeTestUserCtx()
    check ctx.addGuildToSpace("!guild:hs") == false

  test "addGuildToSpace calls stub":
    let ctx = makeTestUserCtx()
    ctx.spaceRoom = "!space:hs"
    var called = false
    ctx.addToSpace = proc(parent, child: string): tuple[ok: bool, err: string] =
      called = true
      (true, "")
    check ctx.addGuildToSpace("!guild:hs") == true
    check called

suite "user: connection state handlers":
  test "connectedHandler clears wasDisconnected":
    let ctx = makeTestUserCtx()
    ctx.wasDisconnected = true
    ctx.connectedHandler()
    check ctx.wasDisconnected == false

  test "disconnectedHandler sets wasDisconnected and sends state":
    let ctx = makeTestUserCtx()
    let (logger, log) = makeBridgeStateLogger()
    ctx.sendBridgeState = logger
    ctx.disconnectedHandler()
    check ctx.wasDisconnected == true
    check log[].len == 1
    check log[][0].stateEvent == bseTransientDisconnect

  test "disconnectedHandler skipped if wasLoggedOut":
    let ctx = makeTestUserCtx()
    ctx.wasLoggedOut = true
    let (logger, log) = makeBridgeStateLogger()
    ctx.sendBridgeState = logger
    ctx.disconnectedHandler()
    check ctx.wasDisconnected == false
    check log[].len == 0

  test "invalidAuthHandler sends bad credentials and logs out":
    let ctx = makeTestUserCtx()
    ctx.isConnected = true
    let (logger, log) = makeBridgeStateLogger()
    ctx.sendBridgeState = logger
    ctx.invalidAuthHandler()
    check ctx.wasLoggedOut == true
    check ctx.isConnected == false
    check ctx.discordToken == ""
    check log[].len == 1
    check log[][0].stateEvent == bseBadCredentials

  test "handlePossible40002 returns true for 40002 errors":
    let ctx = makeTestUserCtx()
    let (logger, log) = makeBridgeStateLogger()
    ctx.sendBridgeState = logger
    check ctx.handlePossible40002("error 40002: locked out") == true
    check log[].len == 1

  test "handlePossible40002 returns false for other errors":
    let ctx = makeTestUserCtx()
    check ctx.handlePossible40002("error 50001: missing access") == false

suite "user: guild event handlers":
  test "guildCreateHandler creates guild record":
    let ctx = makeTestUserCtx()
    let meta = DiscordGuildMeta(id: "g1", name: "Test Guild")
    ctx.guildCreateHandler(meta)
    let guild = ctx.runtime.guilds.getByID("g1")
    check guild.found == true
    check guild.rec.name == "Test Guild"

  test "guildDeleteHandler removes portal for available guild":
    let ctx = makeTestUserCtx()
    ctx.markInPortal("g1", "guild", false)
    check ctx.isInPortal("g1") == true
    ctx.guildDeleteHandler("g1", false)
    check ctx.isInPortal("g1") == false

  test "guildDeleteHandler ignores unavailable guilds":
    let ctx = makeTestUserCtx()
    ctx.markInPortal("g1", "guild", false)
    ctx.guildDeleteHandler("g1", true)
    check ctx.isInPortal("g1") == true

suite "user: channel event handlers":
  test "channelCreateHandler skips non-everything mode":
    let ctx = makeTestUserCtx()
    var created = false
    ctx.createPortalRoom = proc(key: PortalKey, meta: DiscordChannel): tuple[ok: bool, err: string] =
      created = true
      (true, "")
    # Guild with gbmNothing
    var guild = newGuildRecord("g1")
    guild.bridgingMode = gbmNothing
    ctx.runtime.guilds.upsert(guild)
    ctx.channelCreateHandler(DiscordChannel(id: "ch1", guildId: "g1", chanType: 0))
    check created == false

  test "channelDeleteHandler calls deletePortal":
    let ctx = makeTestUserCtx()
    # Create a portal first
    let key = PortalKey(channelId: "ch1", receiver: "")
    var rec = newPortalRecord(key, 0)
    rec.mxid = "!room:hs"
    ctx.runtime.portals.upsert(rec)
    var deleted = false
    ctx.deletePortal = proc(k: PortalKey, cleanup: bool) =
      deleted = true
      check k.channelId == "ch1"
    ctx.channelDeleteHandler("ch1", "g1")
    check deleted == true

  test "channelUpdateHandler updates portal info":
    let ctx = makeTestUserCtx()
    let key = PortalKey(channelId: "ch1", receiver: "")
    var rec = newPortalRecord(key, 0)
    rec.mxid = "!room:hs"
    ctx.runtime.portals.upsert(rec)
    var updated = false
    ctx.updatePortalInfo = proc(k: PortalKey, meta: DiscordChannel) =
      updated = true
      check k.channelId == "ch1"
    ctx.channelUpdateHandler(DiscordChannel(id: "ch1", guildId: "g1", chanType: 0))
    check updated == true

suite "user: channel recipient handlers":
  test "channelRecipientAdd calls syncParticipant":
    let ctx = makeTestUserCtx()
    let key = PortalKey(channelId: "ch1", receiver: "")
    var rec = newPortalRecord(key, 0)
    rec.mxid = "!room:hs"
    ctx.runtime.portals.upsert(rec)
    var synced = false
    ctx.syncParticipant = proc(k: PortalKey, uid: string, remove: bool) =
      synced = true
      check uid == "user1"
      check remove == false
    ctx.channelRecipientAdd("ch1", "user1")
    check synced == true

  test "channelRecipientRemove calls syncParticipant with remove":
    let ctx = makeTestUserCtx()
    let key = PortalKey(channelId: "ch1", receiver: "")
    var rec = newPortalRecord(key, 0)
    rec.mxid = "!room:hs"
    ctx.runtime.portals.upsert(rec)
    var synced = false
    ctx.syncParticipant = proc(k: PortalKey, uid: string, remove: bool) =
      synced = true
      check remove == true
    ctx.channelRecipientRemove("ch1", "user1")
    check synced == true

suite "user: findPortal":
  test "finds existing portal":
    let ctx = makeTestUserCtx()
    let key = PortalKey(channelId: "ch1", receiver: "")
    var rec = newPortalRecord(key, 0)
    rec.mxid = "!room:hs"
    ctx.runtime.portals.upsert(rec)
    let result = ctx.findPortal("ch1")
    check result.found == true
    check result.portalKey.channelId == "ch1"
    check result.threadId == ""

  test "returns not found for unknown channel":
    let ctx = makeTestUserCtx()
    let result = ctx.findPortal("unknown")
    check result.found == false

suite "user: typing handler":
  test "typingStartHandler calls handleTyping for other users":
    let ctx = makeTestUserCtx()
    let key = PortalKey(channelId: "ch1", receiver: "")
    var rec = newPortalRecord(key, 0)
    rec.mxid = "!room:hs"
    ctx.runtime.portals.upsert(rec)
    var handledUser = ""
    ctx.handleTyping = proc(k: PortalKey, uid: string) =
      handledUser = uid
    ctx.typingStartHandler("ch1", "other-user")
    check handledUser == "other-user"

  test "typingStartHandler ignores own typing":
    let ctx = makeTestUserCtx()
    let key = PortalKey(channelId: "ch1", receiver: "")
    var rec = newPortalRecord(key, 0)
    rec.mxid = "!room:hs"
    ctx.runtime.portals.upsert(rec)
    var called = false
    ctx.handleTyping = proc(k: PortalKey, uid: string) =
      called = true
    ctx.typingStartHandler("ch1", ctx.discordId)
    check called == false

suite "user: interaction success":
  test "interactionSuccessHandler reacts and removes pending":
    let ctx = makeTestUserCtx()
    ctx.pendingInteractions["nonce1"] = "$evt:hs"
    var reactedId = ""
    ctx.reactEvent = proc(roomId, eventId, emoji: string) =
      reactedId = eventId
    ctx.interactionSuccessHandler("nonce1", "interaction1")
    check reactedId == "$evt:hs"
    check ctx.pendingInteractions.hasKey("nonce1") == false

  test "interactionSuccessHandler ignores unknown nonces":
    let ctx = makeTestUserCtx()
    var called = false
    ctx.reactEvent = proc(roomId, eventId, emoji: string) =
      called = true
    ctx.interactionSuccessHandler("unknown", "id1")
    check called == false

suite "user: guild role handling":
  test "discordRoleToDB detects new role":
    let ctx = makeTestUserCtx()
    let role = DiscordRole(id: "r1", name: "Admin", color: 0xFF0000)
    check ctx.discordRoleToDB("g1", role, none(RoleRecord)) == true

  test "discordRoleToDB detects changed role":
    let ctx = makeTestUserCtx()
    let existing = RoleRecord(id: "r1", guildId: "g1", name: "Old")
    let role = DiscordRole(id: "r1", name: "New", color: 0xFF0000)
    check ctx.discordRoleToDB("g1", role, some(existing)) == true

  test "discordRoleToDB returns false for unchanged role":
    let ctx = makeTestUserCtx()
    let existing = RoleRecord(id: "r1", guildId: "g1", name: "Same", color: 5)
    let role = DiscordRole(id: "r1", name: "Same", color: 5)
    check ctx.discordRoleToDB("g1", role, some(existing)) == false

  test "handleGuildRoles counts changes":
    let ctx = makeTestUserCtx()
    let roles = @[
      DiscordRole(id: "r1", name: "Admin"),
      DiscordRole(id: "r2", name: "Mod"),
      DiscordRole(id: "r3", name: "Member"),
    ]
    check ctx.handleGuildRoles("g1", roles) == 3

suite "user: event dispatcher":
  test "eventHandler dispatches connect":
    let ctx = makeTestUserCtx()
    ctx.wasDisconnected = true
    ctx.eventHandler(DiscordEvent(kind: dekConnect))
    check ctx.wasDisconnected == false

  test "eventHandler dispatches disconnect":
    let ctx = makeTestUserCtx()
    let (logger, log) = makeBridgeStateLogger()
    ctx.sendBridgeState = logger
    ctx.eventHandler(DiscordEvent(kind: dekDisconnect))
    check ctx.wasDisconnected == true
    check log[].len >= 1

  test "eventHandler dispatches invalidAuth":
    let ctx = makeTestUserCtx()
    ctx.isConnected = true
    let (logger, log) = makeBridgeStateLogger()
    ctx.sendBridgeState = logger
    ctx.eventHandler(DiscordEvent(kind: dekInvalidAuth))
    check ctx.wasLoggedOut == true
    check ctx.isConnected == false

  test "eventHandler dispatches resume":
    let ctx = makeTestUserCtx()
    let (logger, log) = makeBridgeStateLogger()
    ctx.sendBridgeState = logger
    ctx.eventHandler(DiscordEvent(kind: dekResumed))
    check log[].len >= 1
    check log[][^1].stateEvent == bseConnected

suite "user: bridge/unbridge guild":
  test "bridgeGuild sets everything mode":
    let ctx = makeTestUserCtx()
    var guild = newGuildRecord("g1")
    ctx.runtime.guilds.upsert(guild)
    let r = ctx.bridgeGuild("g1", true)
    check r.ok == true
    let updated = ctx.runtime.guilds.getByID("g1")
    check updated.rec.bridgingMode == gbmEverything

  test "bridgeGuild sets createOnMessage mode":
    let ctx = makeTestUserCtx()
    var guild = newGuildRecord("g1")
    ctx.runtime.guilds.upsert(guild)
    let r = ctx.bridgeGuild("g1", false)
    check r.ok == true
    let updated = ctx.runtime.guilds.getByID("g1")
    check updated.rec.bridgingMode == gbmCreateOnMessage

  test "bridgeGuild fails for unknown guild":
    let ctx = makeTestUserCtx()
    let r = ctx.bridgeGuild("nonexistent", true)
    check r.ok == false
    check r.err == "guild not found"

  test "unbridgeGuild sets gbmNothing":
    let ctx = makeTestUserCtx()
    var guild = newGuildRecord("g1")
    guild.bridgingMode = gbmEverything
    guild.mxid = "!guildroom:hs"
    ctx.runtime.guilds.upsert(guild)
    let r = ctx.unbridgeGuild("g1")
    check r.ok == true
    let updated = ctx.runtime.guilds.getByID("g1")
    check updated.rec.bridgingMode == gbmNothing

  test "unbridgeGuild fails for already unbridged guild":
    let ctx = makeTestUserCtx()
    var guild = newGuildRecord("g1")
    guild.bridgingMode = gbmNothing
    guild.mxid = ""
    ctx.runtime.guilds.upsert(guild)
    let r = ctx.unbridgeGuild("g1")
    check r.ok == false
    check "not bridged" in r.err

  test "unbridgeGuild fails for non-admin with other users":
    let ctx = makeTestUserCtx()
    ctx.permissionLevel = plUser
    var guild = newGuildRecord("g1")
    guild.bridgingMode = gbmEverything
    guild.mxid = "!room:hs"
    ctx.runtime.guilds.upsert(guild)
    # Add another user to the portal
    let otherUser = UserRecord(mxid: "@other:hs.tld", discordId: "other1")
    ctx.runtime.db.insertUser(otherUser)
    ctx.runtime.db.markUserInPortal(UserPortalRecord(
      discordId: "g1", userMxid: "@other:hs.tld", portalType: "guild",
      inSpace: false, timestampMs: 1000
    ))
    let r = ctx.unbridgeGuild("g1")
    check r.ok == false
    check "admin" in r.err

suite "user: startup try connect":
  test "startupTryConnect succeeds on first try":
    let ctx = makeTestUserCtx()
    let (logger, log) = makeBridgeStateLogger()
    ctx.sendBridgeState = logger
    let r = ctx.startupTryConnect(0)
    check r.ok == true
    check log[].len >= 1
    check log[][0].stateEvent == bseConnecting

  test "startupTryConnect handles 4004 auth error":
    let ctx = makeTestUserCtx()
    ctx.connectSession = proc(token: string): tuple[ok: bool, err: string] =
      (false, "close 4004: invalid")
    let (logger, log) = makeBridgeStateLogger()
    ctx.sendBridgeState = logger
    let r = ctx.startupTryConnect(0)
    check r.ok == false
    check ctx.wasLoggedOut == true

  test "startupTryConnect sends transient error when retries remain":
    let ctx = makeTestUserCtx()
    ctx.connectSession = proc(token: string): tuple[ok: bool, err: string] =
      (false, "connection reset")
    let (logger, log) = makeBridgeStateLogger()
    ctx.sendBridgeState = logger
    let r = ctx.startupTryConnect(2, 6)
    check r.ok == false
    # Should have connecting + transient disconnect
    check log[].len >= 2
    check log[][^1].stateEvent == bseTransientDisconnect

suite "user: ready handler":
  test "readyHandler updates discordId and sends states":
    let ctx = makeTestUserCtx()
    ctx.discordId = ""
    let (logger, log) = makeBridgeStateLogger()
    ctx.sendBridgeState = logger
    let evt = DiscordReadyEvent(
      userId: "999888777",
      guilds: @[],
      privateChannels: @[],
      relationships: @[],
      readStateVersion: 0,
      readStateEntries: @[],
    )
    ctx.readyHandler(evt)
    check ctx.discordId == "999888777"
    check ctx.wasLoggedOut == false
    # Should have bseBackfilling, then bseConnected
    check log[].len >= 2
    check log[][0].stateEvent == bseBackfilling
    check log[][^1].stateEvent == bseConnected

  test "readyHandler processes relationships":
    let ctx = makeTestUserCtx()
    let (logger, _) = makeBridgeStateLogger()
    ctx.sendBridgeState = logger
    let evt = DiscordReadyEvent(
      userId: ctx.discordId,
      relationships: @[
        DiscordRelationship(id: "friend1", nickname: "BFF"),
        DiscordRelationship(id: "friend2", nickname: ""),
      ],
    )
    ctx.readyHandler(evt)
    check ctx.relationships.len == 2
    check ctx.relationships["friend1"].nickname == "BFF"

suite "user: ensureInvited":
  test "returns false for empty roomId":
    let ctx = makeTestUserCtx()
    check ctx.ensureInvited("", false) == false

  test "returns true for valid roomId":
    let ctx = makeTestUserCtx()
    check ctx.ensureInvited("!room:hs", true) == true

suite "user: direct chats":
  test "getDirectChats returns empty with no privates":
    let ctx = makeTestUserCtx()
    check ctx.getDirectChats().len == 0
