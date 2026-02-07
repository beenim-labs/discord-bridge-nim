## Provisioning API shell compatible with Go route surface.

import std/[asyncdispatch, asynchttpserver, base64, json, locks, strutils, tables, times, uri]
import config/config
import bridge/runtime
import database/[entities, store]
import provisioning/[contracts, ws_qr]
import remoteauth/live_client

type
  UserSessionState = object
    connected: bool
    lastHeartbeatAck: int64
    lastHeartbeatSent: int64
    username: string
    discriminator: string

  RunQrLoginFn* = proc(timeoutMs: int, onQrCode: proc(url: string) {.closure, gcsafe.}): Future[RemoteAuthLoginResult] {.closure, gcsafe.}

  ProvisioningResult* = object
    handled*: bool
    code*: HttpCode
    payload*: JsonNode

  ProvisioningApi* = ref object
    cfg*: Config
    runtime*: DiscordBridgeRuntime
    runQrLogin*: RunQrLoginFn
    lock: Lock
    sessions: Table[string, UserSessionState]
    localUsers: Table[string, UserRecord]

proc nowMs(): int64 =
  getTime().toUnix().int64 * 1000

proc queryParam(query: string, name: string): string =
  if query.len == 0:
    return ""
  for key, val in decodeQuery(query):
    if key == name:
      return val
  ""

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
  if api.runtime != nil:
    let fromMgr = api.runtime.users.getByMXID(mxid, createIfMissing = true)
    if fromMgr.found:
      return fromMgr.rec
    return newUserRecord(mxid)

  withLock api.lock:
    if api.localUsers.hasKey(mxid):
      result = api.localUsers[mxid]
    else:
      let created = newUserRecord(mxid)
      api.localUsers[mxid] = created
      result = created

proc storeUser(api: ProvisioningApi, rec: UserRecord) =
  if api.runtime != nil:
    api.runtime.users.upsert(rec)
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
  var user = api.getOrCreateUser(uid)
  var session = api.getSessionState(user.mxid)

  if reqMethod == HttpGet and sub == "/v1/ping":
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
    let ts = nowMs()
    session.connected = true
    session.lastHeartbeatSent = ts
    session.lastHeartbeatAck = ts
    user.heartbeatSessionJson = sessionStateJson(session)
    api.storeSessionState(user.mxid, session)
    api.storeUser(user)
    return provisioningResult(Http200, successResponse("Connected to Discord"))

  if reqMethod == HttpGet and sub == "/v1/login/qr":
    if user.discordToken.len > 0:
      return provisioningResult(Http409, errorResponse("You're already logged into Discord", ErrCodeAlreadyLoggedIn))
    return provisioningResult(Http400, errorResponse("QR login requires websocket upgrade", ErrCodeLoginPrepareFailed))

  if reqMethod == HttpPost and sub == "/v1/login/token":
    if user.discordToken.len > 0:
      return provisioningResult(Http409, errorResponse("You're already logged into Discord", ErrCodeAlreadyLoggedIn))

    var payload: JsonNode = newJObject()
    try:
      payload = parseJson(body)
    except CatchableError:
      return provisioningResult(Http400, errorResponse("Failed to parse request body", ErrCodeBadJson))

    if payload.kind != JObject or not payload.hasKey("token") or payload["token"].kind != JString:
      return provisioningResult(Http400, errorResponse("Failed to parse request body", ErrCodeBadJson))

    let token = payload["token"].getStr().strip()
    if token.len == 0:
      return provisioningResult(Http401, errorResponse("Failed to connect to Discord", ErrCodePostLoginConnFailed))

    user.discordToken = token
    if user.discordId.len == 0:
      user.discordId = discordIdFromToken(token)

    let ts = nowMs()
    session.connected = true
    session.lastHeartbeatSent = ts
    session.lastHeartbeatAck = ts
    user.heartbeatSessionJson = sessionStateJson(session)
    api.storeSessionState(user.mxid, session)
    api.storeUser(user)
    return provisioningResult(Http200, loginResponse(user.discordId, session.username, session.discriminator))

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
    if user.discordId.len == 0:
      user.discordId =
        if login.user.userId.len > 0:
          login.user.userId
        else:
          discordIdFromToken(login.user.token)

    user.heartbeatSessionJson = sessionStateJson(session)
    api.storeSessionState(user.mxid, session)
    api.storeUser(user)

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
  result.runQrLogin = proc(timeoutMs: int, onQrCode: proc(url: string) {.closure, gcsafe.}): Future[RemoteAuthLoginResult] {.async, gcsafe.} =
    await runRemoteAuthLogin(timeoutMs, onQrCode)
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
