## Discord gateway/session state machine primitives.
## Transport and full payload routing are integrated in later milestones.

import std/[json, strutils]

type
  GatewayState* = enum
    gsDisconnected
    gsConnecting
    gsConnected
    gsResuming

  GatewayDispatch* = enum
    gdUnknown
    gdReady
    gdResumed

  GatewayTimeouts* = object
    heartbeatAckTimeoutMs*: int64
    connectTimeoutMs*: int64

  DiscordGateway* = ref object
    state*: GatewayState
    lastError*: string

    sessionId*: string
    lastSequence*: int64

    heartbeatIntervalMs*: int
    lastHeartbeatSentMs*: int64
    lastHeartbeatAckMs*: int64
    awaitingHeartbeatAck*: bool

    connectStartedAtMs*: int64
    reconnectCount*: int
    reconnectAfterMs*: int64

proc newGatewayTimeouts*(): GatewayTimeouts =
  GatewayTimeouts(
    heartbeatAckTimeoutMs: 45000,
    connectTimeoutMs: 20000
  )

proc newDiscordGateway*(): DiscordGateway =
  DiscordGateway(
    state: gsDisconnected,
    lastError: "",
    sessionId: "",
    lastSequence: 0'i64,
    heartbeatIntervalMs: 0,
    lastHeartbeatSentMs: 0'i64,
    lastHeartbeatAckMs: 0'i64,
    awaitingHeartbeatAck: false,
    connectStartedAtMs: 0'i64,
    reconnectCount: 0,
    reconnectAfterMs: 0'i64
  )

proc resetSession*(g: DiscordGateway) =
  if g == nil:
    return
  g.sessionId = ""
  g.lastSequence = 0'i64

proc startConnect*(g: DiscordGateway, nowMs: int64) =
  g.state = gsConnecting
  g.lastError = ""
  g.connectStartedAtMs = nowMs
  g.awaitingHeartbeatAck = false
  g.lastHeartbeatSentMs = 0
  g.lastHeartbeatAckMs = 0

proc onHello*(g: DiscordGateway, heartbeatIntervalMs: int) =
  if heartbeatIntervalMs <= 0:
    raise newException(ValueError, "heartbeat interval must be > 0")
  g.heartbeatIntervalMs = heartbeatIntervalMs

proc onDispatch*(g: DiscordGateway, dispatchType: GatewayDispatch, seq: int64, sessionId = "") =
  if seq > g.lastSequence:
    g.lastSequence = seq
  case dispatchType
  of gdReady:
    g.state = gsConnected
    g.sessionId = sessionId
    g.reconnectCount = 0
    g.reconnectAfterMs = 0
  of gdResumed:
    g.state = gsConnected
    g.reconnectCount = 0
    g.reconnectAfterMs = 0
  of gdUnknown:
    discard

proc beginResume*(g: DiscordGateway, nowMs: int64): bool =
  if g.sessionId.len == 0:
    return false
  g.state = gsResuming
  g.connectStartedAtMs = nowMs
  true

proc hasResumableSession*(g: DiscordGateway): bool =
  g.sessionId.len > 0

proc markHeartbeatSent*(g: DiscordGateway, nowMs: int64) =
  g.lastHeartbeatSentMs = nowMs
  g.awaitingHeartbeatAck = true

proc markHeartbeatAck*(g: DiscordGateway, nowMs: int64) =
  g.lastHeartbeatAckMs = nowMs
  g.awaitingHeartbeatAck = false

proc shouldHeartbeat*(g: DiscordGateway, nowMs: int64): bool =
  if g.state notin {gsConnecting, gsConnected, gsResuming}:
    return false
  if g.heartbeatIntervalMs <= 0:
    return false
  if g.lastHeartbeatSentMs == 0:
    return true
  (nowMs - g.lastHeartbeatSentMs) >= g.heartbeatIntervalMs.int64

proc shouldReconnect*(g: DiscordGateway, nowMs: int64, timeouts = newGatewayTimeouts()): bool =
  if g.state == gsDisconnected:
    return false
  if g.awaitingHeartbeatAck and g.lastHeartbeatSentMs > 0:
    if nowMs - g.lastHeartbeatSentMs >= timeouts.heartbeatAckTimeoutMs:
      return true
  if g.state in {gsConnecting, gsResuming} and g.connectStartedAtMs > 0:
    if nowMs - g.connectStartedAtMs >= timeouts.connectTimeoutMs:
      return true
  false

proc markDisconnected*(g: DiscordGateway, reason: string) =
  g.state = gsDisconnected
  g.lastError = reason
  g.awaitingHeartbeatAck = false

proc computeReconnectDelayMs*(g: DiscordGateway, baseDelayMs = 1000'i64, maxDelayMs = 30000'i64): int64 =
  let step = min(g.reconnectCount, 6)
  var delay = baseDelayMs shl step
  if delay > maxDelayMs:
    delay = maxDelayMs
  delay

proc scheduleReconnect*(g: DiscordGateway, nowMs: int64, baseDelayMs = 1000'i64, maxDelayMs = 30000'i64): int64 =
  let delay = g.computeReconnectDelayMs(baseDelayMs, maxDelayMs)
  g.reconnectAfterMs = nowMs + delay
  inc g.reconnectCount
  g.reconnectAfterMs

proc shouldAttemptReconnect*(g: DiscordGateway, nowMs: int64): bool =
  g.reconnectAfterMs > 0 and nowMs >= g.reconnectAfterMs

proc heartbeatPayload*(g: DiscordGateway): JsonNode =
  %*{"op": 1, "d": g.lastSequence}

proc identifyPayload*(token: string, intents: int, osName = "linux", browser = "bridge-discord-nim", device = "bridge-discord-nim"): JsonNode =
  let cleanToken = token.strip()
  %*{
    "op": 2,
    "d": {
      "token": cleanToken,
      "intents": intents,
      "properties": {
        "os": osName,
        "browser": browser,
        "device": device
      }
    }
  }

proc resumePayload*(token, sessionId: string, seq: int64): JsonNode =
  %*{
    "op": 6,
    "d": {
      "token": token.strip(),
      "session_id": sessionId,
      "seq": seq
    }
  }
