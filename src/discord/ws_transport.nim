## Standalone websocket transport for Discord gateway/session use.

{.push warning[Uninit]: off, warning[ProveInit]: off, warning[Deprecated]: off.}

import std/[net, uri, strutils, tables, times, base64, random, sha1]

type
  WsConnState* = enum
    wcsDisconnected
    wcsConnecting
    wcsOpen
    wcsClosing

  WsTransportConfig* = object
    userAgent*: string
    origin*: string
    handshakeTimeoutMs*: int
    recvTimeoutMs*: int
    readChunkSize*: int
    tlsVerifyPeer*: bool
    extraHeaders*: Table[string, string]

  WsFrame* = object
    fin*: bool
    opcode*: uint8
    masked*: bool
    payload*: seq[byte]
    closeCode*: uint16
    closeReason*: string

  WsTransportResult* = tuple[ok: bool, err: string]
  WsTransportRecvResult* = tuple[ok: bool, frame: seq[byte], err: string]

  WsTransport* = ref object
    cfg*: WsTransportConfig
    socket: Socket
    sslContext: SslContext
    state*: WsConnState
    endpoint*: string
    recvBuffer: seq[byte]
    fragmentOpcode: uint8
    fragmentBuffer: seq[byte]

const
  WsGuid* = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  DefaultWsUserAgent* = "bridge-discord-nim/1"
  ErrWsIncompleteFrame* = "incomplete frame"
  ErrWsTimeout* = "timeout"
  ErrWsRemoteClosed* = "remote closed"

var seeded = false

proc defaultWsTransportConfig*(): WsTransportConfig =
  WsTransportConfig(
    userAgent: DefaultWsUserAgent,
    origin: "",
    handshakeTimeoutMs: 10_000,
    recvTimeoutMs: 5_000,
    readChunkSize: 16_384,
    tlsVerifyPeer: true,
    extraHeaders: initTable[string, string]()
  )

proc nowMs(): int64 =
  getTime().toUnix().int64 * 1000

proc toBytes(s: string): seq[byte] =
  result = newSeqOfCap[byte](s.len)
  for ch in s:
    result.add(ch.byte)

proc toString(data: openArray[byte]): string =
  result = newStringOfCap(data.len)
  for b in data:
    result.add(char(b))

proc secureRandom(n: int): seq[byte] =
  if n <= 0:
    return @[]
  if not seeded:
    randomize()
    seeded = true
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = byte(rand(255))

proc createHandshakeKey*(): string =
  encode(secureRandom(16))

proc computeAcceptKey*(clientKey: string): string =
  var ctx = newSha1State()
  ctx.update(clientKey & WsGuid)
  let digest = ctx.finalize()
  var bytes: seq[byte] = @[]
  for b in digest:
    bytes.add(b)
  encode(bytes)

proc buildHandshakeRequest*(host, path, secKey: string, cfg: WsTransportConfig): string =
  var lines = @[
    "GET " & path & " HTTP/1.1",
    "Host: " & host,
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " & secKey,
    "Sec-WebSocket-Version: 13"
  ]

  if cfg.userAgent.len > 0:
    lines.add("User-Agent: " & cfg.userAgent)
  if cfg.origin.len > 0:
    lines.add("Origin: " & cfg.origin)
  for k, v in cfg.extraHeaders:
    lines.add(k & ": " & v)

  lines.join("\r\n") & "\r\n\r\n"

proc parseWsFrame*(buffer: openArray[byte]): tuple[ok: bool, frame: WsFrame, consumed: int, err: string] =
  var frame = WsFrame(fin: false, opcode: 0, masked: false, payload: @[], closeCode: 0, closeReason: "")
  if buffer.len < 2:
    return (false, frame, 0, ErrWsIncompleteFrame)

  let b0 = buffer[0]
  let b1 = buffer[1]
  frame.fin = (b0 and 0x80'u8) != 0
  frame.opcode = b0 and 0x0F'u8
  frame.masked = (b1 and 0x80'u8) != 0

  var idx = 2
  var payloadLen = uint64(b1 and 0x7F'u8)
  if payloadLen == 126'u64:
    if buffer.len < idx + 2:
      return (false, frame, 0, ErrWsIncompleteFrame)
    payloadLen = (uint64(buffer[idx]) shl 8) or uint64(buffer[idx + 1])
    idx += 2
  elif payloadLen == 127'u64:
    if buffer.len < idx + 8:
      return (false, frame, 0, ErrWsIncompleteFrame)
    payloadLen = 0
    for _ in 0 ..< 8:
      payloadLen = (payloadLen shl 8) or uint64(buffer[idx])
      inc idx

  if frame.opcode in [0x8'u8, 0x9'u8, 0xA'u8] and payloadLen > 125'u64:
    return (false, frame, 0, "invalid control frame length")

  var maskingKey = [byte(0), byte(0), byte(0), byte(0)]
  if frame.masked:
    if buffer.len < idx + 4:
      return (false, frame, 0, ErrWsIncompleteFrame)
    for i in 0 ..< 4:
      maskingKey[i] = buffer[idx + i]
    idx += 4

  if payloadLen > uint64(high(int)):
    return (false, frame, 0, "frame too large")
  let totalNeeded = idx + int(payloadLen)
  if buffer.len < totalNeeded:
    return (false, frame, 0, ErrWsIncompleteFrame)

  frame.payload = newSeq[byte](int(payloadLen))
  for i in 0 ..< int(payloadLen):
    var value = buffer[idx + i]
    if frame.masked:
      value = value xor maskingKey[i mod 4]
    frame.payload[i] = value

  if frame.opcode == 0x8'u8 and frame.payload.len >= 2:
    frame.closeCode = (uint16(frame.payload[0]) shl 8) or uint16(frame.payload[1])
    if frame.payload.len > 2:
      frame.closeReason = toString(frame.payload.toOpenArray(2, frame.payload.high))

  (true, frame, totalNeeded, "")

proc buildClientFrame*(opcode: uint8, payload: openArray[byte], fin = true): seq[byte] =
  result = @[]
  let firstByte = (if fin: 0x80'u8 else: 0'u8) or (opcode and 0x0F'u8)
  result.add(firstByte)

  let maskBit = 0x80'u8
  let plen = payload.len
  if plen <= 125:
    result.add(maskBit or uint8(plen))
  elif plen <= 0xFFFF:
    result.add(maskBit or 126'u8)
    result.add(byte((plen shr 8) and 0xFF))
    result.add(byte(plen and 0xFF))
  else:
    result.add(maskBit or 127'u8)
    for shift in countdown(56, 0, 8):
      result.add(byte((uint64(plen) shr shift) and 0xFF'u64))

  let mask = secureRandom(4)
  result.add(mask)
  for i in 0 ..< plen:
    result.add(payload[i] xor mask[i mod 4])

proc closeSocket(ws: WsTransport) =
  if ws.socket != nil:
    try:
      ws.socket.close()
    except CatchableError:
      discard
    ws.socket = nil

  if ws.sslContext != nil:
    try:
      ws.sslContext.destroyContext()
    except CatchableError:
      discard
    ws.sslContext = nil

proc sendControlFrame(ws: WsTransport, opcode: uint8, payload: openArray[byte]): bool =
  if ws.socket == nil:
    return false
  try:
    ws.socket.send(toString(buildClientFrame(opcode, payload)))
    true
  except CatchableError:
    false

proc parseEndpoint(endpoint: string): tuple[ok: bool, scheme: string, host: string, port: int, hostHeader: string, path: string, err: string] =
  let u = parseUri(endpoint)
  let scheme = u.scheme.toLowerAscii()
  if scheme notin ["ws", "wss"]:
    return (false, "", "", 0, "", "", "unsupported websocket scheme")
  if u.hostname.len == 0:
    return (false, "", "", 0, "", "", "missing websocket host")

  let defaultPort = if scheme == "wss": 443 else: 80
  var port = defaultPort
  if u.port.len > 0:
    try:
      port = parseInt(u.port)
    except CatchableError:
      return (false, "", "", 0, "", "", "invalid websocket port")

  var hostHeader = u.hostname
  if port != defaultPort:
    hostHeader.add(":" & $port)

  var path = if u.path.len > 0: u.path else: "/"
  if u.query.len > 0:
    path.add("?" & u.query)
  (true, scheme, u.hostname, port, hostHeader, path, "")

proc open*(ws: WsTransport, endpoint: string): WsTransportResult =
  let parsed = parseEndpoint(endpoint)
  if not parsed.ok:
    return (false, parsed.err)

  ws.endpoint = endpoint
  ws.state = wcsConnecting
  ws.recvBuffer = @[]
  ws.fragmentOpcode = 0
  ws.fragmentBuffer = @[]

  try:
    ws.socket = newSocket(buffered = true)
    connect(ws.socket, parsed.host, Port(parsed.port))

    if parsed.scheme == "wss":
      ws.sslContext = newContext(
        verifyMode = if ws.cfg.tlsVerifyPeer: CVerifyPeer else: CVerifyNone
      )
      ws.sslContext.wrapConnectedSocket(ws.socket, handshakeAsClient, hostname = parsed.host)

    let secKey = createHandshakeKey()
    let request = buildHandshakeRequest(parsed.hostHeader, parsed.path, secKey, ws.cfg)
    ws.socket.send(request)

    let statusLine = ws.socket.recvLine(timeout = ws.cfg.handshakeTimeoutMs)
    if statusLine.len == 0 or " 101 " notin statusLine:
      ws.closeSocket()
      ws.state = wcsDisconnected
      return (false, "websocket handshake failed: " & statusLine)

    var headers = initTable[string, string]()
    while true:
      let line = ws.socket.recvLine(timeout = ws.cfg.handshakeTimeoutMs)
      if line.len == 0:
        ws.closeSocket()
        ws.state = wcsDisconnected
        return (false, "unexpected EOF in websocket handshake headers")
      if line == "\r\n" or line == "\n":
        break
      let idx = line.find(':')
      if idx > 0:
        let key = line[0 ..< idx].strip().toLowerAscii()
        let value = line[idx + 1 .. ^1].strip()
        headers[key] = value

    if headers.getOrDefault("upgrade", "").toLowerAscii() != "websocket":
      ws.closeSocket()
      ws.state = wcsDisconnected
      return (false, "invalid websocket upgrade header")

    let accept = headers.getOrDefault("sec-websocket-accept", "")
    let expected = computeAcceptKey(secKey)
    if accept != expected:
      ws.closeSocket()
      ws.state = wcsDisconnected
      return (false, "invalid websocket accept hash")

    ws.state = wcsOpen
    (true, "")
  except TimeoutError:
    ws.closeSocket()
    ws.state = wcsDisconnected
    (false, "websocket handshake timeout")
  except CatchableError as e:
    ws.closeSocket()
    ws.state = wcsDisconnected
    (false, e.msg)

proc close*(ws: WsTransport) =
  if ws.state == wcsOpen:
    discard ws.sendControlFrame(0x8'u8, @[])
  ws.state = wcsClosing
  ws.closeSocket()
  ws.state = wcsDisconnected

proc sendBinary*(ws: WsTransport, frame: seq[byte]): WsTransportResult =
  if ws.state != wcsOpen or ws.socket == nil:
    return (false, "websocket is not connected")
  try:
    let wrapped = buildClientFrame(0x2'u8, frame)
    ws.socket.send(toString(wrapped))
    (true, "")
  except CatchableError as e:
    ws.state = wcsDisconnected
    ws.closeSocket()
    (false, e.msg)

proc sendText*(ws: WsTransport, payload: string): WsTransportResult =
  if ws.state != wcsOpen or ws.socket == nil:
    return (false, "websocket is not connected")
  try:
    let wrapped = buildClientFrame(0x1'u8, toBytes(payload))
    ws.socket.send(toString(wrapped))
    (true, "")
  except CatchableError as e:
    ws.state = wcsDisconnected
    ws.closeSocket()
    (false, e.msg)

proc recv*(ws: WsTransport, timeoutMs: int): WsTransportRecvResult =
  if ws.state != wcsOpen or ws.socket == nil:
    return (false, @[], "websocket is not connected")

  let started = nowMs()
  let effectiveTimeout = if timeoutMs > 0: timeoutMs else: ws.cfg.recvTimeoutMs
  while true:
    if ws.recvBuffer.len > 0:
      let parsed = parseWsFrame(ws.recvBuffer)
      if parsed.ok:
        if parsed.consumed >= ws.recvBuffer.len:
          ws.recvBuffer = @[]
        else:
          ws.recvBuffer = ws.recvBuffer[parsed.consumed .. ^1]

        let frame = parsed.frame
        case frame.opcode
        of 0x9'u8:
          discard ws.sendControlFrame(0xA'u8, frame.payload)
          continue
        of 0xA'u8:
          continue
        of 0x8'u8:
          ws.state = wcsClosing
          discard ws.sendControlFrame(0x8'u8, @[])
          ws.closeSocket()
          ws.state = wcsDisconnected
          return (false, @[], ErrWsRemoteClosed)
        of 0x0'u8:
          if ws.fragmentOpcode == 0:
            ws.close()
            return (false, @[], "unexpected continuation frame")
          ws.fragmentBuffer.add(frame.payload)
          if frame.fin:
            let payload = ws.fragmentBuffer
            ws.fragmentOpcode = 0
            ws.fragmentBuffer = @[]
            return (true, payload, "")
          continue
        of 0x1'u8, 0x2'u8:
          if frame.fin:
            return (true, frame.payload, "")
          ws.fragmentOpcode = frame.opcode
          ws.fragmentBuffer = frame.payload
          continue
        else:
          continue
      elif parsed.err != ErrWsIncompleteFrame:
        ws.close()
        return (false, @[], parsed.err)

    var remaining = effectiveTimeout
    if timeoutMs > 0:
      let elapsed = int(nowMs() - started)
      remaining = timeoutMs - elapsed
      if remaining <= 0:
        return (false, @[], ErrWsTimeout)

    try:
      let chunk = ws.socket.recv(max(1024, ws.cfg.readChunkSize), timeout = remaining)
      if chunk.len == 0:
        ws.close()
        return (false, @[], ErrWsRemoteClosed)
      ws.recvBuffer.add(toBytes(chunk))
    except TimeoutError:
      return (false, @[], ErrWsTimeout)
    except CatchableError as e:
      ws.close()
      return (false, @[], e.msg)

proc newWsTransport*(cfg: WsTransportConfig = defaultWsTransportConfig()): WsTransport =
  WsTransport(
    cfg: cfg,
    socket: nil,
    sslContext: nil,
    state: wcsDisconnected,
    endpoint: "",
    recvBuffer: @[],
    fragmentOpcode: 0,
    fragmentBuffer: @[]
  )

{.pop.}
