import std/[unittest, json]
import discord/gateway

suite "discord gateway":
  test "ready flow and heartbeat scheduling":
    let g = newDiscordGateway()
    check g.state == gsDisconnected

    g.startConnect(1000)
    check g.state == gsConnecting
    check g.connectStartedAtMs == 1000

    g.onHello(15000)
    check g.heartbeatIntervalMs == 15000
    check g.shouldHeartbeat(1000)

    g.markHeartbeatSent(1000)
    check g.awaitingHeartbeatAck
    check not g.shouldHeartbeat(2000)

    g.markHeartbeatAck(1200)
    check not g.awaitingHeartbeatAck

    g.onDispatch(gdReady, 42, "sess-1")
    check g.state == gsConnected
    check g.sessionId == "sess-1"
    check g.lastSequence == 42

    check g.shouldHeartbeat(17000)

  test "resume and reconnect lifecycle":
    let g = newDiscordGateway()
    g.startConnect(0)
    g.onHello(10000)
    g.onDispatch(gdReady, 5, "sess-2")

    check g.hasResumableSession()
    check g.beginResume(2000)
    check g.state == gsResuming

    g.onDispatch(gdResumed, 7)
    check g.state == gsConnected
    check g.lastSequence == 7

    g.markHeartbeatSent(3000)
    let shortTimeout = GatewayTimeouts(heartbeatAckTimeoutMs: 50, connectTimeoutMs: 1000)
    check not g.shouldReconnect(3040, shortTimeout)
    check g.shouldReconnect(3060, shortTimeout)

    g.markDisconnected("heartbeat timeout")
    check g.state == gsDisconnected
    check g.lastError == "heartbeat timeout"

  test "reconnect backoff and schedule":
    let g = newDiscordGateway()
    check g.computeReconnectDelayMs() == 1000
    discard g.scheduleReconnect(10000)
    check g.reconnectCount == 1
    check g.reconnectAfterMs == 11000
    check not g.shouldAttemptReconnect(10999)
    check g.shouldAttemptReconnect(11000)

    discard g.scheduleReconnect(11000)
    discard g.scheduleReconnect(12000)
    discard g.scheduleReconnect(13000)
    discard g.scheduleReconnect(14000)
    discard g.scheduleReconnect(15000)
    discard g.scheduleReconnect(16000)
    check g.reconnectCount == 7
    check g.computeReconnectDelayMs() == 30000

  test "identify resume and heartbeat payload shapes":
    let identify = identifyPayload("  tok123 ", 513, osName = "darwin", browser = "mautrix-discord", device = "mautrix-discord")
    check identify["op"].getInt() == 2
    check identify["d"]["token"].getStr() == "tok123"
    check identify["d"]["intents"].getInt() == 513
    check identify["d"]["properties"]["os"].getStr() == "darwin"

    let resume = resumePayload(" token ", "sess-9", 99)
    check resume["op"].getInt() == 6
    check resume["d"]["token"].getStr() == "token"
    check resume["d"]["session_id"].getStr() == "sess-9"
    check resume["d"]["seq"].getInt() == 99

    let g = newDiscordGateway()
    g.onDispatch(gdReady, 33, "sess-x")
    let hb = g.heartbeatPayload()
    check hb["op"].getInt() == 1
    check hb["d"].getInt() == 33
