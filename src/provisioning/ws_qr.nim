## Minimal websocket upgrade/send helpers for provisioning QR login.

import std/[asyncdispatch, asynchttpserver, asyncnet, json, strutils]
import discord/ws_transport

type
  ProvisioningWs* = ref object
    client*: AsyncSocket
    closed*: bool

proc bytesToString(data: openArray[byte]): string =
  result = newString(data.len)
  for i, b in data:
    result[i] = char(b)

proc stringToBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ch)

proc hasUpgradeToken(connectionHeader: string): bool =
  for part in connectionHeader.split(','):
    if part.strip().toLowerAscii() == "upgrade":
      return true
  false

proc isWsUpgrade*(req: Request): bool =
  let connection = req.headers.getOrDefault("Connection").toLowerAscii()
  let upgrade = req.headers.getOrDefault("Upgrade").toLowerAscii().strip()
  let secKey = req.headers.getOrDefault("Sec-WebSocket-Key").strip()
  let secVer = req.headers.getOrDefault("Sec-WebSocket-Version").strip()

  hasUpgradeToken(connection) and
  upgrade == "websocket" and
  secKey.len > 0 and
  secVer == "13"

proc buildServerFrame(opcode: uint8, payload: openArray[byte], fin = true): seq[byte] =
  result = @[]
  let first = (if fin: 0x80'u8 else: 0'u8) or (opcode and 0x0F'u8)
  result.add(first)

  let payloadLen = payload.len
  if payloadLen <= 125:
    result.add(uint8(payloadLen))
  elif payloadLen <= 0xFFFF:
    result.add(126'u8)
    result.add(byte((payloadLen shr 8) and 0xFF))
    result.add(byte(payloadLen and 0xFF))
  else:
    result.add(127'u8)
    for shift in countdown(56, 0, 8):
      result.add(byte((uint64(payloadLen) shr shift) and 0xFF'u64))

  for b in payload:
    result.add(b)

proc sendRaw(ws: ProvisioningWs, data: seq[byte]): Future[bool] {.async.} =
  if ws == nil or ws.client == nil or ws.closed:
    return false
  try:
    await ws.client.send(bytesToString(data))
    true
  except CatchableError:
    ws.closed = true
    false

proc sendJson*(ws: ProvisioningWs, payload: JsonNode): Future[bool] {.async.} =
  let frame = buildServerFrame(0x1'u8, stringToBytes($payload))
  await ws.sendRaw(frame)

proc closeWithCode*(ws: ProvisioningWs, code = 1000'u16, reason = ""): Future[void] {.async.} =
  if ws == nil or ws.client == nil or ws.closed:
    return

  var payload: seq[byte] = @[
    byte((code shr 8) and 0xFF'u16),
    byte(code and 0xFF'u16)
  ]
  for ch in reason:
    payload.add(byte(ch))

  discard await ws.sendRaw(buildServerFrame(0x8'u8, payload))
  ws.closed = true
  try:
    ws.client.close()
  except CatchableError:
    discard

proc close*(ws: ProvisioningWs) =
  if ws == nil or ws.client == nil or ws.closed:
    return
  ws.closed = true
  try:
    ws.client.close()
  except CatchableError:
    discard

proc acceptWs*(req: Request, protocol: string): Future[tuple[ok: bool, ws: ProvisioningWs, err: string]] {.async.} =
  if not req.isWsUpgrade():
    return (false, nil, "request is not a websocket upgrade")

  let secKey = req.headers.getOrDefault("Sec-WebSocket-Key").strip()
  if secKey.len == 0:
    return (false, nil, "missing Sec-WebSocket-Key")

  let acceptKey = computeAcceptKey(secKey)
  var response = "HTTP/1.1 101 Switching Protocols\r\n"
  response.add("Upgrade: websocket\r\n")
  response.add("Connection: Upgrade\r\n")
  response.add("Sec-WebSocket-Accept: " & acceptKey & "\r\n")
  if protocol.len > 0:
    response.add("Sec-WebSocket-Protocol: " & protocol & "\r\n")
  response.add("\r\n")

  try:
    await req.client.send(response)
  except CatchableError as e:
    return (false, nil, "failed to complete websocket handshake: " & e.msg)

  (true, ProvisioningWs(client: req.client, closed: false), "")
