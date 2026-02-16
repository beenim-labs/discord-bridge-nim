## Live remoteauth login flow (networked) built on packet/state core.

import std/[asyncdispatch, httpclient, json, strutils, tables, times]
import remoteauth/[client, crypto, user]
import discord/ws_transport

type
  RemoteAuthFailureKind* = enum
    rafNone
    rafPrepare
    rafConnection
    rafLogin
    rafPostLogin

  RemoteAuthLoginResult* = object
    ok*: bool
    user*: RemoteAuthUser
    err*: string
    failure*: RemoteAuthFailureKind

  RemoteAuthEndpoints* = object
    websocketUrl*: string
    apiBaseUrl*: string

  TicketLoginFn* = proc(ticket: string): tuple[ok: bool, encryptedToken: string, err: string] {.closure, gcsafe.}

const
  DefaultRemoteAuthApiBase* = "https://discord.com/api/v10"
  DefaultRemoteAuthTimeoutMs* = 180_000
  DroidUserAgent* = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

proc nowMs(): int64 =
  getTime().toUnix().int64 * 1000

proc bytesToString(data: openArray[byte]): string =
  result = newString(data.len)
  for i, b in data:
    result[i] = char(b)

proc fail(kind: RemoteAuthFailureKind, err: string): RemoteAuthLoginResult =
  RemoteAuthLoginResult(ok: false, user: RemoteAuthUser(), err: err, failure: kind)

proc success(user: RemoteAuthUser): RemoteAuthLoginResult =
  RemoteAuthLoginResult(ok: true, user: user, err: "", failure: rafNone)

proc defaultRemoteAuthEndpoints*(): RemoteAuthEndpoints =
  RemoteAuthEndpoints(
    websocketUrl: DefaultRemoteAuthUrl,
    apiBaseUrl: DefaultRemoteAuthApiBase
  )

proc droidWsHeaders(): Table[string, string] =
  result = initTable[string, string]()
  result["User-Agent"] = DroidUserAgent
  result["Origin"] = "https://discord.com"
  result["Accept-Language"] = "en-US,en;q=0.9"
  result["Pragma"] = "no-cache"
  result["Cache-Control"] = "no-cache"
  result["Accept-Encoding"] = "gzip, deflate, br"

proc loginWithTicket(apiBaseUrl, ticket: string): tuple[ok: bool, encryptedToken: string, err: string] =
  var cli = newHttpClient()
  defer:
    try:
      cli.close()
    except CatchableError:
      discard
  cli.headers = newHttpHeaders({
    "User-Agent": DroidUserAgent,
    "Origin": "https://discord.com",
    "Accept": "*/*",
    "Accept-Language": "en-US,en;q=0.9",
    "Content-Type": "application/json"
  })

  let endpoint = apiBaseUrl.strip(chars = {'/'}) & "/users/@me/remote-auth/login"
  try:
    let resp = cli.request(endpoint, HttpPost, body = $(%*{"ticket": ticket}))
    if int(resp.code) < 200 or int(resp.code) > 299:
      return (false, "", "remote auth ticket login returned HTTP " & $int(resp.code))

    let raw = resp.body
    if raw.len == 0:
      return (false, "", "remote auth ticket login returned empty body")
    let parsed = parseJson(raw)
    if parsed.kind != JObject or not parsed.hasKey("encrypted_token") or parsed["encrypted_token"].kind != JString:
      return (false, "", "remote auth ticket login response missing encrypted_token")
    (true, parsed["encrypted_token"].getStr(), "")
  except CatchableError as e:
    (false, "", "remote auth ticket login failed: " & e.msg)

proc runRemoteAuthLoginWith*(
    timeoutMs: int,
    onQrCode: proc(url: string) {.closure, gcsafe.},
    endpoints: RemoteAuthEndpoints = defaultRemoteAuthEndpoints(),
    ticketLoginFn: TicketLoginFn = nil
): Future[RemoteAuthLoginResult] {.async, gcsafe.} =
  let created = newRemoteAuthKeypair()
  if not created.ok:
    return fail(rafPrepare, created.err)
  let keypair = created.kp
  defer:
    keypair.close()

  let state = newRemoteAuthClient()
  state.url = endpoints.websocketUrl
  state.setEncodedPublicKey(keypair.encodedPublicKeyRawStd())
  state.setDecryptor(proc(payload: string): tuple[ok: bool, plaintext: string, err: string] =
    keypair.decryptPayload(payload)
  )

  var wsCfg = defaultWsTransportConfig()
  wsCfg.userAgent = DroidUserAgent
  wsCfg.origin = "https://discord.com"
  wsCfg.extraHeaders = droidWsHeaders()
  wsCfg.recvTimeoutMs = 250
  let ws = newWsTransport(wsCfg)
  defer:
    ws.close()

  let opened = ws.open(endpoints.websocketUrl)
  if not opened.ok:
    return fail(rafConnection, opened.err)

  let loginWithTicketFn =
    if ticketLoginFn != nil:
      ticketLoginFn
    else:
      proc(ticket: string): tuple[ok: bool, encryptedToken: string, err: string] =
        loginWithTicket(endpoints.apiBaseUrl, ticket)

  let globalTimeout = if timeoutMs > 0: timeoutMs else: DefaultRemoteAuthTimeoutMs
  let startedAt = nowMs()
  var protocolDeadline = startedAt + int64(globalTimeout)
  var helloDeadline = 0'i64
  var nextHeartbeatAt = 0'i64
  var qrSent = false

  while true:
    let now = nowMs()
    if now >= protocolDeadline:
      return fail(rafLogin, "remote auth timed out")
    if helloDeadline > 0 and now >= helloDeadline:
      return fail(rafLogin, "Timed out after " & $state.timeoutMs & "ms")

    if state.heartbeatIntervalMs > 0:
      if nextHeartbeatAt == 0'i64:
        nextHeartbeatAt = now + int64(state.heartbeatIntervalMs)
      elif now >= nextHeartbeatAt:
        let hb = state.nextHeartbeatPacket()
        if not hb.ok:
          return fail(rafLogin, hb.err)
        let sent = ws.sendText(hb.packetJson)
        if not sent.ok:
          return fail(rafConnection, sent.err)
        nextHeartbeatAt = now + int64(state.heartbeatIntervalMs)

    let recv = ws.recv(200)
    if not recv.ok:
      if recv.err == ErrWsTimeout:
        await sleepAsync(10)
        continue
      return fail(rafConnection, recv.err)
    if recv.frame.len == 0:
      continue

    let payload = bytesToString(recv.frame)
    let processed = state.processServerPacket(payload)
    if not processed.ok:
      return fail(rafLogin, processed.err)

    if helloDeadline == 0 and state.timeoutMs > 0:
      helloDeadline = nowMs() + int64(state.timeoutMs)
      if helloDeadline < protocolDeadline:
        protocolDeadline = helloDeadline

    case processed.action.kind
    of raaSendPacket:
      let sent = ws.sendText(processed.action.outboundJson)
      if not sent.ok:
        return fail(rafConnection, sent.err)
    of raaQrCode:
      if not qrSent and onQrCode != nil:
        qrSent = true
        onQrCode(processed.action.qrUrl)
    of raaTicketReceived:
      let loggedIn = loginWithTicketFn(processed.action.ticket)
      if not loggedIn.ok:
        return fail(rafLogin, loggedIn.err)
      let decrypted = keypair.decryptPayload(loggedIn.encryptedToken)
      if not decrypted.ok:
        return fail(rafLogin, decrypted.err)

      var updated = state.user
      updated.token = decrypted.plaintext
      return success(updated)
    of raaCancel:
      return fail(rafLogin, "remote auth login canceled")
    of raaNoop, raaUserUpdated, raaHeartbeatAck:
      discard

proc runRemoteAuthLogin*(
    timeoutMs: int,
    onQrCode: proc(url: string) {.closure, gcsafe.}
): Future[RemoteAuthLoginResult] {.async, gcsafe.} =
  await runRemoteAuthLoginWith(timeoutMs, onQrCode)
