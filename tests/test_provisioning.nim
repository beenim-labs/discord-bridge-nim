import std/[httpcore, json, unittest]
import config/config
import provisioning/[contracts, server]

proc newTestApi(): ProvisioningApi =
  var cfg = defaultConfig()
  cfg.bridge.provisioning.prefix = "/_matrix/provision"
  cfg.bridge.provisioning.sharedSecret = "secret"
  newProvisioningApi(cfg)

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

  test "token login parse and conflict behavior":
    let api = newTestApi()

    let bad = api.call(HttpPost, "/_matrix/provision/v1/login/token", body = "{")
    check bad.code == Http400
    check bad.payload["errcode"].getStr() == ErrCodeBadJson

    let ok = api.call(HttpPost, "/_matrix/provision/v1/login/token", body = """{"token":"MTIz.abc.xyz"}""")
    check ok.code == Http200
    check ok.payload["success"].getBool()
    check ok.payload["id"].getStr() == "123"

    let conflict = api.call(HttpPost, "/_matrix/provision/v1/login/token", body = """{"token":"MTIz.abc.xyz"}""")
    check conflict.code == Http409
    check conflict.payload["errcode"].getStr() == ErrCodeAlreadyLoggedIn

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
