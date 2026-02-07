import std/unittest
import discord/[session, gateway]

suite "discord session":
  test "login and dispatch lifecycle updates gateway":
    let s = newDiscordSession()
    s.login("Bot token-1")
    check s.token == "Bot token-1"
    check s.rest != nil

    let ready = s.handleGatewayPayload("""{"op":0,"s":5,"t":"READY","d":{"session_id":"sess-1"}}""")
    check ready.ok
    check s.gateway.state == gsConnected
    check s.gateway.sessionId == "sess-1"
    check s.gateway.lastSequence == 5

    s.gateway.markHeartbeatSent(1000)
    check s.gateway.awaitingHeartbeatAck
    let ack = s.handleGatewayPayload("""{"op":11,"d":null}""")
    check ack.ok
    check not s.gateway.awaitingHeartbeatAck

    let reconnect = s.handleGatewayPayload("""{"op":7,"d":null}""")
    check reconnect.ok
    check s.gateway.state == gsDisconnected
    check s.gateway.reconnectCount >= 1
