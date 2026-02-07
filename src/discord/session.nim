## Discord session lifecycle around websocket gateway and REST primitives.

import std/[json, times]
import discord/[gateway, ws_transport, events, rest_client]

type
  DispatchHandler* = proc(evt: GatewayIncoming) {.gcsafe, closure.}

  DiscordSession* = ref object
    token*: string
    gatewayUrl*: string
    intents*: int
    connected*: bool
    lastError*: string

    gateway*: DiscordGateway
    ws*: WsTransport
    rest*: DiscordRestClient

    onDispatch*: DispatchHandler

const
  DefaultGatewayUrl* = "wss://gateway.discord.gg/?v=10&encoding=json"

proc nowMs(): int64 =
  getTime().toUnix().int64 * 1000

proc bytesToString(data: seq[byte]): string =
  result = newString(data.len)
  for i, b in data:
    result[i] = char(b)

proc newDiscordSession*(gatewayUrl = DefaultGatewayUrl): DiscordSession =
  DiscordSession(
    token: "",
    gatewayUrl: gatewayUrl,
    intents: 0,
    connected: false,
    lastError: "",
    gateway: newDiscordGateway(),
    ws: newWsTransport(),
    rest: nil,
    onDispatch: nil
  )

proc login*(s: DiscordSession, token: string) =
  s.token = token
  s.rest = newDiscordRestClient(token)
  s.lastError = ""

proc disconnect*(s: DiscordSession, reason = "manual disconnect") =
  if s.ws != nil:
    s.ws.close()
  s.gateway.markDisconnected(reason)
  s.connected = false
  s.lastError = reason

proc sendIdentify(s: DiscordSession): tuple[ok: bool, err: string] =
  let payload = identifyPayload(s.token, s.intents)
  s.ws.sendText($payload)

proc sendResume(s: DiscordSession): tuple[ok: bool, err: string] =
  let payload = resumePayload(s.token, s.gateway.sessionId, s.gateway.lastSequence)
  s.ws.sendText($payload)

proc connect*(s: DiscordSession, intents: int): tuple[ok: bool, err: string] =
  if s.token.len == 0:
    return (false, "token is required")
  s.intents = intents
  s.gateway.startConnect(nowMs())

  let opened = s.ws.open(s.gatewayUrl)
  if not opened.ok:
    s.lastError = opened.err
    s.gateway.markDisconnected(opened.err)
    return (false, opened.err)

  s.connected = true
  s.lastError = ""
  (true, "")

proc handleGatewayPayload*(s: DiscordSession, payload: string): tuple[ok: bool, err: string] =
  let parsed = parseGatewayIncoming(payload)
  if not parsed.ok:
    s.lastError = parsed.err
    return (false, parsed.err)

  let evt = parsed.evt
  case evt.op
  of ord(goHello):
    let interval = if evt.data.kind == JObject and evt.data.hasKey("heartbeat_interval"):
      evt.data["heartbeat_interval"].getInt()
    else:
      0
    s.gateway.onHello(interval)
    let resumed = s.gateway.beginResume(nowMs())
    let sent = if resumed: s.sendResume() else: s.sendIdentify()
    if not sent.ok:
      s.lastError = sent.err
      return (false, sent.err)
  of ord(goHeartbeatAck):
    s.gateway.markHeartbeatAck(nowMs())
  of ord(goDispatch):
    case evt.eventType
    of "READY":
      let sid = if evt.data.kind == JObject and evt.data.hasKey("session_id"): evt.data["session_id"].getStr() else: ""
      s.gateway.onDispatch(gdReady, evt.seq, sid)
    of "RESUMED":
      s.gateway.onDispatch(gdResumed, evt.seq)
    else:
      s.gateway.onDispatch(gdUnknown, evt.seq)
    if s.onDispatch != nil:
      s.onDispatch(evt)
  of ord(goReconnect):
    s.gateway.markDisconnected("server requested reconnect")
    discard s.gateway.scheduleReconnect(nowMs())
  of ord(goInvalidSession):
    s.gateway.markDisconnected("invalid session")
    s.gateway.resetSession()
    discard s.gateway.scheduleReconnect(nowMs())
  else:
    discard

  (true, "")

proc pollOnce*(s: DiscordSession, timeoutMs = 50): tuple[ok: bool, processed: bool, err: string] =
  if not s.connected:
    return (false, false, "session is not connected")

  let now = nowMs()
  if s.gateway.shouldHeartbeat(now):
    s.gateway.markHeartbeatSent(now)
    let hb = s.ws.sendText($s.gateway.heartbeatPayload())
    if not hb.ok:
      s.lastError = hb.err
      s.disconnect(hb.err)
      return (false, false, hb.err)

  let recv = s.ws.recv(timeoutMs)
  if not recv.ok:
    if recv.err == ErrWsTimeout:
      if s.gateway.shouldReconnect(nowMs()):
        s.disconnect("heartbeat/connect timeout")
        return (false, false, "reconnect required")
      return (true, false, "")
    s.disconnect(recv.err)
    return (false, false, recv.err)

  if recv.frame.len == 0:
    return (true, false, "")

  let payload = bytesToString(recv.frame)
  let handled = s.handleGatewayPayload(payload)
  if not handled.ok:
    return (false, false, handled.err)
  (true, true, "")
