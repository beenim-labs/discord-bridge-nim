import std/[json, unittest]
import discord/events

suite "gateway events":
  test "parse gateway incoming payload":
    let parsed = parseGatewayIncoming("""{"op":0,"s":42,"t":"MESSAGE_CREATE","d":{"id":"1"}}""")
    check parsed.ok
    check parsed.evt.op == 0
    check parsed.evt.seq == 42
    check parsed.evt.eventType == "MESSAGE_CREATE"
    check parsed.evt.data["id"].getStr() == "1"

  test "invalid payload fails":
    let parsed = parseGatewayIncoming("[]")
    check not parsed.ok
