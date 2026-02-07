import std/[asyncdispatch, asynchttpserver, asyncnet, httpcore, json, strutils, unittest]
import config/config
import provisioning/[contracts, server]
import discord/ws_transport
import remoteauth/[live_client, user]

proc newTestApi(): ProvisioningApi =
  var cfg = defaultConfig()
  cfg.bridge.provisioning.prefix = "/_matrix/provision"
  cfg.bridge.provisioning.sharedSecret = "secret"
  newProvisioningApi(cfg)

proc bytesToString(data: openArray[byte]): string =
  result = newString(data.len)
  for i, b in data:
    result[i] = char(b)

proc recvUntil(sock: AsyncSocket, delim: string): Future[string] {.async.} =
  result = ""
  while delim notin result:
    var fut = sock.recv(4096)
    let ok = await withTimeout(fut, 2000)
    if not ok:
      break
    let chunk = fut.read()
    if chunk.len == 0:
      break
    result.add(chunk)

proc collectWsTextFrames(sock: AsyncSocket, maxFrames: int, initialBuffer: seq[byte] = @[]): Future[seq[JsonNode]] {.async.} =
  result = @[]
  var buffer: seq[byte] = initialBuffer

  for _ in 0 ..< maxFrames:
    var gotFrame = false
    while not gotFrame:
      if buffer.len > 0:
        let parsed = parseWsFrame(buffer)
        if parsed.ok:
          if parsed.consumed >= buffer.len:
            buffer = @[]
          else:
            buffer = buffer[parsed.consumed .. ^1]

          gotFrame = true
          case parsed.frame.opcode
          of 0x1'u8:
            result.add(parseJson(bytesToString(parsed.frame.payload)))
          of 0x8'u8:
            return
          else:
            discard
          break
        elif parsed.err != ErrWsIncompleteFrame:
          return

      var fut = sock.recv(4096)
      let ok = await withTimeout(fut, 2000)
      if not ok:
        return
      let chunk = fut.read()
      if chunk.len == 0:
        return
      for ch in chunk:
        buffer.add(byte(ch))

proc runRequest(
    api: ProvisioningApi,
    rawRequest: string,
    expectWs: bool,
    maxFrames: int
): Future[tuple[statusLine: string, body: string, frames: seq[JsonNode]]] {.async.} =
  var httpServer = newAsyncHttpServer()
  proc cb(req: Request) {.async, gcsafe.} =
    let handled = await api.handle(req)
    if not handled:
      await req.respond(Http404, """{"error":"missing"}""", newHttpHeaders({"Content-Type": "application/json"}))

  httpServer.listen(Port(0), "127.0.0.1")
  let port = httpServer.getPort
  asyncCheck httpServer.acceptRequest(cb)
  await sleepAsync(10)

  let client = newAsyncSocket()
  await client.connect("127.0.0.1", port)
  await client.send(rawRequest)

  let rawResponse = await recvUntil(client, "\r\n\r\n")
  let headerEnd = rawResponse.find("\r\n\r\n")
  let responseHeaders =
    if headerEnd >= 0:
      rawResponse[0 ..< headerEnd]
    else:
      rawResponse
  var inlineBody =
    if headerEnd >= 0 and headerEnd + 4 < rawResponse.len:
      rawResponse[headerEnd + 4 .. ^1]
    else:
      ""

  let firstNewline = responseHeaders.find("\r\n")
  let statusLine = if firstNewline > 0: responseHeaders[0 ..< firstNewline] else: responseHeaders

  var body = ""
  var frames: seq[JsonNode] = @[]
  if expectWs:
    var initialWs: seq[byte] = @[]
    for ch in inlineBody:
      initialWs.add(byte(ch))
    frames = await collectWsTextFrames(client, maxFrames, initialWs)
  else:
    body = inlineBody
    var fut = client.recv(4096)
    let ok = await withTimeout(fut, 500)
    if ok:
      body.add(fut.read())

  client.close()
  httpServer.close()
  (statusLine, body, frames)

suite "provisioning ws qr":
  test "websocket upgrade success and payloads":
    let api = newTestApi()
    api.runQrLogin = proc(timeoutMs: int, onQrCode: proc(url: string) {.closure, gcsafe.}): Future[RemoteAuthLoginResult] {.async, gcsafe.} =
      onQrCode("https://discordapp.com/ra/ws123")
      await sleepAsync(20)
      let u = RemoteAuthUser(
        userId: "123",
        discriminator: "0001",
        avatarHash: "",
        username: "alice",
        token: "MTIz.abc.xyz"
      )
      RemoteAuthLoginResult(ok: true, user: u, err: "", failure: rafNone)

    let request = "GET /_matrix/provision/v1/login/qr?user_id=%40alice%3Alocalhost HTTP/1.1\r\n" &
      "Host: localhost\r\n" &
      "Authorization: Bearer secret\r\n" &
      "Connection: Upgrade\r\n" &
      "Upgrade: websocket\r\n" &
      "Sec-WebSocket-Version: 13\r\n" &
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
      "Sec-WebSocket-Protocol: chat, " & SecWebSocketProtocol & "-secret\r\n" &
      "\r\n"

    let res = waitFor runRequest(api, request, expectWs = true, maxFrames = 3)
    check "101" in res.statusLine
    check res.frames.len >= 2
    if res.frames.len >= 2:
      check res.frames[0]["code"].getStr() == "https://discordapp.com/ra/ws123"
      check res.frames[0]["timeout"].getInt() == 120
      check res.frames[1]["success"].getBool()
      check res.frames[1]["id"].getStr() == "123"
      check res.frames[1]["username"].getStr() == "alice"
      check res.frames[1]["discriminator"].getStr() == "0001"

  test "non-upgrade qr login returns prepare error":
    let api = newTestApi()
    let res = api.handleRequest(
      HttpGet,
      "/_matrix/provision/v1/login/qr",
      "user_id=%40alice%3Alocalhost",
      newHttpHeaders({"Authorization": "Bearer secret"}),
      ""
    )
    check res.handled
    check res.code == Http400
    check res.payload["errcode"].getStr() == ErrCodeLoginPrepareFailed

  test "already logged in conflict over websocket":
    let api = newTestApi()
    discard api.handleRequest(
      HttpPost,
      "/_matrix/provision/v1/login/token",
      "user_id=%40alice%3Alocalhost",
      newHttpHeaders({"Authorization": "Bearer secret"}),
      """{"token":"MTIz.abc.xyz"}"""
    )

    let request = "GET /_matrix/provision/v1/login/qr?user_id=%40alice%3Alocalhost HTTP/1.1\r\n" &
      "Host: localhost\r\n" &
      "Authorization: Bearer secret\r\n" &
      "Connection: Upgrade\r\n" &
      "Upgrade: websocket\r\n" &
      "Sec-WebSocket-Version: 13\r\n" &
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
      "Sec-WebSocket-Protocol: " & SecWebSocketProtocol & "-secret\r\n" &
      "\r\n"

    let res = waitFor runRequest(api, request, expectWs = true, maxFrames = 2)
    check "101" in res.statusLine
    check res.frames.len >= 1
    if res.frames.len >= 1:
      check res.frames[0]["errcode"].getStr() == ErrCodeAlreadyLoggedIn
