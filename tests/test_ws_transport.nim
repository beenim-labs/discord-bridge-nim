import std/[unittest, tables, strutils]
import discord/ws_transport

suite "ws transport":
  test "accept key from handshake key":
    let key = "dGhlIHNhbXBsZSBub25jZQ=="
    check computeAcceptKey(key) == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

  test "build handshake request":
    var cfg = defaultWsTransportConfig()
    cfg.origin = "https://example.com"
    cfg.extraHeaders["X-Test"] = "1"
    let req = buildHandshakeRequest("example.com", "/chat", "abc", cfg)
    check "GET /chat HTTP/1.1" in req
    check "Upgrade: websocket" in req
    check "Sec-WebSocket-Key: abc" in req
    check "Origin: https://example.com" in req
    check "X-Test: 1" in req

  test "frame build and parse text payload":
    let payload = "hello websocket"
    var raw: seq[byte] = @[]
    for ch in payload:
      raw.add(ch.byte)
    let built = buildClientFrame(0x1'u8, raw)
    let parsed = parseWsFrame(built)
    check parsed.ok
    check parsed.consumed == built.len
    check parsed.frame.opcode == 0x1'u8
    var decoded = newString(parsed.frame.payload.len)
    for i, b in parsed.frame.payload:
      decoded[i] = char(b)
    check decoded == payload
