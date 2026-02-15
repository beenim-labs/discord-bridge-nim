## Provisioning API shell compatible with Go route surface.

import std/[algorithm, asyncdispatch, asynchttpserver, base64, httpclient, json, locks, os, random, sets, strutils, tables, times, uri]
import config/config
import bridge/runtime
import database/[entities, store]
import provisioning/[contracts, ws_qr]
import remoteauth/live_client
import discord/rest_client
import common/logging

type
  UserSessionState = object
    connected: bool
    lastHeartbeatAck: int64
    lastHeartbeatSent: int64
    username: string
    discriminator: string

  PollingState = object
    lastSnapshot: string
    stableCycles: int
    delayMs: int
    lastWarn: string
    lastWarnAtMs: int64
    lastRelationshipSyncMs: int64

  RunQrLoginFn* = proc(timeoutMs: int, onQrCode: proc(url: string) {.closure, gcsafe.}): Future[RemoteAuthLoginResult] {.closure, gcsafe.}
  VerifyDiscordTokenFn* = proc(token: string): tuple[
    ok: bool,
    discordId: string,
    username: string,
    discriminator: string,
    err: string
  ] {.closure, gcsafe.}
  FetchDiscordMessagesFn* = proc(
    token: string,
    channelId: string,
    limit: int,
    before: string,
    after: string
  ): DiscordRestResult {.closure, gcsafe.}

  ProvisioningResult* = object
    handled*: bool
    code*: HttpCode
    payload*: JsonNode

  ProvisioningApi* = ref object
    cfg*: Config
    runtime*: DiscordBridgeRuntime
    runQrLogin*: RunQrLoginFn
    verifyDiscordToken*: VerifyDiscordTokenFn
    fetchDiscordMessages*: FetchDiscordMessagesFn
    lock: Lock
    sessions: Table[string, UserSessionState]
    localUsers: Table[string, UserRecord]
    pollingUsers: HashSet[string]
    pollingState: Table[string, PollingState]

  DiscordRecipientInfo = object
    id: string
    displayName: string
    avatarUrl: string

  PrivateChannelSyncResult = object
    syncedCount: int
    oldestFetchedDiscordId: string
    hasMore: bool
    fetchedMessages: seq[JsonNode]
    err: string

  DiscordRelationshipInfo = object
    relType: int
    nickname: string

  RelationshipVerifyMode = enum
    rvmHardSuccess
    rvmSoftSuccess
    rvmFailed

  RelationshipVerifyResult = object
    mode: RelationshipVerifyMode
    actualType: int
    err: string

proc sessionStateJson(state: UserSessionState): string
proc getSessionState(api: ProvisioningApi, mxid: string): UserSessionState
proc storeSessionState(api: ProvisioningApi, mxid: string, state: UserSessionState)
proc runtimeManagersReady(api: ProvisioningApi): bool
proc storeUser(api: ProvisioningApi, rec: UserRecord)

proc nowMs(): int64 =
  getTime().toUnix().int64 * 1000

const DiscordEpochMs = 1420070400000'i64
const DiscordTimestampContentKey = "fi.bee.discord_ts_ms"

proc isUnauthorizedDiscordError(status: int, err: string): bool =
  if status == 401:
    return true
  let lower = err.toLowerAscii()
  lower.contains("401") or lower.contains("unauthorized") or lower.contains("invalid token")

proc nextPollingDelayMs(stableCycles: int): int =
  if stableCycles < 2:
    return 5000
  if stableCycles < 6:
    return 15000
  60000

proc privateChannelSnapshot(channels: JsonNode): string =
  if channels.isNil or channels.kind != JArray:
    return ""
  var rows: seq[string] = @[]
  for channel in channels.getElems():
    if channel.kind != JObject:
      continue
    let channelId = channel{"id"}.getStr("")
    if channelId.len == 0:
      continue
    let channelType = channel{"type"}.getInt(0)
    if channelType notin [1, 3]:
      continue
    var recipientIds: seq[string] = @[]
    if channel.hasKey("recipients") and channel["recipients"].kind == JArray:
      for recipient in channel["recipients"]:
        if recipient.kind != JObject:
          continue
        let recipientId = recipient{"id"}.getStr("")
        if recipientId.len > 0:
          recipientIds.add(recipientId)
    recipientIds.sort(system.cmp[string])
    rows.add(
      channelId & "|" &
      $channelType & "|" &
      channel{"last_message_id"}.getStr("") & "|" &
      recipientIds.join(",")
    )
  rows.sort(system.cmp[string])
  rows.join(";")

proc getPollingState(api: ProvisioningApi, mxid: string): PollingState =
  withLock api.lock:
    if api.pollingState.hasKey(mxid):
      return api.pollingState[mxid]
  PollingState(delayMs: 5000)

proc setPollingState(api: ProvisioningApi, mxid: string, state: PollingState) =
  withLock api.lock:
    api.pollingState[mxid] = state

proc warnPolling(api: ProvisioningApi, mxid: string, message: string) =
  if message.len == 0:
    return
  var state = api.getPollingState(mxid)
  let ts = nowMs()
  if state.lastWarn == message and (ts - state.lastWarnAtMs) < 15000:
    return
  state.lastWarn = message
  state.lastWarnAtMs = ts
  api.setPollingState(mxid, state)
  warn(message)

proc clearDiscordSessionForInvalidToken(api: ProvisioningApi, mxid: string, reason: string) =
  if not api.runtimeManagersReady():
    return
  let found = api.runtime.db.getUserByMXID(mxid)
  if not found.found:
    return
  var user = found.rec
  if user.discordToken.len == 0 and user.discordId.len == 0:
    return

  var session = api.getSessionState(mxid)
  session.connected = false
  session.lastHeartbeatAck = 0
  session.lastHeartbeatSent = 0
  session.username = ""
  session.discriminator = ""

  user.discordToken = ""
  user.discordId = ""
  user.heartbeatSessionJson = sessionStateJson(session)
  api.storeSessionState(mxid, session)
  api.storeUser(user)
  warn("[provisioning] cleared invalid Discord token for " & mxid & ": " & reason)

proc queryParam(query: string, name: string): string =
  if query.len == 0:
    return ""
  for key, val in decodeQuery(query):
    if key == name:
      return val
  ""

proc queryParamBool(query: string, name: string): bool =
  let raw = queryParam(query, name).strip().toLowerAscii()
  raw in ["1", "true", "yes", "on"]

proc readAuthToken*(headers: HttpHeaders, path: string): string =
  let wsPrefix = SecWebSocketProtocol & "-"

  var auth = headers.getOrDefault("Authorization").strip()
  if auth.len == 0 and (path.endsWith("/login") or path.endsWith("/login/qr")):
    let protocols = headers.getOrDefault("Sec-WebSocket-Protocol")
    for part in protocols.split(','):
      let candidate = part.strip()
      if candidate.startsWith(wsPrefix):
        return candidate[wsPrefix.len .. ^1].strip()
    return ""

  if auth.startsWith("Bearer "):
    if auth.len <= 7:
      return ""
    return auth[7 .. ^1].strip()
  auth

proc jsonResponse(req: Request, code: HttpCode, payload: JsonNode) {.async.} =
  let headers = newHttpHeaders({"Content-Type": "application/json"})
  await req.respond(code, $payload, headers)

proc authorized(api: ProvisioningApi, headers: HttpHeaders, path: string): bool =
  let secret = api.cfg.bridge.provisioning.sharedSecret
  if secret.len == 0 or secret == "disable":
    return false
  readAuthToken(headers, path) == secret

proc decodeBase64UrlSegment(raw: string): string =
  if raw.len == 0:
    return ""
  var normal = raw.replace('-', '+').replace('_', '/')
  case normal.len mod 4
  of 0:
    discard
  of 2:
    normal &= "=="
  of 3:
    normal &= "="
  else:
    return ""
  try:
    decode(normal)
  except CatchableError:
    ""

proc discordIdFromToken(token: string): string =
  if token.len == 0:
    return ""
  let parts = token.split('.')
  if parts.len < 1:
    return ""
  let decoded = decodeBase64UrlSegment(parts[0])
  if decoded.len == 0:
    return ""
  for ch in decoded:
    if ch < '0' or ch > '9':
      return ""
  decoded

proc verifyDiscordTokenWithRest(token: string): tuple[
  ok: bool,
  discordId: string,
  username: string,
  discriminator: string,
  err: string
] =
  if token.len == 0:
    return (false, "", "", "", "empty token")
  let me = newDiscordRestClient(token).getCurrentUser()
  if not me.ok:
    return (false, "", "", "", if me.err.len > 0: me.err else: "discord auth failed")
  if me.body.isNil or me.body.kind != JObject:
    return (false, "", "", "", "discord auth response missing user object")
  (
    true,
    me.body{"id"}.getStr(""),
    me.body{"username"}.getStr(""),
    me.body{"discriminator"}.getStr(""),
    ""
  )

proc provisioningResult(code: HttpCode, payload: JsonNode): ProvisioningResult =
  ProvisioningResult(handled: true, code: code, payload: payload)

proc sessionStateJson(state: UserSessionState): string =
  $(%*{
    "connected": state.connected,
    "last_heartbeat_ack": state.lastHeartbeatAck,
    "last_heartbeat_sent": state.lastHeartbeatSent,
    "username": state.username,
    "discriminator": state.discriminator
  })

proc mapFailureToErrcode(kind: RemoteAuthFailureKind): string =
  case kind
  of rafPrepare:
    ErrCodeLoginPrepareFailed
  of rafConnection:
    ErrCodeLoginConnectionFailed
  of rafPostLogin:
    ErrCodePostLoginConnFailed
  of rafLogin, rafNone:
    ErrCodeLoginFailed

proc getOrCreateUser(api: ProvisioningApi, mxid: string): UserRecord =
  if api.runtime != nil and api.runtime.db != nil:
    let fromDb = api.runtime.db.getUserByMXID(mxid)
    if fromDb.found:
      return fromDb.rec
    let created = newUserRecord(mxid)
    api.runtime.db.insertUser(created)
    return created

  withLock api.lock:
    if api.localUsers.hasKey(mxid):
      result = api.localUsers[mxid]
    else:
      let created = newUserRecord(mxid)
      api.localUsers[mxid] = created
      result = created

proc storeUser(api: ProvisioningApi, rec: UserRecord) =
  if api.runtime != nil and api.runtime.db != nil:
    let existing = api.runtime.db.getUserByMXID(rec.mxid)
    if existing.found:
      api.runtime.db.updateUser(rec)
    else:
      api.runtime.db.insertUser(rec)
    return
  withLock api.lock:
    api.localUsers[rec.mxid] = rec

proc getSessionState(api: ProvisioningApi, mxid: string): UserSessionState =
  withLock api.lock:
    if api.sessions.hasKey(mxid):
      return api.sessions[mxid]
  UserSessionState()

proc storeSessionState(api: ProvisioningApi, mxid: string, state: UserSessionState) =
  withLock api.lock:
    api.sessions[mxid] = state

proc runtimeManagersReady(api: ProvisioningApi): bool =
  api.runtime != nil and api.runtime.db != nil

proc appserviceBotUserId(api: ProvisioningApi): string =
  let localpart =
    if api.cfg.appservice.bot.username.len > 0:
      api.cfg.appservice.bot.username
    else:
      "discordbot"
  "@" & localpart & ":" & api.cfg.homeserver.domain

proc appservicePuppetUserId(api: ProvisioningApi, discordId: string): string =
  if discordId.len == 0:
    return ""
  "@" & api.cfg.bridge.formatUsername(discordId) & ":" & api.cfg.homeserver.domain

proc matrixClientRequestAsUser(
    api: ProvisioningApi,
    actingUser: string,
    httpMethod: HttpMethod,
    path: string,
    payload: JsonNode = newJNull()
): tuple[ok: bool, status: int, body: JsonNode, raw: string, err: string] {.gcsafe.} =
  let asToken = api.cfg.appservice.asToken.strip()
  if asToken.len == 0:
    return (false, 0, newJNull(), "", "appservice.as_token is empty")
  let hs = api.cfg.homeserver.address.strip()
  if hs.len == 0:
    return (false, 0, newJNull(), "", "homeserver.address is empty")
  if actingUser.len == 0:
    return (false, 0, newJNull(), "", "acting user is empty")

  let sep = if '?' in path: "&" else: "?"
  let endpoint = hs & path & sep &
    "access_token=" & encodeUrl(asToken) &
    "&user_id=" & encodeUrl(actingUser)

  var http = newHttpClient()
  http.headers = newHttpHeaders({"Content-Type": "application/json"})
  try:
    let resp =
      if not payload.isNil and payload.kind != JNull:
        http.request(endpoint, httpMethod, body = $payload)
      else:
        http.request(endpoint, httpMethod)
    let raw = resp.body
    var parsed = newJNull()
    if raw.len > 0:
      try:
        parsed = parseJson(raw)
      except CatchableError:
        discard
    if resp.code.is2xx:
      return (true, int(resp.code), parsed, raw, "")
    let err =
      if parsed.kind == JObject:
        let msg = parsed{"error"}.getStr("")
        if msg.len > 0: msg else: raw
      else:
        raw
    (false, int(resp.code), parsed, raw, err)
  except CatchableError as e:
    (false, 0, newJNull(), "", e.msg)

proc matrixErrCode(resp: tuple[ok: bool, status: int, body: JsonNode, raw: string, err: string]): string =
  if resp.body.isNil or resp.body.kind != JObject:
    return ""
  resp.body{"errcode"}.getStr("").toUpperAscii()

proc matrixEnsureRegistered(api: ProvisioningApi, userMxid: string): bool =
  if userMxid.len < 4 or userMxid[0] != '@':
    return false
  let sep = userMxid.rfind(':')
  if sep <= 1:
    return false
  let localpart = userMxid[1 ..< sep]
  let req = %*{
    "type": "m.login.application_service",
    "username": localpart
  }
  let resp = api.matrixClientRequestAsUser(
    actingUser = userMxid,
    httpMethod = HttpPost,
    path = "/_matrix/client/v3/register",
    payload = req
  )
  if resp.ok:
    return true
  if resp.matrixErrCode() == "M_USER_IN_USE":
    return true
  if resp.raw.toLowerAscii().contains("already") and resp.raw.toLowerAscii().contains("in use"):
    return true
  warn("Failed to register appservice user " & userMxid & ": " & resp.err)
  false

proc matrixSetDisplayName(api: ProvisioningApi, userMxid, displayName: string): bool =
  if userMxid.len == 0 or displayName.len == 0:
    return false
  let resp = api.matrixClientRequestAsUser(
    actingUser = userMxid,
    httpMethod = HttpPut,
    path = "/_matrix/client/v3/profile/" & encodeUrl(userMxid) & "/displayname",
    payload = %*{"displayname": displayName}
  )
  if not resp.ok:
    warn("Failed to set display name for " & userMxid & ": " & resp.err)
  resp.ok

proc matrixSetAvatar(api: ProvisioningApi, userMxid, avatarUrl: string): bool =
  if userMxid.len == 0 or avatarUrl.len == 0:
    return false
  let resp = api.matrixClientRequestAsUser(
    actingUser = userMxid,
    httpMethod = HttpPut,
    path = "/_matrix/client/v3/profile/" & encodeUrl(userMxid) & "/avatar_url",
    payload = %*{"avatar_url": avatarUrl}
  )
  if not resp.ok:
    warn("Failed to set avatar for " & userMxid & ": " & resp.err)
  resp.ok

proc matrixInviteUser(api: ProvisioningApi, roomId, targetUserMxid: string): bool =
  if roomId.len == 0 or targetUserMxid.len == 0:
    return false
  let botUser = api.appserviceBotUserId()
  let resp = api.matrixClientRequestAsUser(
    actingUser = botUser,
    httpMethod = HttpPost,
    path = "/_matrix/client/v3/rooms/" & encodeUrl(roomId) & "/invite",
    payload = %*{"user_id": targetUserMxid}
  )
  if resp.ok:
    return true
  let rawLower = resp.raw.toLowerAscii()
  if "already" in rawLower and ("join" in rawLower or "invite" in rawLower):
    return true
  warn("Failed to invite " & targetUserMxid & " to " & roomId & ": " & resp.err)
  false

proc matrixJoinRoom(api: ProvisioningApi, roomId, userMxid: string): bool =
  if roomId.len == 0 or userMxid.len == 0:
    return false
  let resp = api.matrixClientRequestAsUser(
    actingUser = userMxid,
    httpMethod = HttpPost,
    path = "/_matrix/client/v3/join/" & encodeUrl(roomId),
    payload = %*{}
  )
  if resp.ok:
    return true
  let rawLower = resp.raw.toLowerAscii()
  if "already" in rawLower and "join" in rawLower:
    return true
  warn("Failed to join room " & roomId & " as " & userMxid & ": " & resp.err)
  false

proc matrixSetRoomNameAsBot(api: ProvisioningApi, roomId, roomName: string): bool =
  if roomId.len == 0 or roomName.len == 0:
    return false
  let botUser = api.appserviceBotUserId()
  let resp = api.matrixClientRequestAsUser(
    actingUser = botUser,
    httpMethod = HttpPut,
    path = "/_matrix/client/v3/rooms/" & encodeUrl(roomId) & "/state/m.room.name",
    payload = %*{"name": roomName}
  )
  if not resp.ok:
    warn("Failed to set room name for " & roomId & ": " & resp.err)
  resp.ok

proc matrixSetRoomAvatarAsBot(api: ProvisioningApi, roomId, avatarUrl: string): bool =
  if roomId.len == 0 or avatarUrl.len == 0:
    return false
  let botUser = api.appserviceBotUserId()
  let resp = api.matrixClientRequestAsUser(
    actingUser = botUser,
    httpMethod = HttpPut,
    path = "/_matrix/client/v3/rooms/" & encodeUrl(roomId) & "/state/m.room.avatar",
    payload = %*{"url": avatarUrl}
  )
  if not resp.ok:
    warn("Failed to set room avatar for " & roomId & ": " & resp.err)
  resp.ok

proc matrixRoomMissingForBot(api: ProvisioningApi, roomId: string): bool =
  if roomId.len == 0:
    return true
  let botUser = api.appserviceBotUserId()
  let resp = api.matrixClientRequestAsUser(
    actingUser = botUser,
    httpMethod = HttpGet,
    path = "/_matrix/client/v3/rooms/" & encodeUrl(roomId) & "/state"
  )
  if resp.ok:
    return false
  if resp.status == 404:
    return true
  let errCode = resp.matrixErrCode()
  if errCode == "M_NOT_FOUND":
    return true
  let lowerErr = resp.err.toLowerAscii()
  if "not found" in lowerErr:
    return true
  false

proc matrixSendRoomEventAsUser(
    api: ProvisioningApi,
    roomId, senderMxid, eventType, txnId: string,
    content: JsonNode,
    timestampMs: int64 = 0
): tuple[ok: bool, eventId: string, err: string] {.gcsafe.}

proc matrixSendRoomMessageAsUser(
    api: ProvisioningApi,
    roomId, senderMxid, txnId, body: string,
    timestampMs: int64 = 0
): tuple[ok: bool, eventId: string, err: string] {.gcsafe.} =
  if roomId.len == 0 or senderMxid.len == 0 or txnId.len == 0 or body.len == 0:
    return (false, "", "invalid matrix message send args")
  var messageContent = %*{
    "msgtype": "m.text",
    "body": body
  }
  if timestampMs > 0:
    messageContent[DiscordTimestampContentKey] = %timestampMs
  api.matrixSendRoomEventAsUser(
    roomId = roomId,
    senderMxid = senderMxid,
    eventType = "m.room.message",
    txnId = txnId,
    content = messageContent,
    timestampMs = timestampMs
  )

proc matrixSendRoomEventAsUser(
    api: ProvisioningApi,
    roomId, senderMxid, eventType, txnId: string,
    content: JsonNode,
    timestampMs: int64 = 0
): tuple[ok: bool, eventId: string, err: string] {.gcsafe.} =
  if roomId.len == 0 or senderMxid.len == 0 or eventType.len == 0 or txnId.len == 0 or content.kind != JObject:
    return (false, "", "invalid matrix event send args")
  var sendPath = "/_matrix/client/v3/rooms/" & encodeUrl(roomId) &
    "/send/" & encodeUrl(eventType) & "/" & encodeUrl(txnId)
  if timestampMs > 0:
    sendPath &= "?ts=" & encodeUrl($timestampMs)
  let resp = api.matrixClientRequestAsUser(
    actingUser = senderMxid,
    httpMethod = HttpPut,
    path = sendPath,
    payload = content
  )
  if not resp.ok:
    return (false, "", resp.err)
  let eventId = resp.body{"event_id"}.getStr("")
  if eventId.len == 0:
    return (false, "", "message send response missing event_id")
  (true, eventId, "")

proc attachmentMsgType(contentType, fileName: string): string =
  let ct = contentType.toLowerAscii().strip()
  if ct.startsWith("image/"):
    return "m.image"
  if ct.startsWith("video/"):
    return "m.video"
  if ct.startsWith("audio/"):
    return "m.audio"
  let lowerName = fileName.toLowerAscii()
  if lowerName.endsWith(".png") or lowerName.endsWith(".jpg") or lowerName.endsWith(".jpeg") or
      lowerName.endsWith(".gif") or lowerName.endsWith(".webp") or lowerName.endsWith(".bmp") or
      lowerName.endsWith(".heic") or lowerName.endsWith(".heif"):
    return "m.image"
  if lowerName.endsWith(".mp4") or lowerName.endsWith(".mov") or lowerName.endsWith(".webm") or
      lowerName.endsWith(".mkv"):
    return "m.video"
  if lowerName.endsWith(".mp3") or lowerName.endsWith(".m4a") or lowerName.endsWith(".aac") or
      lowerName.endsWith(".wav") or lowerName.endsWith(".ogg"):
    return "m.audio"
  "m.file"

proc discordMessageAttachments(msg: JsonNode): seq[JsonNode] =
  result = @[]
  if msg.isNil or msg.kind != JObject:
    return
  if not msg.hasKey("attachments") or msg["attachments"].kind != JArray:
    return
  for att in msg["attachments"]:
    if att.kind == JObject:
      result.add(att)

proc buildMatrixAttachmentContent(att: JsonNode, timestampMs: int64 = 0): JsonNode =
  if att.isNil or att.kind != JObject:
    return newJNull()
  let fileName = att{"filename"}.getStr("Attachment")
  let url = att{"url"}.getStr("").strip()
  let proxyUrl = att{"proxy_url"}.getStr("").strip()
  let contentType = att{"content_type"}.getStr("")
  let mediaUrl = if url.len > 0: url else: proxyUrl
  if mediaUrl.len == 0:
    return newJNull()
  let msgType = attachmentMsgType(contentType, fileName)
  var payload = %*{
    "msgtype": msgType,
    "body": fileName,
    "url": mediaUrl
  }
  if timestampMs > 0:
    payload[DiscordTimestampContentKey] = %timestampMs
  if att.hasKey("size"):
    if not payload.hasKey("info") or payload["info"].kind != JObject:
      payload["info"] = newJObject()
    payload["info"]["size"] = %att{"size"}.getInt(0)
  payload

proc matrixCreateRoomAsBot(
    api: ProvisioningApi,
    roomReq: JsonNode
): tuple[ok: bool, roomId: string, err: string] =
  let asToken = api.cfg.appservice.asToken.strip()
  if asToken.len == 0:
    return (false, "", "appservice.as_token is empty")
  let hs = api.cfg.homeserver.address.strip()
  if hs.len == 0:
    return (false, "", "homeserver.address is empty")

  let botUser = api.appserviceBotUserId()
  let endpoint = hs & "/_matrix/client/v3/createRoom?access_token=" & encodeUrl(asToken) &
    "&user_id=" & encodeUrl(botUser)

  var http = newHttpClient()
  http.headers = newHttpHeaders({"Content-Type": "application/json"})
  try:
    let resp = http.request(endpoint, HttpPost, body = $roomReq)
    if not resp.code.is2xx:
      return (false, "", "createRoom failed: " & $resp.code & " " & resp.body)
    let body = resp.body
    if body.len == 0:
      return (false, "", "createRoom returned empty body")
    let parsed = parseJson(body)
    let roomId = parsed{"room_id"}.getStr("")
    if roomId.len == 0:
      return (false, "", "createRoom response missing room_id")
    (true, roomId, "")
  except CatchableError as e:
    (false, "", "createRoom request failed: " & e.msg)

proc channelTypeName(channelType: int): string =
  case channelType
  of 1:
    "dm"
  of 3:
    "group_dm"
  else:
    ""

proc discordAvatarUrl(userId, avatarHash: string): string =
  if userId.len == 0:
    return ""
  if avatarHash.len > 0:
    let ext = if avatarHash.startsWith("a_"): "gif" else: "png"
    return "https://cdn.discordapp.com/avatars/" & userId & "/" & avatarHash & "." & ext & "?size=128"
  "https://cdn.discordapp.com/embed/avatars/0.png"

proc discordGroupIconUrl(channelId, iconHash: string): string =
  if channelId.len == 0 or iconHash.len == 0:
    return ""
  let ext = if iconHash.startsWith("a_"): "gif" else: "png"
  "https://cdn.discordapp.com/channel-icons/" & channelId & "/" & iconHash & "." & ext & "?size=128"

proc isGenericPrivateChannelName(name: string): bool =
  let lowered = name.strip().toLowerAscii()
  lowered == "discord group dm" or lowered == "discord dm" or lowered.len == 0

proc discordDisplayName(userObj: JsonNode): string =
  if userObj.isNil or userObj.kind != JObject:
    return ""
  let globalName = userObj{"global_name"}.getStr("").strip()
  if globalName.len > 0:
    return globalName
  let username = userObj{"username"}.getStr("").strip()
  if username.len > 0:
    return username
  let displayName = userObj{"display_name"}.getStr("").strip()
  if displayName.len > 0:
    return displayName
  ""

proc resolvePrimaryRecipient(channel: JsonNode, selfDiscordId: string): DiscordRecipientInfo =
  if not channel.hasKey("recipients") or channel["recipients"].kind != JArray:
    return DiscordRecipientInfo()

  var fallback = DiscordRecipientInfo()
  for recipient in channel["recipients"]:
    if recipient.kind != JObject:
      continue
    let id = recipient{"id"}.getStr("")
    if id.len == 0:
      continue
    let displayName = discordDisplayName(recipient)
    let info = DiscordRecipientInfo(
      id: id,
      displayName: if displayName.len > 0: displayName else: id,
      avatarUrl: discordAvatarUrl(id, recipient{"avatar"}.getStr(""))
    )
    if fallback.id.len == 0:
      fallback = info
    if selfDiscordId.len > 0 and id == selfDiscordId:
      continue
    return info
  fallback

proc resolvePrivateChannelName(channel: JsonNode, selfDiscordId: string): string =
  let channelType = channel{"type"}.getInt(0)
  let explicitName = channel{"name"}.getStr("").strip()
  if explicitName.len > 0:
    return explicitName
  let primaryRecipient = resolvePrimaryRecipient(channel, selfDiscordId)
  if channelType == 1 and primaryRecipient.displayName.len > 0:
    return primaryRecipient.displayName
  if channel.hasKey("recipients") and channel["recipients"].kind == JArray:
    var names: seq[string] = @[]
    for recipient in channel["recipients"]:
      if recipient.kind != JObject:
        continue
      let id = recipient{"id"}.getStr("")
      if selfDiscordId.len > 0 and id == selfDiscordId:
        continue
      let n = recipient{"global_name"}.getStr("").strip()
      if n.len > 0:
        names.add(n)
        continue
      let u = recipient{"username"}.getStr("").strip()
      if u.len > 0:
        names.add(u)
    if names.len > 0:
      return names.join(", ")
  if channelType == 3:
    "Discord Group DM"
  else:
    "Discord DM"

proc resolvePrivateChannelNameWithLookup(
    channel: JsonNode,
    selfDiscordId: string,
    rest: DiscordRestClient,
    displayNameCache: var Table[string, string]
): string =
  result = resolvePrivateChannelName(channel, selfDiscordId)
  let channelType = channel{"type"}.getInt(0)
  if channelType != 3 or result != "Discord Group DM":
    return
  if rest.isNil:
    return
  var sourceChannel = channel
  var recipientsMissing =
    (not sourceChannel.hasKey("recipients")) or
    sourceChannel["recipients"].kind != JArray or
    sourceChannel["recipients"].len == 0
  if recipientsMissing:
    let channelId = channel{"id"}.getStr("")
    if channelId.len > 0:
      let fullChannel = rest.getChannel(channelId)
      if fullChannel.ok and fullChannel.body.kind == JObject:
        sourceChannel = fullChannel.body
        result = resolvePrivateChannelName(sourceChannel, selfDiscordId)
        if result != "Discord Group DM":
          return
        recipientsMissing =
          (not sourceChannel.hasKey("recipients")) or
          sourceChannel["recipients"].kind != JArray or
          sourceChannel["recipients"].len == 0
  if recipientsMissing:
    return

  var names: seq[string] = @[]
  var seenIds = initHashSet[string]()
  for recipient in sourceChannel["recipients"]:
    if recipient.kind != JObject:
      continue
    let id = recipient{"id"}.getStr("")
    if id.len == 0:
      continue
    if selfDiscordId.len > 0 and id == selfDiscordId:
      continue
    if id in seenIds:
      continue
    seenIds.incl(id)

    let inlineName = discordDisplayName(recipient)
    if inlineName.len > 0:
      displayNameCache[id] = inlineName
      names.add(inlineName)
      continue

    var lookedUp = displayNameCache.getOrDefault(id, "")
    if lookedUp.len == 0:
      let userResp = rest.getUser(id)
      if userResp.ok and userResp.body.kind == JObject:
        lookedUp = discordDisplayName(userResp.body)
      displayNameCache[id] = lookedUp
    if lookedUp.len > 0:
      names.add(lookedUp)

  if names.len > 0:
    result = names.join(", ")

proc resolveOtherUserId(channel: JsonNode, selfDiscordId: string): string =
  resolvePrimaryRecipient(channel, selfDiscordId).id

proc relationshipTypeLabel(relType: int): string =
  case relType
  of 1:
    "friend"
  of 2:
    "blocked"
  of 0:
    "none"
  else:
    "type-" & $relType

proc relationshipVerifyModeLabel(mode: RelationshipVerifyMode): string =
  case mode
  of rvmHardSuccess:
    "hard_success"
  of rvmSoftSuccess:
    "soft_success"
  of rvmFailed:
    "failed"

proc parseDiscordRelationshipMap(payload: JsonNode): Table[string, DiscordRelationshipInfo] =
  result = initTable[string, DiscordRelationshipInfo]()
  if payload.isNil or payload.kind != JArray:
    return
  for node in payload:
    if node.kind != JObject:
      continue
    let userId = node{"id"}.getStr("").strip()
    if userId.len == 0:
      continue
    result[userId] = DiscordRelationshipInfo(
      relType: node{"type"}.getInt(0),
      nickname: node{"nickname"}.getStr("").strip()
    )

proc fetchDiscordRelationshipMap(
    api: ProvisioningApi,
    user: UserRecord,
    rest: DiscordRestClient,
    source: string
): tuple[ok: bool, status: int, relationships: Table[string, DiscordRelationshipInfo], err: string] =
  var empty = initTable[string, DiscordRelationshipInfo]()
  if user.discordToken.len == 0:
    return (false, 0, empty, "You're not connected to discord")
  let fetched = rest.getRelationships()
  if not fetched.ok:
    let detail =
      if fetched.err.len > 0:
        fetched.err
      else:
        "Discord relationships request failed"
    if isUnauthorizedDiscordError(fetched.status, detail):
      api.clearDiscordSessionForInvalidToken(user.mxid, detail)
    warn("[provisioning] relationship-sync source=" & source &
      " mxid=" & user.mxid & " status=" & $fetched.status &
      " err=" & detail)
    return (false, fetched.status, empty, detail)
  if fetched.body.isNil or fetched.body.kind != JArray:
    let err = "Discord relationships response is not an array"
    warn("[provisioning] relationship-sync source=" & source &
      " mxid=" & user.mxid & " err=" & err)
    return (false, fetched.status, empty, err)
  (true, fetched.status, parseDiscordRelationshipMap(fetched.body), "")

proc applyDiscordRelationshipMapToDmPortals(
    api: ProvisioningApi,
    relationships: Table[string, DiscordRelationshipInfo],
    source: string
) =
  if not api.runtimeManagersReady():
    return
  var updated = 0
  var friendCount = 0
  var blockedCount = 0
  var otherCount = 0
  var preservedBlockedCount = 0
  let portals = api.runtime.db.getAllPortals()
  for existing in portals:
    if existing.portalType != 1 or existing.otherUserId.len == 0:
      continue
    let hasRelationship = relationships.hasKey(existing.otherUserId)
    var relType = 0
    var nickname = ""
    if hasRelationship:
      let rel = relationships[existing.otherUserId]
      relType = rel.relType
      nickname = rel.nickname
    case relType
    of 1:
      inc friendCount
    of 2:
      inc blockedCount
    else:
      inc otherCount

    var rec = existing
    var changed = false
    let shouldBeFriend = hasRelationship and relType == 1
    if hasRelationship:
      let shouldBeBlocked = relType == 2
      if rec.friendNick != shouldBeFriend:
        rec.friendNick = shouldBeFriend
        changed = true
      if rec.blocked != shouldBeBlocked:
        rec.blocked = shouldBeBlocked
        changed = true
    else:
      # Relationship feed can omit blocked users for some auth modes.
      # Don't clear blocked state when relationship is absent.
      if rec.friendNick:
        rec.friendNick = false
        changed = true
      if rec.blocked:
        inc preservedBlockedCount
    if shouldBeFriend and nickname.len > 0 and rec.name != nickname:
      rec.name = nickname
      rec.nameSet = true
      changed = true
    if changed:
      api.runtime.db.updatePortal(rec)
      inc updated

  info("[provisioning] relationship-sync source=" & source &
    " portals_updated=" & $updated &
    " friends=" & $friendCount &
    " blocked=" & $blockedCount &
    " other=" & $otherCount &
    " blocked_preserved_absent=" & $preservedBlockedCount)

proc applyRelationshipActionIntentToDmPortals(
    api: ProvisioningApi,
    targetUserId: string,
    action: string,
    explicitFriend = false
) =
  if not api.runtimeManagersReady() or targetUserId.len == 0:
    return
  let portals = api.runtime.db.findPrivateChatsWith(targetUserId, dmType = 1)
  if portals.len == 0:
    return
  var updated = 0
  for existing in portals:
    var rec = existing
    var changed = false
    case action
    of "block":
      if rec.friendNick:
        rec.friendNick = false
        changed = true
      if not rec.blocked:
        rec.blocked = true
        changed = true
    of "unblock":
      if rec.friendNick:
        rec.friendNick = false
        changed = true
      if rec.blocked:
        rec.blocked = false
        changed = true
    of "remove-friend":
      if rec.friendNick:
        rec.friendNick = false
        changed = true
      if rec.blocked:
        rec.blocked = false
        changed = true
    of "add-friend":
      if explicitFriend:
        if not rec.friendNick:
          rec.friendNick = true
          changed = true
        if rec.blocked:
          rec.blocked = false
          changed = true
    else:
      discard
    if changed:
      api.runtime.db.updatePortal(rec)
      inc updated
  if updated > 0:
    info("[provisioning] relationship-action-local-apply action=" & action &
      " target_user_id=" & targetUserId &
      " portals_updated=" & $updated &
      " explicit_friend=" & $(if explicitFriend: 1 else: 0))

proc verifyRelationshipActionState(
    action: string,
    targetUserId: string,
    relationships: Table[string, DiscordRelationshipInfo]
): tuple[ok: bool, actualType: int, err: string] =
  let actualType =
    if targetUserId.len > 0 and relationships.hasKey(targetUserId):
      relationships[targetUserId].relType
    else:
      0
  case action
  of "block":
    if actualType == 2:
      return (true, actualType, "")
    (false, actualType, "expected blocked relationship")
  of "add-friend":
    if actualType == 1:
      return (true, actualType, "")
    (false, actualType, "expected friend relationship")
  of "unblock", "remove-friend":
    if actualType notin [1, 2]:
      return (true, actualType, "")
    (false, actualType, "expected no direct friend/block relationship")
  else:
    (true, actualType, "")

proc resolveRelationshipVerificationResult(
    action: string,
    hardVerify: tuple[ok: bool, actualType: int, err: string],
    preActionType: int,
    preActionTypeKnown: bool
): RelationshipVerifyResult =
  if hardVerify.ok:
    return RelationshipVerifyResult(mode: rvmHardSuccess, actualType: hardVerify.actualType, err: "")

  case action
  of "block":
    # Only accept friend->none as soft success.
    # If pre-state is unknown/none and post-state is none, treat as failure to
    # avoid local-only block success without remote evidence.
    if hardVerify.actualType == 0 and preActionTypeKnown and preActionType == 1:
      return RelationshipVerifyResult(
        mode: rvmSoftSuccess,
        actualType: hardVerify.actualType,
        err: "friend-to-none fallback accepted"
      )
  of "add-friend":
    # Friend requests may not materialize immediately as type=1 in /relationships.
    # Treat this as request-sent when the action itself succeeded.
    if hardVerify.actualType != 2:
      return RelationshipVerifyResult(
        mode: rvmSoftSuccess,
        actualType: hardVerify.actualType,
        err: "friend state opaque after request"
      )
  else:
    discard

  RelationshipVerifyResult(mode: rvmFailed, actualType: hardVerify.actualType, err: hardVerify.err)

proc relationshipExpectedLabel(action: string): string =
  case action
  of "block":
    "blocked"
  of "add-friend":
    "friend"
  of "unblock", "remove-friend":
    "none"
  else:
    "unknown"

proc compareDiscordSnowflakeIds(id1, id2: string): int =
  if id1 == id2:
    return 0
  if id1.len < id2.len:
    return -1
  if id2.len < id1.len:
    return 1
  if id1 < id2:
    return -1
  1

proc sortDiscordMessagesAscending(messages: var seq[JsonNode]) =
  messages.sort(proc(a, b: JsonNode): int =
    compareDiscordSnowflakeIds(a{"id"}.getStr(""), b{"id"}.getStr(""))
  )

proc messageBodyForMatrix(msg: JsonNode): string =
  if msg.isNil or msg.kind != JObject:
    return ""
  let content = msg{"content"}.getStr("").strip()
  if content.len > 0:
    return content
  let attachmentCount =
    if msg.hasKey("attachments") and msg["attachments"].kind == JArray:
      msg["attachments"].len
    else:
      0
  if attachmentCount > 0:
    return if attachmentCount == 1: "[Attachment]" else: "[Attachments]"
  let embedCount =
    if msg.hasKey("embeds") and msg["embeds"].kind == JArray:
      msg["embeds"].len
    else:
      0
  if embedCount > 0:
    return "[Embed]"
  ""

proc newestDiscordMessageId(messages: openArray[JsonNode]): string =
  result = ""
  for msg in messages:
    let mid = msg{"id"}.getStr("")
    if mid.len == 0:
      continue
    if result.len == 0 or compareDiscordSnowflakeIds(mid, result) > 0:
      result = mid

proc discordSnowflakeTimestampMs(messageId: string): int64 =
  if messageId.len == 0:
    return 0
  try:
    let raw = parseBiggestInt(messageId)
    if raw <= 0:
      return 0
    result = (raw.int64 shr 22) + DiscordEpochMs
  except CatchableError:
    result = 0

proc syncPrivateChannelMessagesPage(
    api: ProvisioningApi,
    user: UserRecord,
    rec: PortalRecord,
    limit: int,
    beforeCursor: string = "",
    onlyNew = false
): PrivateChannelSyncResult {.gcsafe.} =
  result = PrivateChannelSyncResult(
    syncedCount: 0,
    oldestFetchedDiscordId: "",
    hasMore: false,
    fetchedMessages: @[],
    err: ""
  )
  if api.runtime == nil or api.runtime.db == nil:
    return
  if user.discordToken.len == 0 or rec.key.channelId.len == 0 or rec.mxid.len == 0:
    return

  let rest = newDiscordRestClient(user.discordToken)
  var collected: seq[JsonNode] = @[]
  let maxMessages = max(1, limit)
  var lastFetchCount = 0
  var lastFetchLimit = 0

  let lastMapped = api.runtime.db.getLastMessage(rec.key)
  if onlyNew and lastMapped.found and lastMapped.rec.discordId.len > 0:
    var after = lastMapped.rec.discordId
    while collected.len < maxMessages:
      let remaining = maxMessages - collected.len
      let limit = min(100, remaining)
      let fetched =
        if api.fetchDiscordMessages != nil:
          api.fetchDiscordMessages(user.discordToken, rec.key.channelId, limit, "", after)
        else:
          rest.getChannelMessages(rec.key.channelId, limit = limit, after = after)
      if not fetched.ok:
        result.err = "Failed to fetch Discord messages for channel " & rec.key.channelId & ": " & fetched.err
        if collected.len == 0:
          return
        break
      if fetched.body.isNil or fetched.body.kind != JArray:
        result.err = "Discord messages response is not an array for channel " & rec.key.channelId
        if collected.len == 0:
          return
        break
      if fetched.body.len == 0:
        break
      for item in fetched.body:
        if item.kind == JObject:
          collected.add(item)
      lastFetchCount = fetched.body.len
      lastFetchLimit = limit
      let newest = newestDiscordMessageId(fetched.body.elems)
      if fetched.body.len < limit or newest.len == 0 or newest == after:
        break
      after = newest
  else:
    var before = beforeCursor.strip()
    while collected.len < maxMessages:
      let remaining = maxMessages - collected.len
      let limit = min(100, remaining)
      let fetched =
        if api.fetchDiscordMessages != nil:
          api.fetchDiscordMessages(user.discordToken, rec.key.channelId, limit, before, "")
        else:
          rest.getChannelMessages(rec.key.channelId, limit = limit, before = before)
      if not fetched.ok:
        result.err = "Failed to fetch Discord messages for channel " & rec.key.channelId & ": " & fetched.err
        if collected.len == 0:
          return
        break
      if fetched.body.isNil or fetched.body.kind != JArray:
        result.err = "Discord messages response is not an array for channel " & rec.key.channelId
        if collected.len == 0:
          return
        break
      if fetched.body.len == 0:
        break

      for item in fetched.body:
        if item.kind == JObject:
          collected.add(item)
      lastFetchCount = fetched.body.len
      lastFetchLimit = limit
      let oldest = fetched.body[^1]{"id"}.getStr("")
      if fetched.body.len < limit or oldest.len == 0 or oldest == before:
        break
      before = oldest
      # Explicit cursor pagination should process exactly one page per request.
      if beforeCursor.len > 0:
        break

  if collected.len == 0:
    return
  result.fetchedMessages = collected
  if onlyNew:
    result.hasMore = false
  else:
    result.hasMore = lastFetchLimit > 0 and lastFetchCount >= lastFetchLimit
  sortDiscordMessagesAscending(collected)

  var synced = 0
  var preparedSenders = initHashSet[string]()
  for msg in collected:
    let discordMsgId = msg{"id"}.getStr("")
    if discordMsgId.len == 0:
      continue
    if result.oldestFetchedDiscordId.len == 0 or compareDiscordSnowflakeIds(discordMsgId, result.oldestFetchedDiscordId) < 0:
      result.oldestFetchedDiscordId = discordMsgId
    if api.runtime.db.getMessagesByDiscordID(rec.key, discordMsgId).len > 0:
      continue

    let author = msg{"author"}
    if author.isNil or author.kind != JObject:
      continue
    let senderDiscordId = author{"id"}.getStr("")
    if senderDiscordId.len == 0:
      continue
    let senderMxid = api.appservicePuppetUserId(senderDiscordId)
    if senderMxid.len == 0:
      continue

    if senderDiscordId notin preparedSenders:
      if api.matrixEnsureRegistered(senderMxid):
        let displayName =
          block:
            let n = author{"global_name"}.getStr("").strip()
            if n.len > 0:
              n
            else:
              author{"username"}.getStr("").strip()
        if displayName.len > 0:
          discard api.matrixSetDisplayName(senderMxid, displayName)
        let avatar = discordAvatarUrl(senderDiscordId, author{"avatar"}.getStr(""))
        if avatar.len > 0:
          discard api.matrixSetAvatar(senderMxid, avatar)
        discard api.matrixInviteUser(rec.mxid, senderMxid)
        discard api.matrixJoinRoom(rec.mxid, senderMxid)
      preparedSenders.incl(senderDiscordId)

    let textBody = msg{"content"}.getStr("").strip()
    let attachments = discordMessageAttachments(msg)
    let eventTimestampMs =
      block:
        let ts = discordSnowflakeTimestampMs(discordMsgId)
        if ts > 0: ts else: nowMs()
    var firstEventId = ""
    var firstAttachmentId = ""
    var sentAny = false

    if textBody.len > 0:
      let txnId = "discord_dm_" & rec.key.channelId & "_" & discordMsgId & "_text"
      let sentText = api.matrixSendRoomMessageAsUser(rec.mxid, senderMxid, txnId, textBody, timestampMs = eventTimestampMs)
      if sentText.ok:
        sentAny = true
        firstEventId = sentText.eventId
      else:
        warn("Failed to bridge Discord text " & discordMsgId & " into room " & rec.mxid & ": " & sentText.err)

    var attIdx = 0
    for att in attachments:
      let content = buildMatrixAttachmentContent(att, eventTimestampMs)
      if content.kind != JObject:
        continue
      let attachmentId = att{"id"}.getStr($attIdx)
      let txnId = "discord_dm_" & rec.key.channelId & "_" & discordMsgId & "_att_" & $attIdx
      inc attIdx
      let sentAtt = api.matrixSendRoomEventAsUser(
        roomId = rec.mxid,
        senderMxid = senderMxid,
        eventType = "m.room.message",
        txnId = txnId,
        content = content,
        timestampMs = eventTimestampMs
      )
      if not sentAtt.ok:
        warn("Failed to bridge Discord attachment " & discordMsgId & " into room " & rec.mxid & ": " & sentAtt.err)
        continue
      sentAny = true
      if firstEventId.len == 0:
        firstEventId = sentAtt.eventId
      if firstAttachmentId.len == 0:
        firstAttachmentId = attachmentId

    if not sentAny:
      let fallbackBody = messageBodyForMatrix(msg)
      if fallbackBody.len == 0:
        continue
      let txnId = "discord_dm_" & rec.key.channelId & "_" & discordMsgId & "_fallback"
      let sentFallback = api.matrixSendRoomMessageAsUser(rec.mxid, senderMxid, txnId, fallbackBody, timestampMs = eventTimestampMs)
      if not sentFallback.ok:
        warn("Failed to bridge Discord message " & discordMsgId & " into room " & rec.mxid & ": " & sentFallback.err)
        continue
      sentAny = true
      firstEventId = sentFallback.eventId

    if not sentAny or firstEventId.len == 0:
      continue

    try:
      api.runtime.db.insertMessage(MessageRecord(
        discordId: discordMsgId,
        attachmentId: firstAttachmentId,
        channelId: rec.key.channelId,
        channelReceiver: rec.key.receiver,
        senderId: senderDiscordId,
        timestampMs: eventTimestampMs,
        editTimestampNs: 0,
        threadId: "",
        mxid: firstEventId,
        senderMxid: senderMxid
      ))
      inc synced
    except CatchableError as e:
      warn("Failed to store Discord message mapping " & discordMsgId & ": " & e.msg)
  result.syncedCount = synced

proc fallbackEventIdForDiscordMessage(
    api: ProvisioningApi,
    rec: PortalRecord,
    discordMsgId: string,
    fallbackSuffix: string
): string {.gcsafe.} =
  let mapped = api.runtime.db.getFirstMessageByDiscordID(rec.key, discordMsgId)
  if mapped.found and mapped.rec.mxid.len > 0:
    return mapped.rec.mxid
  "$discord_fallback_" & discordMsgId & "_" & fallbackSuffix

proc buildSyntheticFallbackEventsFromDiscordMessages(
    api: ProvisioningApi,
    rec: PortalRecord,
    messages: seq[JsonNode],
    limit: int
): seq[JsonNode] {.gcsafe.} =
  result = @[]
  if messages.len == 0:
    return
  let capped = max(1, min(200, limit))
  for msg in messages:
    if msg.kind != JObject:
      continue
    let discordMsgId = msg{"id"}.getStr("").strip()
    if discordMsgId.len == 0:
      continue
    let authorId = msg{"author"}{"id"}.getStr("").strip()
    if authorId.len == 0:
      continue
    let senderMxid = api.appservicePuppetUserId(authorId)
    if senderMxid.len == 0:
      continue

    let tsMs =
      block:
        let fromSnowflake = discordSnowflakeTimestampMs(discordMsgId)
        if fromSnowflake > 0: fromSnowflake else: nowMs()

    var firstEventUsed = false
    let textBody = msg{"content"}.getStr("").strip()
    if textBody.len > 0 and result.len < capped:
      let eventId =
        if not firstEventUsed:
          firstEventUsed = true
          api.fallbackEventIdForDiscordMessage(rec, discordMsgId, "text")
        else:
          "$discord_fallback_" & discordMsgId & "_text"
      result.add(%*{
        "event_id": eventId,
        "type": "m.room.message",
        "room_id": rec.mxid,
        "sender": senderMxid,
        "origin_server_ts": tsMs,
        "content": {
          "msgtype": "m.text",
          "body": textBody,
          DiscordTimestampContentKey: tsMs
        }
      })

    var attIdx = 0
    for att in discordMessageAttachments(msg):
      if result.len >= capped:
        break
      let content = buildMatrixAttachmentContent(att, tsMs)
      if content.kind != JObject:
        continue
      let attKey = att{"id"}.getStr($attIdx)
      let eventId =
        if not firstEventUsed:
          firstEventUsed = true
          api.fallbackEventIdForDiscordMessage(rec, discordMsgId, "att0")
        else:
          "$discord_fallback_" & discordMsgId & "_att_" & $attIdx & "_" & attKey
      result.add(%*{
        "event_id": eventId,
        "type": "m.room.message",
        "room_id": rec.mxid,
        "sender": senderMxid,
        "origin_server_ts": tsMs,
        "content": content
      })
      inc attIdx

    if firstEventUsed:
      continue
    let fallbackBody = messageBodyForMatrix(msg)
    if fallbackBody.len == 0 or result.len >= capped:
      continue
    result.add(%*{
      "event_id": api.fallbackEventIdForDiscordMessage(rec, discordMsgId, "fallback"),
      "type": "m.room.message",
      "room_id": rec.mxid,
      "sender": senderMxid,
      "origin_server_ts": tsMs,
      "content": {
        "msgtype": "m.text",
        "body": fallbackBody,
        DiscordTimestampContentKey: tsMs
      }
    })

proc fetchLatestDiscordMessagesForFallback(
    api: ProvisioningApi,
    user: UserRecord,
    channelId: string,
    limit: int
): seq[JsonNode] {.gcsafe.} =
  result = @[]
  if user.discordToken.len == 0 or channelId.len == 0:
    return
  let capped = max(1, min(100, limit))
  let fetched =
    if api.fetchDiscordMessages != nil:
      api.fetchDiscordMessages(user.discordToken, channelId, capped, "", "")
    else:
      let rest = newDiscordRestClient(user.discordToken)
      rest.getChannelMessages(channelId, limit = capped)
  if not fetched.ok or fetched.body.isNil or fetched.body.kind != JArray:
    return
  for item in fetched.body:
    if item.kind == JObject:
      result.add(item)
  if result.len > 1:
    sortDiscordMessagesAscending(result)

proc syncPrivateChannelMessages(
    api: ProvisioningApi,
    user: UserRecord,
    rec: PortalRecord,
    onlyNew = false
): int =
  let page = api.syncPrivateChannelMessagesPage(
    user = user,
    rec = rec,
    limit = 300,
    beforeCursor = "",
    onlyNew = onlyNew
  )
  if page.err.len > 0:
    warn(page.err)
  page.syncedCount

proc bridgeInfoForPrivateChannel(
    api: ProvisioningApi,
    channelId, name: string,
    channelType: int
): tuple[stateKey: string, content: JsonNode] =
  var bridgeInfo = %*{
    "bridgebot": api.appserviceBotUserId(),
    "creator": api.appserviceBotUserId(),
    "protocol": {
      "id": "discordgo",
      "displayname": "Discord",
      "external_url": "https://discord.com/"
    },
    "channel": {
      "id": channelId,
      "displayname": name,
      "external_url": "https://discord.com/channels/@me/" & channelId
    }
  }
  let roomType = channelTypeName(channelType)
  if roomType.len > 0:
    let roomTypeLegacy = if roomType == "group_dm": "dm" else: roomType
    bridgeInfo["com.beeper.room_type"] = %roomTypeLegacy
    bridgeInfo["com.beeper.room_type.v2"] = %roomType
  result = ("fi.mau.discord://discord/dm/" & channelId, bridgeInfo)

proc bootstrapPrivateChannelIdentity(
    api: ProvisioningApi,
    roomId: string,
    displayName: string,
    recipient: DiscordRecipientInfo
) =
  if roomId.len == 0:
    return
  if displayName.len > 0:
    discard api.matrixSetRoomNameAsBot(roomId, displayName)
  if recipient.avatarUrl.len > 0:
    discard api.matrixSetRoomAvatarAsBot(roomId, recipient.avatarUrl)

  if recipient.id.len == 0:
    return
  let ghostMxid = api.appservicePuppetUserId(recipient.id)
  if ghostMxid.len == 0:
    return
  if not api.matrixEnsureRegistered(ghostMxid):
    return
  if displayName.len > 0:
    discard api.matrixSetDisplayName(ghostMxid, displayName)
  if recipient.avatarUrl.len > 0:
    discard api.matrixSetAvatar(ghostMxid, recipient.avatarUrl)
  discard api.matrixInviteUser(roomId, ghostMxid)
  discard api.matrixJoinRoom(roomId, ghostMxid)

proc bootstrapPrivateChannels(
    api: ProvisioningApi,
    user: UserRecord,
    logLinkedOnly = true,
    prefetchedChannels: JsonNode = nil
) =
  if not api.runtimeManagersReady() or user.discordToken.len == 0:
    return

  info("[provisioning] bootstrapPrivateChannels start mxid=" & user.mxid)

  var channels = prefetchedChannels
  if channels.isNil:
    let rest = newDiscordRestClient(user.discordToken)
    let fetched = rest.getPrivateChannels()
    if not fetched.ok:
      warn("Failed to fetch Discord private channels for " & user.mxid & ": " & fetched.err)
      return
    if fetched.body.isNil or fetched.body.kind != JArray:
      warn("Discord private channels response is not an array for " & user.mxid)
      return
    channels = fetched.body

  info("[provisioning] fetched private channels count=" & $channels.len & " mxid=" & user.mxid)

  var displayNameCache = initTable[string, string]()
  var created = 0
  var linked = 0
  var messageSynced = 0
  let rest = newDiscordRestClient(user.discordToken)
  let relationshipFetch = api.fetchDiscordRelationshipMap(user, rest, "bootstrap")
  let relationshipSyncAvailable = relationshipFetch.ok
  if not relationshipSyncAvailable and isUnauthorizedDiscordError(relationshipFetch.status, relationshipFetch.err):
    return
  let relationships = relationshipFetch.relationships
  for channel in channels:
    if channel.kind != JObject:
      continue
    let channelId = channel{"id"}.getStr("")
    if channelId.len == 0:
      continue
    let channelType = channel{"type"}.getInt(0)
    if channelType notin [1, 3]:
      continue

    info("[provisioning] syncing private channel id=" & channelId & " type=" & $channelType & " mxid=" & user.mxid)

    let key = PortalKey(channelId: channelId, receiver: "")
    let existing = api.runtime.db.getPortalByID(key)
    var rec =
      if existing.found:
        existing.rec
      else:
        newPortalRecord(key, channelType)
    if existing.found and rec.mxid.len > 0 and api.matrixRoomMissingForBot(rec.mxid):
      warn("[provisioning] stale portal room detected for channel " & channelId &
        " mxid=" & rec.mxid & ", recreating")
      rec.mxid = ""
      rec.nameSet = false
      rec.topicSet = false
      rec.avatarSet = false
    rec.portalType = channelType
    let recipient = resolvePrimaryRecipient(channel, user.discordId)
    rec.otherUserId = resolveOtherUserId(channel, user.discordId)
    var displayName = resolvePrivateChannelNameWithLookup(channel, user.discordId, rest, displayNameCache)
    if channelType == 1 and relationshipSyncAvailable and rec.otherUserId.len > 0 and relationships.hasKey(rec.otherUserId):
      let rel = relationships[rec.otherUserId]
      rec.friendNick = rel.relType == 1
      rec.blocked = rel.relType == 2
      if rec.friendNick and rel.nickname.len > 0:
        displayName = rel.nickname
    if existing.found and isGenericPrivateChannelName(displayName):
      let existingName =
        if existing.rec.plainName.len > 0:
          existing.rec.plainName
        else:
          existing.rec.name
      if not isGenericPrivateChannelName(existingName):
        displayName = existingName
    rec.plainName = displayName
    rec.name = displayName
    if channelType == 1:
      rec.avatarUrl = recipient.avatarUrl
      rec.avatarSet = false
    elif channelType == 3:
      let groupIconUrl = discordGroupIconUrl(channelId, channel{"icon"}.getStr(""))
      if groupIconUrl.len > 0:
        rec.avatarUrl = groupIconUrl
        rec.avatarSet = false

    if rec.mxid.len == 0:
      let (bridgeStateKey, bridgeInfo) = api.bridgeInfoForPrivateChannel(channelId, displayName, channelType)
      var creationContent = newJObject()
      if not api.cfg.bridge.federateRooms:
        creationContent["m.federate"] = %false
      var initialState = %*[
        {"type": "m.bridge", "state_key": bridgeStateKey, "content": bridgeInfo},
        {"type": "uk.half-shot.bridge", "state_key": bridgeStateKey, "content": bridgeInfo}
      ]
      if channelType == 1 and recipient.avatarUrl.len > 0:
        initialState.add(%*{
          "type": "m.room.avatar",
          "content": {"url": recipient.avatarUrl}
        })
      elif channelType == 3 and rec.avatarUrl.len > 0:
        initialState.add(%*{
          "type": "m.room.avatar",
          "content": {"url": rec.avatarUrl}
        })
      let roomReq = %*{
        "visibility": "private",
        "name": displayName,
        "preset": "private_chat",
        "is_direct": channelType == 1,
        "invite": [user.mxid],
        "initial_state": initialState,
        "creation_content": creationContent,
        "room_version": "11"
      }
      let createdRoom = api.matrixCreateRoomAsBot(roomReq)
      if not createdRoom.ok:
        warn("Failed to create Matrix room for Discord channel " & channelId & ": " & createdRoom.err)
        continue
      rec.mxid = createdRoom.roomId
      rec.nameSet = true
      inc created
    else:
      discard api.matrixInviteUser(rec.mxid, user.mxid)
    inc linked
    if existing.found:
      api.runtime.db.updatePortal(rec)
    else:
      api.runtime.db.insertPortal(rec)
    if channelType == 1:
      api.bootstrapPrivateChannelIdentity(rec.mxid, displayName, recipient)
    if channelType == 3:
      # Keep existing group DM rooms renamed to the latest Discord title/participants.
      let prevName = if existing.found: existing.rec.name else: ""
      if not existing.found or prevName != displayName:
        discard api.matrixSetRoomNameAsBot(rec.mxid, displayName)
      if rec.avatarUrl.len > 0:
        discard api.matrixSetRoomAvatarAsBot(rec.mxid, rec.avatarUrl)
    if channelType in [1, 3]:
      messageSynced += api.syncPrivateChannelMessages(user, rec, onlyNew = not logLinkedOnly)
    if api.runtime.db != nil:
      api.runtime.db.markUserInPortal(UserPortalRecord(
        discordId: channelId,
        userMxid: user.mxid,
        portalType: "dm",
        inSpace: false,
        timestampMs: nowMs()
      ))

  if relationshipSyncAvailable:
    api.applyDiscordRelationshipMapToDmPortals(relationships, "bootstrap")

  let shouldLog =
    if logLinkedOnly:
      created > 0 or linked > 0 or messageSynced > 0
    else:
      created > 0 or messageSynced > 0
  if shouldLog:
    info(
      "Bootstrapped Discord private channels for " & user.mxid &
      ": created=" & $created &
      " linked=" & $linked &
      " synced_messages=" & $messageSynced
    )
  info("[provisioning] bootstrapPrivateChannels done mxid=" & user.mxid)

proc startPrivateChannelPolling(api: ProvisioningApi, mxid: string)
proc runPrivateChannelPolling(api: ProvisioningApi, mxid: string): Future[void] {.async.}
proc kickImmediatePrivateChannelSync(api: ProvisioningApi, mxid: string)

proc startPrivateChannelPolling(api: ProvisioningApi, mxid: string) =
  if not api.runtimeManagersReady() or mxid.len == 0:
    return
  var shouldStart = false
  withLock api.lock:
    if mxid notin api.pollingUsers:
      api.pollingUsers.incl(mxid)
      shouldStart = true
  if shouldStart:
    api.setPollingState(mxid, PollingState(delayMs: 5000))
    asyncCheck api.runPrivateChannelPolling(mxid)

proc kickImmediatePrivateChannelSync(api: ProvisioningApi, mxid: string) =
  if not api.runtimeManagersReady() or mxid.len == 0:
    return

  var state = api.getPollingState(mxid)
  state.lastSnapshot = ""
  state.stableCycles = 0
  state.delayMs = 5000
  api.setPollingState(mxid, state)
  api.startPrivateChannelPolling(mxid)
  info("[provisioning] login-token immediate-sync queued user_id=" & mxid)

  asyncCheck (proc() {.async.} =
    if not api.runtimeManagersReady():
      return
    let current = api.runtime.db.getUserByMXID(mxid)
    if not current.found or current.rec.discordToken.len == 0:
      return

    let rest = newDiscordRestClient(current.rec.discordToken)
    let fetched = rest.getPrivateChannels()
    if not fetched.ok:
      if isUnauthorizedDiscordError(fetched.status, fetched.err):
        api.clearDiscordSessionForInvalidToken(mxid, if fetched.err.len > 0: fetched.err else: "unauthorized")
      else:
        api.warnPolling(mxid, "[provisioning] immediate private channel sync failed for " & mxid & ": " & fetched.err)
      return
    if fetched.body.isNil or fetched.body.kind != JArray:
      api.warnPolling(mxid, "[provisioning] immediate private channel sync returned non-array payload for " & mxid)
      return

    try:
      api.bootstrapPrivateChannels(current.rec, logLinkedOnly = false, prefetchedChannels = fetched.body)
      var refreshed = api.getPollingState(mxid)
      refreshed.lastSnapshot = privateChannelSnapshot(fetched.body)
      refreshed.stableCycles = 0
      refreshed.delayMs = 5000
      refreshed.lastRelationshipSyncMs = nowMs()
      api.setPollingState(mxid, refreshed)
    except CatchableError as e:
      if isUnauthorizedDiscordError(0, e.msg):
        api.clearDiscordSessionForInvalidToken(mxid, e.msg)
      else:
        api.warnPolling(mxid, "[provisioning] immediate private channel sync failed for " & mxid & ": " & e.msg)
  )()

proc runPrivateChannelPolling(api: ProvisioningApi, mxid: string): Future[void] {.async.} =
  randomize()
  defer:
    withLock api.lock:
      api.pollingUsers.excl(mxid)
      if api.pollingState.hasKey(mxid):
        api.pollingState.del(mxid)

  var state = api.getPollingState(mxid)
  if state.delayMs <= 0:
    state.delayMs = 5000
  api.setPollingState(mxid, state)
  while true:
    if not api.runtimeManagersReady():
      break
    let current = api.runtime.db.getUserByMXID(mxid)
    if not current.found or current.rec.discordToken.len == 0:
      break

    let rest = newDiscordRestClient(current.rec.discordToken)
    let fetched = rest.getPrivateChannels()
    if not fetched.ok:
      if isUnauthorizedDiscordError(fetched.status, fetched.err):
        api.clearDiscordSessionForInvalidToken(mxid, if fetched.err.len > 0: fetched.err else: "unauthorized")
        break
      let warnMsg = "[provisioning] private channel poll failed for " & mxid & ": " & fetched.err
      api.warnPolling(mxid, warnMsg)
      state = api.getPollingState(mxid)
      state.stableCycles = 0
      state.delayMs = min(60000, max(5000, max(state.delayMs, 5000) * 2))
      api.setPollingState(mxid, state)
      let delay = state.delayMs + rand(500)
      await sleepAsync(delay)
      continue

    if fetched.body.isNil or fetched.body.kind != JArray:
      api.warnPolling(mxid, "[provisioning] private channel poll returned non-array payload for " & mxid)
      state = api.getPollingState(mxid)
      state.stableCycles = 0
      state.delayMs = min(60000, max(5000, max(state.delayMs, 5000) * 2))
      api.setPollingState(mxid, state)
      let delay = state.delayMs + rand(500)
      await sleepAsync(delay)
      continue

    let snapshot = privateChannelSnapshot(fetched.body)
    state = api.getPollingState(mxid)
    let unchanged = snapshot.len > 0 and snapshot == state.lastSnapshot
    try:
      # Bootstrap only when channel snapshot changed; this avoids expensive
      # full DM/channel sync every poll interval during steady state.
      if not unchanged:
        api.bootstrapPrivateChannels(current.rec, logLinkedOnly = false, prefetchedChannels = fetched.body)
        state.stableCycles = 0
        state.lastRelationshipSyncMs = nowMs()
      else:
        inc state.stableCycles
      let nowTs = nowMs()
      let shouldSyncRelationships =
        unchanged and (
          state.lastRelationshipSyncMs <= 0 or
          (nowTs - state.lastRelationshipSyncMs) >= 30000
        )
      if shouldSyncRelationships:
        let relationshipFetch = api.fetchDiscordRelationshipMap(current.rec, rest, "poll")
        if relationshipFetch.ok:
          api.applyDiscordRelationshipMapToDmPortals(relationshipFetch.relationships, "poll")
          state.lastRelationshipSyncMs = nowTs
        elif isUnauthorizedDiscordError(relationshipFetch.status, relationshipFetch.err):
          break
      state.lastSnapshot = snapshot
      state.delayMs = nextPollingDelayMs(state.stableCycles)
      api.setPollingState(mxid, state)
    except CatchableError as e:
      if isUnauthorizedDiscordError(0, e.msg):
        api.clearDiscordSessionForInvalidToken(mxid, e.msg)
        break
      let warnMsg = "[provisioning] private channel poll failed for " & mxid & ": " & e.msg
      api.warnPolling(mxid, warnMsg)
      state.stableCycles = 0
      state.delayMs = min(60000, max(5000, max(state.delayMs, 5000) * 2))
      api.setPollingState(mxid, state)
    let delay = max(1000, state.delayMs + rand(750))
    await sleepAsync(delay)

proc detachDiscordIdentity(api: ProvisioningApi, owningMxid, discordId: string) =
  if discordId.len == 0:
    return

  var reset = UserSessionState(
    connected: false,
    lastHeartbeatAck: 0,
    lastHeartbeatSent: 0,
    username: "",
    discriminator: ""
  )

  if api.runtime != nil and api.runtime.db != nil:
    let linked = api.runtime.db.getUserByDiscordID(discordId)
    if linked.found and linked.rec.mxid != owningMxid:
      var detached = linked.rec
      detached.discordId = ""
      detached.discordToken = ""
      detached.heartbeatSessionJson = sessionStateJson(reset)
      api.storeSessionState(detached.mxid, reset)
      api.storeUser(detached)
    return

  var detachMxid = ""
  var detached = UserRecord()
  withLock api.lock:
    for mxid, rec in api.localUsers:
      if rec.discordId == discordId and mxid != owningMxid:
        detachMxid = mxid
        detached = rec
        break

  if detachMxid.len == 0:
    return
  detached.discordId = ""
  detached.discordToken = ""
  detached.heartbeatSessionJson = sessionStateJson(reset)
  api.storeSessionState(detachMxid, reset)
  api.storeUser(detached)

proc markSessionConnected(
    api: ProvisioningApi,
    user: var UserRecord,
    session: var UserSessionState,
    verifiedDiscordId: string,
    verifiedUsername: string,
    verifiedDiscriminator: string
) =
  if verifiedDiscordId.len > 0:
    api.detachDiscordIdentity(user.mxid, verifiedDiscordId)
    user.discordId = verifiedDiscordId
  elif user.discordId.len == 0:
    let guessedDiscordId = discordIdFromToken(user.discordToken)
    if guessedDiscordId.len > 0:
      api.detachDiscordIdentity(user.mxid, guessedDiscordId)
      user.discordId = guessedDiscordId

  if verifiedUsername.len > 0:
    session.username = verifiedUsername
  if verifiedDiscriminator.len > 0:
    session.discriminator = verifiedDiscriminator

  let ts = nowMs()
  session.connected = true
  session.lastHeartbeatSent = ts
  session.lastHeartbeatAck = ts
  user.heartbeatSessionJson = sessionStateJson(session)
  api.storeSessionState(user.mxid, session)
  api.storeUser(user)

proc resumePersistedDiscordSessions*(api: ProvisioningApi) =
  if api == nil or not api.runtimeManagersReady():
    return

  let usersWithToken = api.runtime.db.getAllUsersWithToken()
  if usersWithToken.len == 0:
    info("[provisioning] startup resume: no stored Discord sessions")
    return

  var resumed = 0
  var failed = 0
  for rec in usersWithToken:
    if rec.mxid.len == 0:
      continue
    let token = rec.discordToken.strip()
    if token.len == 0:
      continue

    var user = rec
    user.discordToken = token
    var session = api.getSessionState(user.mxid)
    let verified = api.verifyDiscordToken(token)
    if not verified.ok:
      inc failed
      warn("[provisioning] startup resume failed for " & user.mxid & ": " & verified.err)
      let errLower = verified.err.toLowerAscii()
      let invalidToken =
        errLower.contains("401") or
        errLower.contains("unauthorized") or
        errLower.contains("invalid token")
      session.connected = false
      session.lastHeartbeatAck = 0
      session.lastHeartbeatSent = 0
      user.heartbeatSessionJson = sessionStateJson(session)
      if invalidToken:
        user.discordToken = ""
        user.discordId = ""
        warn("[provisioning] cleared invalid Discord token for " & user.mxid)
      api.storeSessionState(user.mxid, session)
      api.storeUser(user)
      continue

    api.markSessionConnected(user, session, verified.discordId, verified.username, verified.discriminator)
    api.startPrivateChannelPolling(user.mxid)
    inc resumed

  info("[provisioning] startup resume complete: resumed=" & $resumed & " failed=" & $failed)

proc handleDiscordChatAction(api: ProvisioningApi, user: UserRecord, body: string): ProvisioningResult =
  if user.discordToken.len == 0:
    return provisioningResult(Http409, errorResponse("You're not connected to discord", ErrCodeNotConnected))
  if api.runtime == nil or api.runtime.db == nil:
    return provisioningResult(Http500, errorResponse("Bridge runtime is unavailable", ErrCodeConnectFailed))

  var payload: JsonNode = newJObject()
  try:
    payload = parseJson(body)
  except CatchableError:
    return provisioningResult(Http400, errorResponse("Failed to parse request body", ErrCodeBadJson))

  if payload.isNil or payload.kind != JObject:
    return provisioningResult(Http400, errorResponse("Failed to parse request body", ErrCodeBadJson))

  let roomId = payload{"room_id"}.getStr("").strip()
  let action = payload{"action"}.getStr("").strip().toLowerAscii()
  let eventId = payload{"event_id"}.getStr("").strip()
  if roomId.len == 0 or action.len == 0:
    return provisioningResult(Http400, errorResponse("room_id and action are required", ErrCodeBadJson))
  if action notin ["close-dm", "block", "unblock", "add-friend", "remove-friend", "remove-message"]:
    return provisioningResult(Http400, errorResponse("unsupported action", ErrCodeBadJson))

  let portal = api.runtime.db.getPortalByMXID(roomId)
  if not portal.found:
    return provisioningResult(Http404, errorResponse("Portal not found for room", ErrCodeNotFound))

  var rec = portal.rec
  if rec.key.channelId.len == 0:
    return provisioningResult(Http404, errorResponse("Portal missing Discord channel ID", ErrCodeNotFound))
  if not api.runtime.db.isUserInPortal(user.mxid, rec.key.channelId):
    return provisioningResult(Http404, errorResponse("Portal is not linked for this user", ErrCodeNotFound))
  if rec.portalType != 1 and rec.portalType != 3:
    return provisioningResult(Http400, errorResponse("Chat action is only available for Discord DMs", ErrCodeBadJson))

  let rest = newDiscordRestClient(user.discordToken)
  var relationshipTargetUserId = rec.otherUserId
  if action in ["block", "unblock", "add-friend", "remove-friend"]:
    if rec.portalType != 1:
      let verb =
        case action
        of "block":
          "Block"
        of "unblock":
          "Unblock"
        of "add-friend":
          "Add friend"
        of "remove-friend":
          "Remove friend"
        else:
          "Action"
      return provisioningResult(Http400, errorResponse(verb & " is only available in 1:1 DMs", ErrCodeBadJson))
    # Always resolve the current DM counterpart from Discord channel metadata.
    # This avoids stale other_user_id values and ensures relationship actions
    # target the real current user behind the DM.
    let channelLookup = rest.getChannel(rec.key.channelId)
    if not channelLookup.ok:
      let detail =
        if channelLookup.err.len > 0:
          channelLookup.err
        else:
          "Discord channel lookup failed"
      if isUnauthorizedDiscordError(channelLookup.status, detail):
        api.clearDiscordSessionForInvalidToken(user.mxid, detail)
        return provisioningResult(Http409, errorResponse("You're not connected to discord", ErrCodeNotConnected))
      return provisioningResult(Http502, errorResponse(detail, ErrCodeConnectFailed))
    let resolvedTargetUserId = resolveOtherUserId(channelLookup.body, user.discordId)
    if resolvedTargetUserId.len > 0:
      relationshipTargetUserId = resolvedTargetUserId
      if rec.otherUserId != resolvedTargetUserId:
        rec.otherUserId = resolvedTargetUserId
        api.runtime.db.updatePortal(rec)
    if relationshipTargetUserId.len == 0:
      return provisioningResult(Http400, errorResponse("Cannot " & action & ": DM user is unknown", ErrCodeBadJson))

  var preActionRelationshipType = 0
  var preActionRelationshipTypeKnown = false
  if action in ["block", "unblock", "add-friend", "remove-friend"]:
    let preActionFetch = api.fetchDiscordRelationshipMap(user, rest, "chat-action-pre")
    if preActionFetch.ok:
      preActionRelationshipTypeKnown = true
      if relationshipTargetUserId.len > 0 and preActionFetch.relationships.hasKey(relationshipTargetUserId):
        preActionRelationshipType = preActionFetch.relationships[relationshipTargetUserId].relType
      else:
        preActionRelationshipType = 0
      info("[provisioning] relationship-pre action=" & action &
        " target_user_id=" & relationshipTargetUserId &
        " pre_type=" & relationshipTypeLabel(preActionRelationshipType) &
        " status=" & $preActionFetch.status)
    elif isUnauthorizedDiscordError(preActionFetch.status, preActionFetch.err):
      return provisioningResult(Http409, errorResponse("You're not connected to discord", ErrCodeNotConnected))

  var restResult: DiscordRestResult = (ok: false, status: 0, body: newJNull(), err: "")
  case action
  of "close-dm":
    restResult = rest.closePrivateChannel(rec.key.channelId)
  of "block":
    # Normalize existing relationship state before block.
    # Some states (e.g. pending or stale friend edges) can interfere with block transitions.
    let clearRelationship = rest.removeFriend(relationshipTargetUserId)
    if not clearRelationship.ok and isUnauthorizedDiscordError(clearRelationship.status, clearRelationship.err):
      api.clearDiscordSessionForInvalidToken(user.mxid, clearRelationship.err)
      return provisioningResult(Http409, errorResponse("You're not connected to discord", ErrCodeNotConnected))
    restResult = rest.blockUser(relationshipTargetUserId)
  of "unblock":
    # Discord unblocks by deleting the relationship entry.
    restResult = rest.removeFriend(relationshipTargetUserId)
  of "add-friend":
    restResult = rest.addFriend(relationshipTargetUserId)
  of "remove-friend":
    restResult = rest.removeFriend(relationshipTargetUserId)
  of "remove-message":
    if eventId.len == 0:
      return provisioningResult(Http400, errorResponse("event_id is required for remove-message", ErrCodeBadJson))
    let mapped = api.runtime.db.getMessageByMXID(rec.key, eventId)
    if not mapped.found:
      return provisioningResult(Http404, errorResponse("Message mapping not found for event", ErrCodeNotFound))
    if mapped.rec.discordId.len == 0:
      return provisioningResult(Http404, errorResponse("Discord message ID not found for event", ErrCodeNotFound))
    restResult = rest.deleteMessage(rec.key.channelId, mapped.rec.discordId)
    if restResult.ok:
      let siblings = api.runtime.db.getMessagesByDiscordID(rec.key, mapped.rec.discordId)
      if siblings.len == 0:
        api.runtime.db.deleteMessage(mapped.rec)
      else:
        for sibling in siblings:
          api.runtime.db.deleteMessage(sibling)
  else:
    discard

  if not restResult.ok:
    let detail = if restResult.err.len > 0: restResult.err else: "Discord API request failed"
    if isUnauthorizedDiscordError(restResult.status, detail):
      api.clearDiscordSessionForInvalidToken(user.mxid, detail)
      return provisioningResult(Http409, errorResponse("You're not connected to discord", ErrCodeNotConnected))
    return provisioningResult(Http502, errorResponse(detail, ErrCodeConnectFailed))
  elif action in ["block", "unblock", "add-friend", "remove-friend"]:
    info("[provisioning] relationship-action request ok action=" & action &
      " target_user_id=" & relationshipTargetUserId &
      " status=" & $restResult.status)

  var relationshipVerifyMode = rvmHardSuccess
  if action == "close-dm":
    api.runtime.db.markUserNotInPortal(user.mxid, rec.key.channelId)
  elif action in ["block", "unblock", "add-friend", "remove-friend"]:
    let expected = relationshipExpectedLabel(action)
    var relationshipFetch = api.fetchDiscordRelationshipMap(user, rest, "chat-action-verify")
    var verify = verifyRelationshipActionState(action, relationshipTargetUserId, relationshipFetch.relationships)
    var hadSuccessfulRelationshipFetch = relationshipFetch.ok
    var sawFriendDuringVerification =
      (preActionRelationshipTypeKnown and preActionRelationshipType == 1) or
      verify.actualType == 1
    var lastRelationshipFetchErr =
      if relationshipFetch.ok:
        ""
      else:
        if relationshipFetch.err.len > 0: relationshipFetch.err else: "Discord relationship verification failed"

    info("[provisioning] relationship-verify action=" & action &
      " target_user_id=" & relationshipTargetUserId &
      " expected=" & expected &
      " actual=" & relationshipTypeLabel(verify.actualType) &
      " status=" & $relationshipFetch.status &
      " attempt=0")

    for attempt in 1 .. 4:
      if verify.ok:
        break
      if relationshipFetch.ok and verify.actualType notin [1, 2]:
        # For unblock/remove-friend we can stop once target is neither friend nor blocked.
        if action in ["unblock", "remove-friend"]:
          break
      sleep(min(1000, 150 * attempt))
      relationshipFetch = api.fetchDiscordRelationshipMap(
        user,
        rest,
        "chat-action-verify-retry-" & $attempt
      )
      if relationshipFetch.ok:
        hadSuccessfulRelationshipFetch = true
        verify = verifyRelationshipActionState(action, relationshipTargetUserId, relationshipFetch.relationships)
        if verify.actualType == 1:
          sawFriendDuringVerification = true
      else:
        if relationshipFetch.err.len > 0:
          lastRelationshipFetchErr = relationshipFetch.err
      info("[provisioning] relationship-verify action=" & action &
        " target_user_id=" & relationshipTargetUserId &
        " expected=" & expected &
        " actual=" & relationshipTypeLabel(verify.actualType) &
        " status=" & $relationshipFetch.status &
        " attempt=" & $attempt)

    if not verify.ok and action == "block" and verify.actualType == 1:
      info("[provisioning] relationship-verify remediation action=block target_user_id=" &
        relationshipTargetUserId & " step=remove-friend-then-block")
      let unfriend = rest.removeFriend(relationshipTargetUserId)
      if not unfriend.ok and isUnauthorizedDiscordError(unfriend.status, unfriend.err):
        api.clearDiscordSessionForInvalidToken(user.mxid, unfriend.err)
        return provisioningResult(Http409, errorResponse("You're not connected to discord", ErrCodeNotConnected))
      let secondBlock = rest.blockUser(relationshipTargetUserId)
      if not secondBlock.ok:
        let blockErr = if secondBlock.err.len > 0: secondBlock.err else: "Discord block request failed"
        if isUnauthorizedDiscordError(secondBlock.status, blockErr):
          api.clearDiscordSessionForInvalidToken(user.mxid, blockErr)
          return provisioningResult(Http409, errorResponse("You're not connected to discord", ErrCodeNotConnected))
        return provisioningResult(Http502, errorResponse(blockErr, ErrCodeConnectFailed))
      info("[provisioning] relationship-action remediation request ok action=block target_user_id=" &
        relationshipTargetUserId & " status=" & $secondBlock.status)

      # Re-verify after remediation with short bounded retries.
      for attempt in 0 .. 4:
        if attempt > 0:
          sleep(min(1000, 180 * attempt))
        relationshipFetch = api.fetchDiscordRelationshipMap(
          user,
          rest,
          "chat-action-remediate-verify-" & $attempt
        )
        if relationshipFetch.ok:
          hadSuccessfulRelationshipFetch = true
          verify = verifyRelationshipActionState(action, relationshipTargetUserId, relationshipFetch.relationships)
          if verify.actualType == 1:
            sawFriendDuringVerification = true
        else:
          if relationshipFetch.err.len > 0:
            lastRelationshipFetchErr = relationshipFetch.err
        info("[provisioning] relationship-verify action=" & action &
          " target_user_id=" & relationshipTargetUserId &
          " expected=" & expected &
          " actual=" & relationshipTypeLabel(verify.actualType) &
          " status=" & $relationshipFetch.status &
          " remediate_attempt=" & $attempt)
        if verify.ok:
          break

    if not preActionRelationshipTypeKnown and sawFriendDuringVerification:
      preActionRelationshipTypeKnown = true
      preActionRelationshipType = 1

    var verifyOutcome = resolveRelationshipVerificationResult(
      action,
      verify,
      preActionRelationshipType,
      preActionRelationshipTypeKnown
    )

    if not hadSuccessfulRelationshipFetch:
      if isUnauthorizedDiscordError(relationshipFetch.status, lastRelationshipFetchErr):
        return provisioningResult(Http409, errorResponse("You're not connected to discord", ErrCodeNotConnected))
      if action == "add-friend":
        verifyOutcome = RelationshipVerifyResult(
          mode: rvmSoftSuccess,
          actualType: 0,
          err: "relationship fetch unavailable; accepted as request-sent"
        )
      else:
        let detail =
          if lastRelationshipFetchErr.len > 0:
            lastRelationshipFetchErr
          else:
            "Discord relationship verification failed"
        return provisioningResult(Http502, errorResponse(detail, ErrCodeConnectFailed))

    info("[provisioning] relationship-verify result action=" & action &
      " target_user_id=" & relationshipTargetUserId &
      " expected=" & expected &
      " actual=" & relationshipTypeLabel(verifyOutcome.actualType) &
      " mode=" & relationshipVerifyModeLabel(verifyOutcome.mode) &
      " pre_type=" & (
        if preActionRelationshipTypeKnown:
          relationshipTypeLabel(preActionRelationshipType)
        else:
          "unknown"
      ) &
      (if verifyOutcome.err.len > 0: " reason=" & verifyOutcome.err else: ""))

    if verifyOutcome.mode == rvmFailed:
      let actual = relationshipTypeLabel(verifyOutcome.actualType)
      warn("[provisioning] relationship-verify failed action=" & action &
        " target_user_id=" & relationshipTargetUserId &
        " expected=" & expected &
        " actual=" & actual)
      return provisioningResult(
        Http502,
        errorResponse(
          "Discord relationship verification failed: expected " & expected & ", got " & actual,
          ErrCodeConnectFailed
        )
      )

    if action == "block" and verifyOutcome.mode == rvmSoftSuccess:
      info("[provisioning] relationship-verify fallback success action=block target_user_id=" &
        relationshipTargetUserId & " path=friend-to-none")

    let explicitFriend = action == "add-friend" and verifyOutcome.mode == rvmHardSuccess
    api.applyRelationshipActionIntentToDmPortals(
      relationshipTargetUserId,
      action,
      explicitFriend = explicitFriend
    )
    if relationshipFetch.ok:
      api.applyDiscordRelationshipMapToDmPortals(relationshipFetch.relationships, "chat-action-verify")
    relationshipVerifyMode = verifyOutcome.mode

  let statusText =
    case action
    of "close-dm": "Closed Discord DM"
    of "block": "Blocked Discord user"
    of "unblock": "Unblocked Discord user"
    of "add-friend":
      if relationshipVerifyMode == rvmSoftSuccess:
        "Discord friend request sent"
      else:
        "Added Discord friend"
    of "remove-friend": "Removed Discord friend"
    of "remove-message": "Removed Discord message"
    else: "Discord action completed"
  provisioningResult(Http200, successResponse(statusText))

proc parseBackfillLimit(payload: JsonNode, fallback = 25): int =
  result = fallback
  if payload.isNil or payload.kind != JObject or not payload.hasKey("limit"):
    return
  case payload["limit"].kind
  of JInt:
    result = payload["limit"].getInt(fallback)
  of JString:
    try:
      result = parseInt(payload["limit"].getStr($fallback))
    except CatchableError:
      discard
  else:
    discard
  result = max(1, min(100, result))

proc loadMappedMatrixEventsForPortal(
    api: ProvisioningApi,
    user: UserRecord,
    rec: PortalRecord,
    limit: int
): seq[JsonNode] {.gcsafe.} =
  result = @[]
  if api.runtime == nil or api.runtime.db == nil:
    return
  if rec.mxid.len == 0:
    return

  let mapped = api.runtime.db.getRecentMessages(rec.key, limit)
  if mapped.len == 0:
    return

  var seenEventIds = initHashSet[string]()
  for msg in mapped:
    let eventId = msg.mxid.strip()
    if eventId.len == 0:
      continue
    if eventId in seenEventIds:
      continue
    seenEventIds.incl(eventId)

    let eventPath = "/_matrix/client/v3/rooms/" & encodeUrl(rec.mxid) &
      "/event/" & encodeUrl(eventId)
    var acting = user.mxid
    if acting.len == 0:
      acting = api.appserviceBotUserId()
    let resp = api.matrixClientRequestAsUser(
      actingUser = acting,
      httpMethod = HttpGet,
      path = eventPath
    )
    if not resp.ok:
      # Fallback to bot user if requesting as the bridge user fails.
      let botResp = api.matrixClientRequestAsUser(
        actingUser = api.appserviceBotUserId(),
        httpMethod = HttpGet,
        path = eventPath
      )
      if botResp.ok and botResp.body.kind == JObject:
        result.add(botResp.body)
      continue
    if resp.body.kind == JObject:
      result.add(resp.body)
    if result.len >= limit:
      break

proc handleDiscordHistoryBackfill(api: ProvisioningApi, user: UserRecord, body: string): ProvisioningResult =
  if user.discordToken.len == 0:
    return provisioningResult(Http409, errorResponse("You're not connected to discord", ErrCodeNotConnected))
  if api.runtime == nil or api.runtime.db == nil:
    return provisioningResult(Http500, errorResponse("Bridge runtime is unavailable", ErrCodeConnectFailed))

  var payload: JsonNode = newJObject()
  try:
    payload = parseJson(body)
  except CatchableError:
    return provisioningResult(Http400, errorResponse("Failed to parse request body", ErrCodeBadJson))

  if payload.isNil or payload.kind != JObject:
    return provisioningResult(Http400, errorResponse("Failed to parse request body", ErrCodeBadJson))

  let roomId = payload{"room_id"}.getStr("").strip()
  if roomId.len == 0:
    return provisioningResult(Http400, errorResponse("room_id is required", ErrCodeBadJson))
  let limit = parseBackfillLimit(payload, 25)

  let portal = api.runtime.db.getPortalByMXID(roomId)
  if not portal.found:
    return provisioningResult(Http404, errorResponse("Portal not found for room", ErrCodeNotFound))
  let rec = portal.rec
  if rec.key.channelId.len == 0:
    return provisioningResult(Http404, errorResponse("Portal missing Discord channel ID", ErrCodeNotFound))
  if not api.runtime.db.isUserInPortal(user.mxid, rec.key.channelId):
    return provisioningResult(Http404, errorResponse("Portal is not linked for this user", ErrCodeNotFound))
  if rec.portalType notin [1, 3]:
    return provisioningResult(Http400, errorResponse("History backfill is only available for Discord DMs", ErrCodeBadJson))

  let requestedCursor = payload{"cursor"}.getStr("").strip()
  let oldestEventId = payload{"oldest_event_id"}.getStr("").strip()
  var cursor = requestedCursor
  let cursorProvided = requestedCursor.len > 0
  let oldestEventProvided = oldestEventId.len > 0
  if cursor.len == 0 and oldestEventId.len > 0:
    let mapped = api.runtime.db.getMessageByMXID(rec.key, oldestEventId)
    if mapped.found and mapped.rec.discordId.len > 0:
      cursor = mapped.rec.discordId
  if cursor.len == 0:
    let oldestMapped = api.runtime.db.getOldestMessage(rec.key)
    if oldestMapped.found and oldestMapped.rec.discordId.len > 0:
      cursor = oldestMapped.rec.discordId

  let page = api.syncPrivateChannelMessagesPage(
    user = user,
    rec = rec,
    limit = limit,
    beforeCursor = cursor,
    onlyNew = false
  )
  if page.err.len > 0:
    if isUnauthorizedDiscordError(0, page.err):
      api.clearDiscordSessionForInvalidToken(user.mxid, page.err)
      return provisioningResult(Http409, errorResponse("You're not connected to discord", ErrCodeNotConnected))
    return provisioningResult(Http502, errorResponse(page.err, ErrCodeConnectFailed))

  var fallbackEvents = newJArray()
  # If no new events were sent to Matrix (common when mappings already exist),
  # return fallback events for the exact fetched Discord page first. This keeps
  # cursor pagination range-correct and avoids replaying recent duplicates.
  if page.syncedCount == 0:
    if page.fetchedMessages.len > 0:
      for eventData in api.buildSyntheticFallbackEventsFromDiscordMessages(rec, page.fetchedMessages, limit):
        fallbackEvents.add(eventData)
    # Initial bootstrap only: if there was no explicit cursor context and the
    # fetched page is empty, try loading recent mapped Matrix events.
    if fallbackEvents.len == 0 and not cursorProvided and not oldestEventProvided:
      for eventData in api.loadMappedMatrixEventsForPortal(user, rec, limit):
        fallbackEvents.add(eventData)
    # Initial "latest-load" can request history before the oldest mapped event.
    # If that returns empty and Matrix event fetch is unavailable, fetch latest
    # Discord messages directly as a last-resort source for client cache restore.
    if fallbackEvents.len == 0 and not cursorProvided and not oldestEventProvided:
      let latestMessages = api.fetchLatestDiscordMessagesForFallback(user, rec.key.channelId, limit)
      for eventData in api.buildSyntheticFallbackEventsFromDiscordMessages(rec, latestMessages, limit):
        fallbackEvents.add(eventData)

  return provisioningResult(Http200, %*{
    "success": true,
    "inserted_count": page.syncedCount,
    "next_cursor": page.oldestFetchedDiscordId,
    "has_more": page.hasMore,
    "endpoint_available": true,
    "events": fallbackEvents
  })

proc subPath(api: ProvisioningApi, fullPath: string): tuple[handled: bool, sub: string] =
  let prefix = api.cfg.bridge.provisioning.prefix.strip()
  if prefix.len == 0 or prefix == "disable":
    return (false, "")
  if not fullPath.startsWith(prefix):
    return (false, "")
  var sub = fullPath[prefix.len .. ^1]
  if sub.len == 0:
    sub = "/"
  (true, sub)

proc handleRequest*(
    api: ProvisioningApi,
    reqMethod: HttpMethod,
    path: string,
    query: string,
    headers: HttpHeaders,
    body: string
): ProvisioningResult =
  let mapped = api.subPath(path)
  if not mapped.handled:
    return ProvisioningResult(handled: false, code: Http404, payload: newJNull())

  if not api.authorized(headers, path):
    return provisioningResult(Http401, errorResponse("Invalid auth token", ErrCodeUnknownToken))

  let sub = mapped.sub
  let uid = queryParam(query, "user_id")
  if uid.len == 0:
    return provisioningResult(Http400, errorResponse("Missing user_id query parameter", ErrCodeBadJson))
  var user = api.getOrCreateUser(uid)
  var session = api.getSessionState(user.mxid)

  if reqMethod == HttpGet and sub == "/v1/ping":
    let verifyToken = queryParamBool(query, "verify_token")
    if verifyToken and user.discordToken.len > 0:
      let verified = api.verifyDiscordToken(user.discordToken)
      if not verified.ok:
        if isUnauthorizedDiscordError(0, verified.err):
          api.clearDiscordSessionForInvalidToken(
            user.mxid,
            if verified.err.len > 0: verified.err else: "invalid token"
          )
          user = api.getOrCreateUser(uid)
          session = api.getSessionState(user.mxid)
      else:
        api.markSessionConnected(user, session, verified.discordId, verified.username, verified.discriminator)
        user = api.getOrCreateUser(uid)
        session = api.getSessionState(user.mxid)
    if api.runtimeManagersReady() and user.discordToken.len > 0:
      # Keep /ping lightweight: background poller handles room/bootstrap sync.
      api.startPrivateChannelPolling(user.mxid)
    return provisioningResult(Http200, pingResponse(
      user.mxid,
      user.managementRoom,
      user.discordId,
      user.discordToken.len > 0,
      session.connected,
      session.lastHeartbeatAck,
      session.lastHeartbeatSent
    ))

  if reqMethod == HttpPost and sub == "/v1/logout":
    let status = if user.discordId.len > 0: "Logged out successfully." else: "User wasn't logged in."
    user.discordId = ""
    user.discordToken = ""
    session.connected = false
    session.lastHeartbeatAck = 0
    session.lastHeartbeatSent = 0
    user.heartbeatSessionJson = sessionStateJson(session)
    api.storeSessionState(user.mxid, session)
    api.storeUser(user)
    return provisioningResult(Http200, successResponse(status))

  if reqMethod == HttpPost and sub == "/v1/disconnect":
    if not session.connected:
      return provisioningResult(Http409, errorResponse("You're not connected to discord", ErrCodeNotConnected))
    session.connected = false
    session.lastHeartbeatAck = 0
    session.lastHeartbeatSent = 0
    user.heartbeatSessionJson = sessionStateJson(session)
    api.storeSessionState(user.mxid, session)
    api.storeUser(user)
    return provisioningResult(Http200, successResponse("Disconnected from Discord"))

  if reqMethod == HttpPost and sub == "/v1/reconnect":
    if session.connected:
      return provisioningResult(Http409, errorResponse("You're already connected to discord", ErrCodeAlreadyConnected))
    if user.discordToken.len == 0:
      return provisioningResult(Http500, errorResponse("Failed to connect to discord", ErrCodeConnectFailed))
    let verified = api.verifyDiscordToken(user.discordToken)
    if not verified.ok:
      return provisioningResult(Http500, errorResponse("Failed to connect to discord", ErrCodeConnectFailed))
    let ts = nowMs()
    session.connected = true
    session.lastHeartbeatSent = ts
    session.lastHeartbeatAck = ts
    if verified.username.len > 0:
      session.username = verified.username
    if verified.discriminator.len > 0:
      session.discriminator = verified.discriminator
    if verified.discordId.len > 0:
      api.detachDiscordIdentity(user.mxid, verified.discordId)
      user.discordId = verified.discordId
    user.heartbeatSessionJson = sessionStateJson(session)
    api.storeSessionState(user.mxid, session)
    api.storeUser(user)
    if api.runtimeManagersReady():
      # Avoid heavy synchronous bootstrap inside request handling.
      api.startPrivateChannelPolling(user.mxid)
    # Startup coordinator already runs on bridge startup; avoid re-entry here.
    return provisioningResult(Http200, successResponse("Connected to Discord"))

  if reqMethod == HttpGet and sub == "/v1/login/qr":
    if user.discordToken.len > 0:
      return provisioningResult(Http409, errorResponse("You're already logged into Discord", ErrCodeAlreadyLoggedIn))
    return provisioningResult(Http400, errorResponse("QR login requires websocket upgrade", ErrCodeLoginPrepareFailed))

  if reqMethod == HttpPost and sub == "/v1/login/token":
    info("[provisioning] /v1/login/token request user_id=" & user.mxid & " runtimeReady=" & $(api.runtimeManagersReady()))
    if user.discordToken.len > 0:
      let existing = api.verifyDiscordToken(user.discordToken)
      if existing.ok:
        var existingSession = api.getSessionState(user.mxid)
        api.markSessionConnected(user, existingSession, existing.discordId, existing.username, existing.discriminator)
        if api.runtimeManagersReady():
          # Keep token login idempotent and fast while kicking an immediate DM sync.
          api.kickImmediatePrivateChannelSync(user.mxid)
        return provisioningResult(Http200, loginResponse(user.discordId, existingSession.username, existingSession.discriminator))
      user.discordToken = ""
      user.discordId = ""
      var reset = api.getSessionState(user.mxid)
      reset.connected = false
      reset.lastHeartbeatAck = 0
      reset.lastHeartbeatSent = 0
      reset.username = ""
      reset.discriminator = ""
      user.heartbeatSessionJson = sessionStateJson(reset)
      api.storeSessionState(user.mxid, reset)
      api.storeUser(user)

    var payload: JsonNode = newJObject()
    try:
      payload = parseJson(body)
    except CatchableError:
      return provisioningResult(Http400, errorResponse("Failed to parse request body", ErrCodeBadJson))

    if payload.isNil or payload.kind != JObject or not payload.hasKey("token") or payload["token"].kind != JString:
      return provisioningResult(Http400, errorResponse("Failed to parse request body", ErrCodeBadJson))

    let token = payload["token"].getStr().strip()
    if token.len == 0:
      return provisioningResult(Http401, errorResponse("Failed to connect to Discord", ErrCodePostLoginConnFailed))

    info("[provisioning] /v1/login/token verifying token for " & user.mxid)
    let verified = api.verifyDiscordToken(token)
    if not verified.ok:
      return provisioningResult(Http401, errorResponse("Failed to connect to Discord", ErrCodePostLoginConnFailed))
    info("[provisioning] /v1/login/token token verified for " & user.mxid)

    user.discordToken = token
    api.markSessionConnected(user, session, verified.discordId, verified.username, verified.discriminator)
    info("[provisioning] /v1/login/token storing user/session for " & user.mxid)
    info("[provisioning] /v1/login/token stored user/session for " & user.mxid)
    if api.runtimeManagersReady():
      info("[provisioning] /v1/login/token scheduling polling sync for " & user.mxid)
      api.kickImmediatePrivateChannelSync(user.mxid)
      info("[provisioning] /v1/login/token polling started for " & user.mxid)
    # Startup coordinator already runs on bridge startup; avoid re-entry here.
    info("[provisioning] /v1/login/token success for " & user.mxid)
    return provisioningResult(Http200, loginResponse(user.discordId, session.username, session.discriminator))

  if reqMethod == HttpPost and sub == "/v1/discord/chat_action":
    return api.handleDiscordChatAction(user, body)

  if reqMethod == HttpPost and sub == "/v1/discord/history_backfill":
    return api.handleDiscordHistoryBackfill(user, body)

  if reqMethod == HttpGet and sub == "/v1/guilds":
    return provisioningResult(Http200, %*{"guilds": []})

  if (reqMethod == HttpPost or reqMethod == HttpDelete) and sub.startsWith("/v1/guilds/"):
    return provisioningResult(Http200, %*{"success": true, "mxid": ""})

  provisioningResult(Http404, errorResponse("unknown provisioning endpoint", ErrCodeNotFound))

proc handleQrLoginWs(api: ProvisioningApi, req: Request, uid: string): Future[void] {.async.} =
  let accepted = await acceptWs(req, SecWebSocketProtocol)
  if not accepted.ok:
    try:
      await jsonResponse(req, Http400, errorResponse("Failed to prepare login", ErrCodeLoginPrepareFailed))
    except CatchableError:
      discard
    return

  let ws = accepted.ws
  defer:
    ws.close()

  var user = api.getOrCreateUser(uid)
  if user.discordToken.len > 0:
    discard await ws.sendJson(errorResponse("You're already logged into Discord", ErrCodeAlreadyLoggedIn))
    await ws.closeWithCode(1000'u16)
    return

  var qrCodes: seq[string] = @[]
  let login = await api.runQrLogin(DefaultRemoteAuthTimeoutMs, proc(url: string) {.gcsafe.} =
    qrCodes.add(url)
  )

  for qr in qrCodes:
    discard await ws.sendJson(%*{
      "code": qr,
      "timeout": 120
    })

  if login.ok:
    var session = api.getSessionState(user.mxid)
    let ts = nowMs()
    session.connected = true
    session.lastHeartbeatAck = ts
    session.lastHeartbeatSent = ts
    session.username = login.user.username
    session.discriminator = login.user.discriminator

    user.discordToken = login.user.token
    let loginDiscordId =
      if login.user.userId.len > 0:
        login.user.userId
      else:
        discordIdFromToken(login.user.token)
    if loginDiscordId.len > 0:
      api.detachDiscordIdentity(user.mxid, loginDiscordId)
      user.discordId = loginDiscordId

    user.heartbeatSessionJson = sessionStateJson(session)
    api.storeSessionState(user.mxid, session)
    api.storeUser(user)
    # Keep websocket login response quick; poller handles bootstrap/sync.
    api.startPrivateChannelPolling(user.mxid)

    if qrCodes.len == 0:
      discard await ws.sendJson(%*{
        "code": "",
        "timeout": 120
      })
    discard await ws.sendJson(loginResponse(user.discordId, login.user.username, login.user.discriminator))
    await ws.closeWithCode(1000'u16)
  else:
    let errcode = mapFailureToErrcode(login.failure)
    let msg = if login.err.len > 0: login.err else: "Failed to log in"
    discard await ws.sendJson(errorResponse(msg, errcode))
    await ws.closeWithCode(1000'u16)

proc newProvisioningApi*(cfg: Config, runtime: DiscordBridgeRuntime = nil): ProvisioningApi =
  new(result)
  result.cfg = cfg
  result.runtime = runtime
  result.sessions = initTable[string, UserSessionState]()
  result.localUsers = initTable[string, UserRecord]()
  result.pollingUsers = initHashSet[string]()
  result.pollingState = initTable[string, PollingState]()
  result.runQrLogin = proc(timeoutMs: int, onQrCode: proc(url: string) {.closure, gcsafe.}): Future[RemoteAuthLoginResult] {.async, gcsafe.} =
    await runRemoteAuthLogin(timeoutMs, onQrCode)
  result.verifyDiscordToken = verifyDiscordTokenWithRest
  result.fetchDiscordMessages = nil
  initLock(result.lock)

proc handle*(api: ProvisioningApi, req: Request): Future[bool] {.async.} =
  let mapped = api.subPath(req.url.path)
  if not mapped.handled:
    return false

  if not api.authorized(req.headers, req.url.path):
    await jsonResponse(req, Http401, errorResponse("Invalid auth token", ErrCodeUnknownToken))
    return true

  if req.reqMethod == HttpGet and mapped.sub == "/v1/login/qr" and req.isWsUpgrade():
    let uid = queryParam(req.url.query, "user_id")
    await api.handleQrLoginWs(req, uid)
    return true

  let outcome = api.handleRequest(req.reqMethod, req.url.path, req.url.query, req.headers, req.body)
  if not outcome.handled:
    return false
  await jsonResponse(req, outcome.code, outcome.payload)
  true
