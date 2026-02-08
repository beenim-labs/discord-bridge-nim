import std/[base64, strutils, unittest]
import bridge/commands/commands
import bridge/commands/core_utils
import database/entities

proc rawUrlB64(s: string): string =
  var encoded = encode(s)
  encoded = encoded.replace('+', '-').replace('/', '_')
  while encoded.len > 0 and encoded[^1] == '=':
    encoded.setLen(encoded.len - 1)
  encoded

suite "commands handler":
  test "fnLoginToken usage with wrong arg count":
    let ce = newCommandEvent("login-token", @["user"])
    fnLoginToken(ce)
    check ce.replies.len == 1
    check ce.replies[0].contains("Usage")

  test "fnLoginToken already logged in":
    let ce = newCommandEvent("login-token", @["user", "fake.token.here"])
    ce.userDiscordToken = "existing-token"
    fnLoginToken(ce)
    check ce.replies.len == 1
    check ce.replies[0].contains("already logged in")

  test "fnLoginToken invalid token format":
    let ce = newCommandEvent("login-token", @["user", "bad-token"])
    fnLoginToken(ce)
    check ce.replies.len == 1
    check ce.replies[0].contains("Invalid token")

  test "fnLoginToken invalid type":
    let token = rawUrlB64("12345") & "." & rawUrlB64("rand") & "." & rawUrlB64("chk")
    let ce = newCommandEvent("login-token", @["magic", token])
    fnLoginToken(ce)
    check ce.replies.len == 1
    check ce.replies[0].contains("Token type must be")

  test "fnLoginToken success user token":
    let token = rawUrlB64("12345") & "." & rawUrlB64("rand") & "." & rawUrlB64("chk")
    let ce = newCommandEvent("login-token", @["user", token])
    ce.userSessionUsername = "TestUser"
    var loginCalled = false
    var loginToken = ""
    ce.userLogin = proc(t: string): tuple[ok: bool, err: string] {.closure.} =
      loginCalled = true
      loginToken = t
      (true, "")
    fnLoginToken(ce)
    check loginCalled
    check loginToken == token
    check ce.replies.len == 2
    check ce.replies[0].contains("Connecting to Discord as user ID 12345")
    check ce.replies[1].contains("Successfully logged in as @TestUser")

  test "fnLoginToken bot prefix":
    let token = rawUrlB64("99999") & "." & rawUrlB64("rand") & "." & rawUrlB64("chk")
    let ce = newCommandEvent("login-token", @["bot", token])
    ce.userSessionUsername = "BotUser"
    var gotToken = ""
    ce.userLogin = proc(t: string): tuple[ok: bool, err: string] {.closure.} =
      gotToken = t
      (true, "")
    fnLoginToken(ce)
    check gotToken == "Bot " & token

  test "fnLoginToken login failure":
    let token = rawUrlB64("12345") & "." & rawUrlB64("rand") & "." & rawUrlB64("chk")
    let ce = newCommandEvent("login-token", @["user", token])
    ce.userLogin = proc(t: string): tuple[ok: bool, err: string] {.closure.} =
      (false, "connection refused")
    fnLoginToken(ce)
    check ce.replies.len == 2
    check ce.replies[1].contains("Error connecting to Discord")
    check ce.replies[1].contains("connection refused")

  test "fnLogout was logged in":
    let ce = newCommandEvent("logout")
    ce.userDiscordId = "12345"
    var logoutCalled = false
    ce.userLogout = proc(isOverwriting: bool) {.closure.} =
      logoutCalled = true
    fnLogout(ce)
    check logoutCalled
    check ce.replies.len == 1
    check ce.replies[0].contains("Logged out successfully")

  test "fnLogout was not logged in":
    let ce = newCommandEvent("logout")
    ce.userDiscordId = ""
    fnLogout(ce)
    check ce.replies.len == 1
    check ce.replies[0].contains("weren't logged in")

  test "fnPing not logged in":
    let ce = newCommandEvent("ping")
    ce.userDiscordToken = ""
    fnPing(ce)
    check ce.replies.len == 1
    check ce.replies[0].contains("not logged in")

  test "fnPing connected":
    let ce = newCommandEvent("ping")
    ce.userDiscordToken = "tok"
    ce.userIsConnected = true
    ce.userSessionUsername = "TestUser"
    ce.userDiscordId = "12345"
    fnPing(ce)
    check ce.replies.len == 1
    check ce.replies[0].contains("@TestUser")
    check ce.replies[0].contains("12345")

  test "fnPing disconnected":
    let ce = newCommandEvent("ping")
    ce.userDiscordToken = "tok"
    ce.userIsConnected = false
    ce.userWasDisconnected = true
    fnPing(ce)
    check ce.replies.len == 1
    check ce.replies[0].contains("dead")

  test "fnPing token but not connected":
    let ce = newCommandEvent("ping")
    ce.userDiscordToken = "tok"
    ce.userIsConnected = false
    ce.userWasDisconnected = false
    fnPing(ce)
    check ce.replies.len == 1
    check ce.replies[0].contains("not connected for some reason")

  test "fnDisconnect already disconnected":
    let ce = newCommandEvent("disconnect")
    ce.userIsConnected = false
    fnDisconnect(ce)
    check ce.replies.len == 1
    check ce.replies[0].contains("already not connected")

  test "fnDisconnect success":
    let ce = newCommandEvent("disconnect")
    ce.userIsConnected = true
    var called = false
    ce.userDisconnect = proc(): tuple[ok: bool, err: string] {.closure.} =
      called = true
      (true, "")
    fnDisconnect(ce)
    check called
    check ce.replies[0].contains("Successfully disconnected")

  test "fnDisconnect error":
    let ce = newCommandEvent("disconnect")
    ce.userIsConnected = true
    ce.userDisconnect = proc(): tuple[ok: bool, err: string] {.closure.} =
      (false, "ws broke")
    fnDisconnect(ce)
    check ce.replies[0].contains("Error while disconnecting")

  test "fnReconnect already connected":
    let ce = newCommandEvent("reconnect")
    ce.userIsConnected = true
    fnReconnect(ce)
    check ce.replies[0].contains("already connected")

  test "fnReconnect success":
    let ce = newCommandEvent("reconnect")
    ce.userIsConnected = false
    var called = false
    ce.userConnect = proc(): tuple[ok: bool, err: string] {.closure.} =
      called = true
      (true, "")
    fnReconnect(ce)
    check called
    check ce.replies[0].contains("Successfully reconnected")

  test "fnReconnect error":
    let ce = newCommandEvent("reconnect")
    ce.userIsConnected = false
    ce.userConnect = proc(): tuple[ok: bool, err: string] {.closure.} =
      (false, "timeout")
    fnReconnect(ce)
    check ce.replies[0].contains("Error while reconnecting")

  test "fnRejoinSpace no args":
    let ce = newCommandEvent("rejoin-space")
    fnRejoinSpace(ce)
    check ce.replies[0].contains("Usage")

  test "fnRejoinSpace main":
    let ce = newCommandEvent("rejoin-space", @["main"])
    ce.userSpaceRoom = "!space:local"
    var invitedRoom = ""
    ce.ensureInvited = proc(roomId: string, isDirect: bool): bool {.closure.} =
      invitedRoom = roomId
      true
    fnRejoinSpace(ce)
    check invitedRoom == "!space:local"
    check ce.replies[0].contains("main space")

  test "fnRejoinSpace dms":
    let ce = newCommandEvent("rejoin-space", @["dms"])
    ce.userDmSpaceRoom = "!dmspace:local"
    var invitedRoom = ""
    ce.ensureInvited = proc(roomId: string, isDirect: bool): bool {.closure.} =
      invitedRoom = roomId
      true
    fnRejoinSpace(ce)
    check invitedRoom == "!dmspace:local"
    check ce.replies[0].contains("DM space")

  test "fnRejoinSpace guild ID not yet implemented":
    let ce = newCommandEvent("rejoin-space", @["123456"])
    fnRejoinSpace(ce)
    check ce.replies[0].contains("not yet implemented")

  test "fnGuilds no args shows help":
    let ce = newCommandEvent("guilds")
    fnGuilds(ce)
    check ce.replies[0].contains("Usage")

  test "fnGuilds status empty":
    let ce = newCommandEvent("guilds", @["status"])
    ce.getPortals = proc(): seq[UserPortalRecord] {.closure.} = @[]
    fnGuilds(ce)
    check ce.replies[0].contains("No guilds found")

  test "fnGuilds status with guilds":
    let ce = newCommandEvent("guilds", @["status"])
    ce.getPortals = proc(): seq[UserPortalRecord] {.closure.} =
      @[UserPortalRecord(discordId: "111")]
    ce.getGuildByID = proc(id: string): tuple[found: bool, rec: GuildRecord] {.closure.} =
      if id == "111":
        (true, GuildRecord(id: "111", name: "Test Guild", bridgingMode: gbmCreateOnMessage))
      else:
        (false, GuildRecord())
    fnGuilds(ce)
    check ce.replies.len == 1
    check ce.replies[0].contains("Test Guild")
    check ce.replies[0].contains("111")

  test "fnGuilds bridge success":
    let ce = newCommandEvent("guilds", @["bridge", "555"])
    var bridgedId = ""
    var bridgeEntire = false
    ce.bridgeGuild = proc(guildId: string, everything: bool): tuple[ok: bool, err: string] {.closure.} =
      bridgedId = guildId
      bridgeEntire = everything
      (true, "")
    fnGuilds(ce)
    check bridgedId == "555"
    check not bridgeEntire
    check ce.replies[0].contains("Successfully bridged guild")

  test "fnGuilds bridge entire":
    let ce = newCommandEvent("guilds", @["bridge", "555", "--entire"])
    var bridgeEntire = false
    ce.bridgeGuild = proc(guildId: string, everything: bool): tuple[ok: bool, err: string] {.closure.} =
      bridgeEntire = everything
      (true, "")
    fnGuilds(ce)
    check bridgeEntire

  test "fnGuilds bridge error":
    let ce = newCommandEvent("guilds", @["bridge", "555"])
    ce.bridgeGuild = proc(guildId: string, everything: bool): tuple[ok: bool, err: string] {.closure.} =
      (false, "guild not found")
    fnGuilds(ce)
    check ce.replies[0].contains("Error bridging guild")
    check ce.replies[0].contains("guild not found")

  test "fnGuilds unbridge success":
    let ce = newCommandEvent("guilds", @["unbridge", "555"])
    var unbridgedId = ""
    ce.unbridgeGuild = proc(guildId: string): tuple[ok: bool, err: string] {.closure.} =
      unbridgedId = guildId
      (true, "")
    fnGuilds(ce)
    check unbridgedId == "555"
    check ce.replies[0].contains("Successfully unbridged guild")

  test "fnGuilds bridging-mode query":
    let ce = newCommandEvent("guilds", @["bridging-mode", "111"])
    ce.getGuildByID = proc(id: string): tuple[found: bool, rec: GuildRecord] {.closure.} =
      (true, GuildRecord(id: "111", plainName: "MyGuild", bridgingMode: gbmCreateOnMessage))
    fnGuilds(ce)
    check ce.replies[0].contains("MyGuild")
    check ce.replies[0].contains("create-on-message")

  test "fnGuilds bridging-mode set":
    let ce = newCommandEvent("guilds", @["bridging-mode", "111", "everything"])
    ce.getGuildByID = proc(id: string): tuple[found: bool, rec: GuildRecord] {.closure.} =
      (true, GuildRecord(id: "111", plainName: "MyGuild", bridgingMode: gbmNothing))
    var updatedMode = gbmNothing
    ce.updateGuild = proc(rec: GuildRecord) {.closure.} =
      updatedMode = rec.bridgingMode
    fnGuilds(ce)
    check updatedMode == gbmEverything
    check ce.replies[0].contains("Set guild bridging mode to")

  test "fnGuilds bridging-mode invalid":
    let ce = newCommandEvent("guilds", @["bridging-mode", "111", "banana"])
    ce.getGuildByID = proc(id: string): tuple[found: bool, rec: GuildRecord] {.closure.} =
      (true, GuildRecord(id: "111", plainName: "MyGuild", bridgingMode: gbmNothing))
    fnGuilds(ce)
    check ce.replies[0].contains("Invalid guild bridging mode")

  test "fnGuilds bridging-mode guild not found":
    let ce = newCommandEvent("guilds", @["bridging-mode", "999"])
    ce.getGuildByID = proc(id: string): tuple[found: bool, rec: GuildRecord] {.closure.} =
      (false, GuildRecord())
    fnGuilds(ce)
    check ce.replies[0].contains("Guild not found")

  test "fnGuilds unknown subcommand":
    let ce = newCommandEvent("guilds", @["banana"])
    fnGuilds(ce)
    check ce.replies[0].contains("Unknown subcommand")

  test "fnSetRelay no portal":
    let ce = newCommandEvent("set-relay")
    ce.hasPortal = false
    fnSetRelay(ce)
    check ce.replies[0].contains("must either run the command in a portal")

  test "fnSetRelay not guild":
    let ce = newCommandEvent("set-relay", @["--url", "https://example.com"])
    ce.hasPortal = true
    ce.portalGuildId = ""
    fnSetRelay(ce)
    check ce.replies[0].contains("Only guild channels")

  test "fnSetRelay already has webhook":
    let ce = newCommandEvent("set-relay", @["--create"])
    ce.hasPortal = true
    ce.portalGuildId = "123"
    ce.portalRelayWebhookId = "existing-webhook"
    fnSetRelay(ce)
    check ce.replies[0].contains("already has a relay webhook")

  test "fnSetRelay no args":
    let ce = newCommandEvent("set-relay")
    ce.hasPortal = true
    ce.portalGuildId = "123"
    fnSetRelay(ce)
    check ce.replies[0].contains("Usage")

  test "fnUnsetRelay no webhook":
    let ce = newCommandEvent("unset-relay")
    ce.portalRelayWebhookId = ""
    fnUnsetRelay(ce)
    check ce.replies[0].contains("doesn't have a relay webhook")

  test "fnUnsetRelay delete":
    let ce = newCommandEvent("unset-relay", @["--delete"])
    ce.portalRelayWebhookId = "wh-123"
    fnUnsetRelay(ce)
    check ce.replies[0].contains("deleted webhook")

  test "fnUnsetRelay disable":
    let ce = newCommandEvent("unset-relay")
    ce.portalRelayWebhookId = "wh-123"
    fnUnsetRelay(ce)
    check ce.replies[0].contains("disabled")

  test "fnBridge already portal":
    let ce = newCommandEvent("bridge", @["12345"])
    ce.hasPortal = true
    fnBridge(ce)
    check ce.replies[0].contains("already a portal room")

  test "fnBridge no args":
    let ce = newCommandEvent("bridge")
    fnBridge(ce)
    check ce.replies[0].contains("Usage")

  test "fnBridge success":
    let ce = newCommandEvent("bridge", @["12345"])
    ce.hasPortal = false
    fnBridge(ce)
    check ce.replies[0].contains("successfully bridged")
    check ce.replies[0].contains("12345")

  test "fnBridge with replace":
    let ce = newCommandEvent("bridge", @["--replace", "12345"])
    ce.hasPortal = false
    fnBridge(ce)
    check ce.replies[0].contains("successfully bridged")

  test "fnUnbridge not a portal":
    let ce = newCommandEvent("unbridge")
    ce.hasPortal = false
    fnUnbridge(ce)
    check ce.replies[0].contains("not a portal room")

  test "fnUnbridge success":
    let ce = newCommandEvent("unbridge")
    ce.hasPortal = true
    fnUnbridge(ce)
    check ce.replies[0].contains("unbridged")

  test "fnCreatePortal no args":
    let ce = newCommandEvent("create-portal")
    fnCreatePortal(ce)
    check ce.replies[0].contains("Usage")

  test "fnCreatePortal with channel":
    let ce = newCommandEvent("create-portal", @["98765"])
    fnCreatePortal(ce)
    check ce.replies[0].contains("98765")

  test "fnDeleteAllPortals":
    let ce = newCommandEvent("delete-all-portals")
    fnDeleteAllPortals(ce)
    check ce.replies.len == 1

  test "GuildBridgingMode description":
    check gbmNothing.description() == "not bridging"
    check gbmIfPortalExists.description() == "portal exists"
    check gbmCreateOnMessage.description() == "create portal on message"
    check gbmEverything.description() == "bridging everything"

  test "GuildBridgingMode modeString":
    check gbmNothing.modeString() == "nothing"
    check gbmEverything.modeString() == "everything"

  test "parseGuildBridgingMode":
    check parseGuildBridgingMode("nothing") == gbmNothing
    check parseGuildBridgingMode("if-portal-exists") == gbmIfPortalExists
    check parseGuildBridgingMode("create-on-message") == gbmCreateOnMessage
    check parseGuildBridgingMode("everything") == gbmEverything
    check parseGuildBridgingMode("EVERYTHING") == gbmEverything
    check parseGuildBridgingMode("invalid") == gbmNothing

  test "command registry and dispatch":
    let defs = allCommandDefs()
    check defs.len >= 14
    check findCommand(defs, "ping") >= 0
    check findCommand(defs, "guilds") >= 0
    check findCommand(defs, "servers") >= 0  # alias for guilds
    check findCommand(defs, "connect") >= 0  # alias for reconnect
    check findCommand(defs, "nonexistent") == -1

  test "dispatch calls handler":
    let defs = allCommandDefs()
    let ce = newCommandEvent("ping")
    ce.userDiscordToken = ""
    let dispatched = dispatch(defs, ce)
    check dispatched
    check ce.replies.len == 1
    check ce.replies[0].contains("not logged in")

  test "dispatch unknown command returns false":
    let defs = allCommandDefs()
    let ce = newCommandEvent("nonexistent-cmd")
    let dispatched = dispatch(defs, ce)
    check not dispatched
    check ce.replies.len == 0
