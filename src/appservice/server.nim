## Native appservice HTTP server with transaction parsing and dispatch.

import std/[asyncdispatch, asynchttpserver, strutils, json, uri, strformat, sets]
import appservice/registration
import config/config
import common/logging

type
  MatrixEvent* = object
    eventId*: string
    roomId*: string
    sender*: string
    eventType*: string
    stateKey*: string
    redacts*: string
    originServerTs*: int64
    content*: JsonNode
    unsigned*: JsonNode

  AppserviceTransaction* = object
    transactionId*: string
    events*: seq[MatrixEvent]
    ephemeral*: seq[MatrixEvent]
    raw*: JsonNode

  TransactionHandler* = proc(tx: AppserviceTransaction): Future[void] {.closure.}
  HealthProvider* = proc(): JsonNode {.closure.}
  CustomRequestHandler* = proc(req: Request): Future[bool] {.closure.}

  AppserviceServer* = ref object
    cfg*: Config
    reg*: Registration

    transactionsSeen*: int
    transactionErrors*: int
    duplicateTransactions*: int
    eventsSeen*: int
    lastTransactionId*: string

    seenTransactions: HashSet[string]
    onTransaction*: TransactionHandler
    extraHealth*: HealthProvider
    onCustomRequest*: CustomRequestHandler

const
  AppTxPrefix = "/_matrix/app/v1/transactions/"
  LegacyTxPrefix = "/transactions/"

proc queryParam(req: Request, name: string): string =
  if req.url.query.len == 0:
    return ""
  for key, val in decodeQuery(req.url.query):
    if key == name:
      return val
  ""

proc isAuthorized(server: AppserviceServer, req: Request): bool =
  let access = queryParam(req, "access_token")
  access.len > 0 and access == server.reg.hsToken

proc jsonResponse(req: Request, code: HttpCode, payload: JsonNode) {.async.} =
  let headers = newHttpHeaders({"Content-Type": "application/json"})
  await req.respond(code, $payload, headers)

proc extractTxnId*(path: string): string =
  if path.startsWith(AppTxPrefix):
    return path[AppTxPrefix.len .. ^1]
  if path.startsWith(LegacyTxPrefix):
    return path[LegacyTxPrefix.len .. ^1]
  ""

proc parseMatrixEvent(node: JsonNode): MatrixEvent =
  MatrixEvent(
    eventId: node{"event_id"}.getStr(""),
    roomId: node{"room_id"}.getStr(""),
    sender: node{"sender"}.getStr(""),
    eventType: node{"type"}.getStr(""),
    stateKey: node{"state_key"}.getStr(""),
    redacts: node{"redacts"}.getStr(""),
    originServerTs: node{"origin_server_ts"}.getInt(0),
    content: if node.hasKey("content"): node["content"] else: newJObject(),
    unsigned: if node.hasKey("unsigned"): node["unsigned"] else: newJObject()
  )

proc parseEventList(root: JsonNode, key: string): seq[MatrixEvent] =
  result = @[]
  if not root.hasKey(key):
    return
  let arr = root[key]
  if arr.kind != JArray:
    return
  for item in arr:
    if item.kind == JObject:
      result.add(parseMatrixEvent(item))

proc parseTransaction*(transactionId, body: string): AppserviceTransaction =
  let root = parseJson(body)
  result = AppserviceTransaction(
    transactionId: transactionId,
    events: parseEventList(root, "events"),
    ephemeral: parseEventList(root, "de.sorunome.msc2409.ephemeral"),
    raw: root
  )

proc userExists(server: AppserviceServer, userId: string): bool =
  if userId == "@" & server.reg.senderLocalpart & ":" & server.cfg.homeserver.domain:
    return true
  if userId.startsWith("@" & server.cfg.appservice.id & "_") and userId.endsWith(":" & server.cfg.homeserver.domain):
    return true
  false

proc roomAliasExists(server: AppserviceServer, roomAlias: string): bool =
  roomAlias.startsWith("#" & server.cfg.appservice.id & "_") and roomAlias.endsWith(":" & server.cfg.homeserver.domain)

proc healthPayload(server: AppserviceServer): JsonNode =
  result = %*{
    "status": "ok",
    "bridge": "discord-bridge-nim",
    "transactions_seen": server.transactionsSeen,
    "transaction_errors": server.transactionErrors,
    "duplicate_transactions": server.duplicateTransactions,
    "events_seen": server.eventsSeen,
    "last_transaction_id": server.lastTransactionId
  }

  if server.extraHealth != nil:
    let ext = server.extraHealth()
    if ext.kind == JObject:
      for k, v in ext:
        result[k] = v

proc dispatchTransaction(server: AppserviceServer, tx: AppserviceTransaction): Future[void] {.async.} =
  if server.onTransaction == nil:
    return
  await server.onTransaction(tx)

proc handleTransactionRequest(server: AppserviceServer, req: Request) {.async.} =
  if not server.isAuthorized(req):
    await jsonResponse(req, Http401, %*{"errcode": "M_UNAUTHORIZED", "error": "Invalid appservice token"})
    return

  let txId = extractTxnId(req.url.path)
  if txId.len == 0:
    await jsonResponse(req, Http400, %*{"errcode": "M_BAD_JSON", "error": "Missing transaction id"})
    return

  if txId in server.seenTransactions:
    inc server.duplicateTransactions
    await jsonResponse(req, Http200, %*{})
    return

  let body = req.body
  var parsed = AppserviceTransaction(transactionId: "", events: @[], ephemeral: @[], raw: newJObject())
  try:
    parsed = parseTransaction(txId, body)
  except CatchableError as e:
    inc server.transactionErrors
    await jsonResponse(req, Http400, %*{"errcode": "M_BAD_JSON", "error": "Invalid transaction JSON: " & e.msg})
    return

  server.seenTransactions.incl(txId)
  inc server.transactionsSeen
  server.eventsSeen += parsed.events.len + parsed.ephemeral.len
  server.lastTransactionId = txId

  try:
    await server.dispatchTransaction(parsed)
    await jsonResponse(req, Http200, %*{})
  except CatchableError as e:
    inc server.transactionErrors
    err("Transaction handler failed for " & txId & ": " & e.msg)
    await jsonResponse(req, Http500, %*{"errcode": "M_UNKNOWN", "error": "Transaction handling failed"})

proc handleRequest(server: AppserviceServer, req: Request) {.async.} =
  let p = req.url.path

  if req.reqMethod == HttpGet and (p == "/health" or p == "/_matrix/app/v1/ping"):
    await jsonResponse(req, Http200, server.healthPayload())
    return

  if (req.reqMethod == HttpPut or req.reqMethod == HttpPost) and
     (p.startsWith(AppTxPrefix) or p.startsWith(LegacyTxPrefix)):
    await server.handleTransactionRequest(req)
    return

  if req.reqMethod == HttpGet and p.startsWith("/_matrix/app/v1/users/"):
    if not server.isAuthorized(req):
      await jsonResponse(req, Http401, %*{"errcode": "M_UNAUTHORIZED", "error": "Invalid appservice token"})
      return
    let userId = decodeUrl(p["/_matrix/app/v1/users/".len .. ^1])
    if server.userExists(userId):
      await jsonResponse(req, Http200, %*{})
    else:
      await jsonResponse(req, Http404, %*{"errcode": "M_NOT_FOUND", "error": "User not known"})
    return

  if req.reqMethod == HttpGet and p.startsWith("/_matrix/app/v1/rooms/"):
    if not server.isAuthorized(req):
      await jsonResponse(req, Http401, %*{"errcode": "M_UNAUTHORIZED", "error": "Invalid appservice token"})
      return
    let roomAlias = decodeUrl(p["/_matrix/app/v1/rooms/".len .. ^1])
    if server.roomAliasExists(roomAlias):
      await jsonResponse(req, Http200, %*{})
    else:
      await jsonResponse(req, Http404, %*{"errcode": "M_NOT_FOUND", "error": "Room alias not known"})
    return

  if server.onCustomRequest != nil:
    try:
      let handled = await server.onCustomRequest(req)
      if handled:
        return
    except CatchableError as e:
      err("Custom request handler failed: " & e.msg)
      await jsonResponse(req, Http500, %*{"errcode": "M_UNKNOWN", "error": "Custom handler failed"})
      return

  await jsonResponse(req, Http404, %*{"errcode": "M_NOT_FOUND", "error": "Unknown endpoint"})

proc runForever*(server: AppserviceServer) {.async.} =
  let httpServer = newAsyncHttpServer()
  info(fmt"Appservice listening on {server.cfg.appservice.hostname}:{server.cfg.appservice.port}")
  let cbRaw = proc(req: Request): Future[void] {.async.} =
    await server.handleRequest(req)
  let cb = cast[proc(request: Request): Future[void] {.closure, gcsafe.}](cbRaw)
  await httpServer.serve(
    Port(server.cfg.appservice.port),
    cb,
    address = server.cfg.appservice.hostname
  )

proc newAppserviceServer*(cfg: Config, reg: Registration): AppserviceServer =
  AppserviceServer(
    cfg: cfg,
    reg: reg,
    transactionsSeen: 0,
    transactionErrors: 0,
    duplicateTransactions: 0,
    eventsSeen: 0,
    lastTransactionId: "",
    seenTransactions: initHashSet[string]()
  )
