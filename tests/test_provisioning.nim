import std/[httpcore, json, os, times, unittest]
import config/config
import provisioning/[contracts, server]
import database/database
import database/entities
import database/store
import bridge/runtime
import discord/rest_client

var fetchBeforeBuf {.global.}: array[256, char]
var fetchBeforeLen {.global.}: int

proc setFetchBefore(value: string) {.gcsafe.} =
  fetchBeforeLen = min(value.len, fetchBeforeBuf.len)
  for i in 0 ..< fetchBeforeLen:
    fetchBeforeBuf[i] = value[i]

proc getFetchBefore(): string =
  result = newString(fetchBeforeLen)
  for i in 0 ..< fetchBeforeLen:
    result[i] = fetchBeforeBuf[i]

proc newTestApi(): ProvisioningApi =
  var cfg = defaultConfig()
  cfg.bridge.provisioning.prefix = "/_matrix/provision"
  cfg.bridge.provisioning.sharedSecret = "secret"
  result = newProvisioningApi(cfg)
  result.verifyDiscordToken = proc(token: string): tuple[
    ok: bool,
    discordId: string,
    username: string,
    discriminator: string,
    err: string
  ] =
    if token.len == 0 or token == "bad":
      (false, "", "", "", "invalid token")
    else:
      (true, "123", "alice", "0001", "")

proc makeHeaders(authHeader = "Bearer secret", wsProtocol = ""): HttpHeaders =
  result = newHttpHeaders()
  if authHeader.len > 0:
    result["Authorization"] = authHeader
  if wsProtocol.len > 0:
    result["Sec-WebSocket-Protocol"] = wsProtocol

proc call(
    api: ProvisioningApi,
    reqMethod: HttpMethod,
    path: string,
    query = "user_id=%40alice%3Alocalhost",
    body = "",
    authHeader = "Bearer secret",
    wsProtocol = ""
): ProvisioningResult =
  api.handleRequest(reqMethod, path, query, makeHeaders(authHeader, wsProtocol), body)

proc openRuntimeApi(name: string): tuple[api: ProvisioningApi, dbPath: string] =
  let dbPath = "tests/fixtures/" & name & "-" & $getTime().toUnix() & "-" & $epochTime().int64 & ".db"
  let db = openBridgeDb("file:" & dbPath, "sqlite")
  var cfg = defaultConfig()
  cfg.bridge.provisioning.prefix = "/_matrix/provision"
  cfg.bridge.provisioning.sharedSecret = "secret"
  cfg.homeserver.address = "http://127.0.0.1:9"
  let rt = newDiscordBridgeRuntime(cfg, db)
  result = (newProvisioningApi(cfg, rt), dbPath)
  result.api.verifyDiscordToken = proc(token: string): tuple[
    ok: bool,
    discordId: string,
    username: string,
    discriminator: string,
    err: string
  ] =
    if token.len == 0 or token == "bad":
      (false, "", "", "", "invalid token")
    else:
      (true, "123", "alice", "0001", "")

proc seedBackfillPortal(
    api: ProvisioningApi,
    mxid: string,
    roomId: string,
    channelId: string,
    portalType: int = 1,
    markMembership = true
) =
  var rec = newUserRecord(mxid)
  rec.discordId = "123"
  rec.discordToken = "token"
  api.runtime.db.insertUser(rec)

  var portal = newPortalRecord(PortalKey(channelId: channelId, receiver: ""), portalType)
  portal.mxid = roomId
  api.runtime.db.insertPortal(portal)

  if markMembership:
    api.runtime.db.markUserInPortal(UserPortalRecord(
      discordId: channelId,
      userMxid: mxid,
      portalType: "dm",
      inSpace: false,
      timestampMs: getTime().toUnix.int64 * 1000
    ))

suite "provisioning":
  test "auth required":
    let api = newTestApi()
    let res = api.call(HttpGet, "/_matrix/provision/v1/ping", authHeader = "")
    check res.handled
    check res.code == Http401
    check res.payload["errcode"].getStr() == ErrCodeUnknownToken

  test "ping reports user state":
    let api = newTestApi()
    let res = api.call(HttpGet, "/_matrix/provision/v1/ping")
    check res.handled
    check res.code == Http200
    check res.payload["mxid"].getStr() == "@alice:localhost"
    check not res.payload["discord"]["logged_in"].getBool()
    check not res.payload["discord"]["connected"].getBool()

  test "token login parse and idempotent behavior":
    let api = newTestApi()

    let bad = api.call(HttpPost, "/_matrix/provision/v1/login/token", body = "{")
    check bad.code == Http400
    check bad.payload["errcode"].getStr() == ErrCodeBadJson

    let ok = api.call(HttpPost, "/_matrix/provision/v1/login/token", body = """{"token":"MTIz.abc.xyz"}""")
    check ok.code == Http200
    check ok.payload["success"].getBool()
    check ok.payload["id"].getStr() == "123"

    let repeat = api.call(HttpPost, "/_matrix/provision/v1/login/token", body = """{"token":"MTIz.abc.xyz"}""")
    check repeat.code == Http200
    check repeat.payload["success"].getBool()
    check repeat.payload["id"].getStr() == "123"

  test "disconnect reconnect and logout lifecycle":
    let api = newTestApi()
    discard api.call(HttpPost, "/_matrix/provision/v1/login/token", body = """{"token":"MTIz.abc.xyz"}""")

    let disconnected = api.call(HttpPost, "/_matrix/provision/v1/disconnect")
    check disconnected.code == Http200

    let disconnectConflict = api.call(HttpPost, "/_matrix/provision/v1/disconnect")
    check disconnectConflict.code == Http409
    check disconnectConflict.payload["errcode"].getStr() == ErrCodeNotConnected

    let reconnected = api.call(HttpPost, "/_matrix/provision/v1/reconnect")
    check reconnected.code == Http200

    let reconnectConflict = api.call(HttpPost, "/_matrix/provision/v1/reconnect")
    check reconnectConflict.code == Http409
    check reconnectConflict.payload["errcode"].getStr() == ErrCodeAlreadyConnected

    let loggedOut = api.call(HttpPost, "/_matrix/provision/v1/logout")
    check loggedOut.code == Http200
    check loggedOut.payload["success"].getBool()

    let ping = api.call(HttpGet, "/_matrix/provision/v1/ping")
    check ping.code == Http200
    check not ping.payload["discord"]["logged_in"].getBool()
    check not ping.payload["discord"]["connected"].getBool()
    check ping.payload["discord"]["id"].getStr() == ""

  test "token login reassigns existing discord id to current user":
    let api = newTestApi()
    let aliceQuery = "user_id=%40alice%3Alocalhost"
    let bobQuery = "user_id=%40bob%3Alocalhost"

    let aliceLogin = api.call(HttpPost, "/_matrix/provision/v1/login/token", query = aliceQuery, body = """{"token":"MTIz.abc.xyz"}""")
    check aliceLogin.code == Http200

    let bobLogin = api.call(HttpPost, "/_matrix/provision/v1/login/token", query = bobQuery, body = """{"token":"MTIz.abc.xyz"}""")
    check bobLogin.code == Http200
    check bobLogin.payload["id"].getStr() == "123"

    let alicePing = api.call(HttpGet, "/_matrix/provision/v1/ping", query = aliceQuery)
    check alicePing.code == Http200
    check not alicePing.payload["discord"]["logged_in"].getBool()
    check alicePing.payload["discord"]["id"].getStr() == ""

    let bobPing = api.call(HttpGet, "/_matrix/provision/v1/ping", query = bobQuery)
    check bobPing.code == Http200
    check bobPing.payload["discord"]["logged_in"].getBool()
    check bobPing.payload["discord"]["id"].getStr() == "123"

  test "websocket subprotocol auth accepted for qr login":
    let api = newTestApi()
    let res = api.call(
      HttpGet,
      "/_matrix/provision/v1/login/qr",
      authHeader = "",
      wsProtocol = "chat, " & SecWebSocketProtocol & "-secret"
    )
    check res.code == Http400
    check res.payload["errcode"].getStr() == ErrCodeLoginPrepareFailed

  test "unknown endpoint and disabled prefix behavior":
    let api = newTestApi()
    let missing = api.call(HttpGet, "/_matrix/provision/v1/unknown")
    check missing.code == Http404
    check missing.payload["errcode"].getStr() == ErrCodeNotFound

    var cfg = defaultConfig()
    cfg.bridge.provisioning.prefix = "disable"
    cfg.bridge.provisioning.sharedSecret = "secret"
    let disabled = newProvisioningApi(cfg)
    let res = disabled.handleRequest(HttpGet, "/_matrix/provision/v1/ping", "", makeHeaders(), "")
    check not res.handled

  test "runtime-backed token login does not crash when bootstrap fails":
    let opened = openRuntimeApi("provisioning-runtime")
    defer:
      if fileExists(opened.dbPath):
        removeFile(opened.dbPath)

    let ok = opened.api.call(HttpPost, "/_matrix/provision/v1/login/token", body = """{"token":"MTIz.abc.xyz"}""")
    check ok.code == Http200
    check ok.payload["success"].getBool()

  test "startup resume clears invalid discord token and keeps session disconnected":
    let opened = openRuntimeApi("provisioning-invalid-token")
    defer:
      if fileExists(opened.dbPath):
        removeFile(opened.dbPath)

    var rec = newUserRecord("@alice:localhost")
    rec.discordId = "123"
    rec.discordToken = "bad"
    opened.api.runtime.db.insertUser(rec)

    opened.api.resumePersistedDiscordSessions()

    let stored = opened.api.runtime.db.getUserByMXID("@alice:localhost")
    check stored.found
    check stored.rec.discordToken == ""
    check stored.rec.discordId == ""
    let ping = opened.api.call(HttpGet, "/_matrix/provision/v1/ping")
    check ping.code == Http200
    check not ping.payload["discord"]["logged_in"].getBool()
    check not ping.payload["discord"]["connected"].getBool()

  test "history_backfill requires room_id":
    let opened = openRuntimeApi("provisioning-history-required-room")
    defer:
      if fileExists(opened.dbPath):
        removeFile(opened.dbPath)
    var user = newUserRecord("@alice:localhost")
    user.discordId = "123"
    user.discordToken = "token"
    opened.api.runtime.db.insertUser(user)
    let res = opened.api.call(HttpPost, "/_matrix/provision/v1/discord/history_backfill", body = """{"limit":25}""")
    check res.code == Http400
    check res.payload["errcode"].getStr() == ErrCodeBadJson

  test "history_backfill rejects non-dm portals":
    let opened = openRuntimeApi("provisioning-history-non-dm")
    defer:
      if fileExists(opened.dbPath):
        removeFile(opened.dbPath)
    seedBackfillPortal(opened.api, "@alice:localhost", "!room:localhost", "ch-non-dm", portalType = 0)
    let res = opened.api.call(
      HttpPost,
      "/_matrix/provision/v1/discord/history_backfill",
      body = """{"room_id":"!room:localhost","limit":25}"""
    )
    check res.code == Http400
    check res.payload["errcode"].getStr() == ErrCodeBadJson

  test "history_backfill uses explicit cursor and returns success contract":
    let opened = openRuntimeApi("provisioning-history-cursor")
    defer:
      if fileExists(opened.dbPath):
        removeFile(opened.dbPath)
    seedBackfillPortal(opened.api, "@alice:localhost", "!dm:localhost", "ch-cursor", portalType = 1)
    setFetchBefore("")
    opened.api.fetchDiscordMessages = proc(
      token: string,
      channelId: string,
      limit: int,
      before: string,
      after: string
    ): DiscordRestResult {.closure, gcsafe.} =
      setFetchBefore(before)
      return (true, 200, %*[], "")
    let res = opened.api.call(
      HttpPost,
      "/_matrix/provision/v1/discord/history_backfill",
      body = """{"room_id":"!dm:localhost","limit":25,"cursor":"555"}"""
    )
    check res.code == Http200
    check getFetchBefore() == "555"
    check res.payload["success"].getBool()
    check res.payload["inserted_count"].getInt(999) == 0
    check res.payload["next_cursor"].getStr("x") == ""
    check not res.payload["has_more"].getBool(true)
    check res.payload["endpoint_available"].getBool(false)

  test "history_backfill falls back to oldest_event_id mapping":
    let opened = openRuntimeApi("provisioning-history-oldest-event")
    defer:
      if fileExists(opened.dbPath):
        removeFile(opened.dbPath)
    seedBackfillPortal(opened.api, "@alice:localhost", "!dm-old:localhost", "ch-old", portalType = 1)
    opened.api.runtime.db.insertMessage(MessageRecord(
      discordId: "777",
      attachmentId: "",
      channelId: "ch-old",
      channelReceiver: "",
      senderId: "u1",
      timestampMs: getTime().toUnix.int64 * 1000,
      editTimestampNs: 0,
      threadId: "",
      mxid: "$old_evt",
      senderMxid: "@discord_u1:localhost"
    ))
    setFetchBefore("")
    opened.api.fetchDiscordMessages = proc(
      token: string,
      channelId: string,
      limit: int,
      before: string,
      after: string
    ): DiscordRestResult {.closure, gcsafe.} =
      setFetchBefore(before)
      return (true, 200, %*[], "")
    let res = opened.api.call(
      HttpPost,
      "/_matrix/provision/v1/discord/history_backfill",
      body = """{"room_id":"!dm-old:localhost","limit":25,"oldest_event_id":"$old_evt"}"""
    )
    check res.code == Http200
    check getFetchBefore() == "777"

  test "history_backfill returns synthetic events when mapped fetch is unavailable":
    let opened = openRuntimeApi("provisioning-history-synthetic-fallback")
    defer:
      if fileExists(opened.dbPath):
        removeFile(opened.dbPath)
    seedBackfillPortal(opened.api, "@alice:localhost", "!dm-synth:localhost", "ch-synth", portalType = 1)
    opened.api.runtime.db.insertMessage(MessageRecord(
      discordId: "500",
      attachmentId: "",
      channelId: "ch-synth",
      channelReceiver: "",
      senderId: "u1",
      timestampMs: getTime().toUnix.int64 * 1000,
      editTimestampNs: 0,
      threadId: "",
      mxid: "$mapped500",
      senderMxid: "@discord_u1:localhost"
    ))
    var fetchCalls = 0
    opened.api.fetchDiscordMessages = proc(
      token: string,
      channelId: string,
      limit: int,
      before: string,
      after: string
    ): DiscordRestResult {.closure, gcsafe.} =
      inc fetchCalls
      if fetchCalls == 1:
        # Initial auto-cursor request (before oldest mapped) yields no results.
        return (true, 200, %*[], "")
      # Latest fallback request returns one Discord message.
      return (true, 200, %*[
        {
          "id": "600",
          "content": "hello from discord fallback",
          "author": {
            "id": "42",
            "username": "fallback-user"
          },
          "attachments": []
        }
      ], "")
    let res = opened.api.call(
      HttpPost,
      "/_matrix/provision/v1/discord/history_backfill",
      body = """{"room_id":"!dm-synth:localhost","limit":25}"""
    )
    check res.code == Http200
    check fetchCalls == 2
    check res.payload["inserted_count"].getInt(-1) == 0
    check res.payload.hasKey("events")
    check res.payload["events"].kind == JArray
    check res.payload["events"].len > 0
    let first = res.payload["events"][0]
    check first{"room_id"}.getStr("") == "!dm-synth:localhost"
    check first{"type"}.getStr("") == "m.room.message"
    check first{"content"}{"body"}.getStr("") == "hello from discord fallback"
