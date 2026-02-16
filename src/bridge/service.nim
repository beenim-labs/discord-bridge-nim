## Bridge lifecycle and wiring for appservice and provisioning shell.

import std/[os, asyncdispatch, asynchttpserver, json, sets, strformat, strutils, uri]
import config/config
import appservice/[registration, server]
import provisioning/server as provisioning_server
import directmedia/api as directmedia_api
import database/[database, entities, store]
import bridge/runtime
import bridge/main_compat
import common/logging
import discord/rest_client

type
  DiscordBridgeService* = ref object
    cfg*: Config
    reg*: Registration
    db*: BridgeDb
    runtime*: DiscordBridgeRuntime
    compat*: DiscordBridgeCompat
    appservice*: AppserviceServer
    provisioning*: provisioning_server.ProvisioningApi
    directMedia*: directmedia_api.DirectMediaApi

    processedTransactions*: int
    duplicateTransactions*: int
    processedEvents*: int
    processedEphemeral*: int
    failedEvents*: int
    seenTransactions: HashSet[string]

proc txHealth(svc: DiscordBridgeService): JsonNode =
  result = %*{
    "svc_transactions_processed": svc.processedTransactions,
    "svc_transactions_duplicates": svc.duplicateTransactions,
    "svc_events_processed": svc.processedEvents,
    "svc_ephemeral_processed": svc.processedEphemeral,
    "svc_events_failed": svc.failedEvents
  }
  if svc.runtime != nil:
    let rt = svc.runtime.health()
    if rt.kind == JObject:
      for k, v in rt:
        result[k] = v

proc ensureRegFileExists(path: string) =
  if not fileExists(path):
    raise newException(IOError, "registration file not found: " & path)

proc parseCommandBody(event: MatrixEvent): string =
  if event.content.isNil or event.content.kind != JObject:
    return ""
  event.content{"body"}.getStr("").strip()

proc parseReplyTargetEventId(event: MatrixEvent): string =
  if event.content.isNil or event.content.kind != JObject:
    return ""
  let relatesTo = event.content{"m.relates_to"}
  if relatesTo.isNil or relatesTo.kind != JObject:
    return ""
  let inReplyTo = relatesTo{"m.in_reply_to"}
  if inReplyTo.isNil or inReplyTo.kind != JObject:
    return ""
  inReplyTo{"event_id"}.getStr("").strip()

proc parseDiscordFallbackMessageId(eventId: string): tuple[ok: bool, discordId: string] =
  const Prefix = "$discord_fallback_"
  let trimmed = eventId.strip()
  if not trimmed.startsWith(Prefix):
    return (false, "")
  let remainder = trimmed[Prefix.len .. ^1]
  let sepIdx = remainder.find('_')
  if sepIdx <= 0:
    return (false, "")
  let candidate = remainder[0 ..< sepIdx]
  if candidate.len == 0 or not candidate.allCharsInSet({'0'..'9'}):
    return (false, "")
  (true, candidate)

proc resolveDiscordReplyMessageId(
    svc: DiscordBridgeService,
    key: PortalKey,
    replyEventId: string
): tuple[discordMessageId: string, mode: string] =
  let trimmed = replyEventId.strip()
  if trimmed.len == 0:
    return ("", "none")
  let mapped = svc.db.getMessageByMXID(key, trimmed)
  if mapped.found and mapped.rec.discordId.len > 0:
    return (mapped.rec.discordId, "db")
  let fallback = parseDiscordFallbackMessageId(trimmed)
  if fallback.ok:
    return (fallback.discordId, "fallback-id")
  ("", "unresolved")

proc handleLoginTokenCommand(svc: DiscordBridgeService, event: MatrixEvent): bool =
  let body = event.parseCommandBody()
  if body.len == 0:
    return false
  let lowered = body.toLowerAscii()
  if not lowered.startsWith("login-token "):
    return false

  let parts = body.splitWhitespace()
  if parts.len < 3:
    return true
  let token = parts[^1].strip()
  if token.len == 0:
    return true

  let found = svc.runtime.users.getByMXID(event.sender, createIfMissing = true)
  var rec = found.rec
  rec.discordToken = token
  svc.runtime.users.upsert(rec)
  if svc.runtime.userStartup != nil:
    svc.runtime.userStartup.startUsers()
  true

proc relayRoomMessageToDiscord(svc: DiscordBridgeService, event: MatrixEvent) =
  if event.eventType != "m.room.message":
    return
  if event.roomId.len == 0:
    return
  var message = event.parseCommandBody()
  let replyEventId = parseReplyTargetEventId(event)
  var mediaUrl = ""
  if event.content.kind == JObject:
    mediaUrl = event.content{"url"}.getStr("").strip()

  let portal = svc.db.getPortalByMXID(event.roomId)
  if not portal.found or portal.rec.key.channelId.len == 0:
    return
  if portal.rec.portalType == 1 and portal.rec.blocked:
    warn(fmt"Blocked Discord DM relay suppressed: room={event.roomId} channel={portal.rec.key.channelId}")
    return

  let sender = svc.runtime.users.getByMXID(event.sender, createIfMissing = false)
  if not sender.found or sender.rec.discordToken.len == 0:
    return

  let rest = newDiscordRestClient(sender.rec.discordToken)
  defer:
    rest.close()
  let replyResolution = svc.resolveDiscordReplyMessageId(portal.rec.key, replyEventId)
  if replyEventId.len > 0:
    let hasReference = if replyResolution.discordMessageId.len > 0: "1" else: "0"
    if replyResolution.mode == "unresolved":
      warn(fmt"[REPLY-BRIDGE] unresolved room={event.roomId} target_event={replyEventId} mapping={replyResolution.mode} has_reference=0")
    else:
      info(fmt"[REPLY-BRIDGE] resolved room={event.roomId} target_event={replyEventId} mapping={replyResolution.mode} has_reference={hasReference}")
  if mediaUrl.startsWith("file://"):
    let encodedPath = mediaUrl["file://".len .. ^1]
    let localPath = decodeUrl(encodedPath).strip()
    let sent = rest.createMessageWithFile(
      portal.rec.key.channelId,
      message,
      localPath,
      replyResolution.discordMessageId
    )
    if not sent.ok:
      inc svc.failedEvents
      warn(fmt"Failed to relay Matrix file to Discord channel {portal.rec.key.channelId}: status={sent.status} err={sent.err}")
    return

  if mediaUrl.len > 0:
    if message.len == 0:
      message = mediaUrl
    elif mediaUrl notin message:
      message = message & "\n" & mediaUrl

  if message.len == 0:
    return

  var payload = %*{"content": message}
  if replyResolution.discordMessageId.len > 0:
    payload["message_reference"] = %*{
      "message_id": replyResolution.discordMessageId,
      "channel_id": portal.rec.key.channelId,
      "fail_if_not_exists": false
    }
  let sent = rest.createMessage(portal.rec.key.channelId, payload)
  if not sent.ok:
    inc svc.failedEvents
    warn(fmt"Failed to relay Matrix message to Discord channel {portal.rec.key.channelId}: status={sent.status} err={sent.err}")

proc handleTransaction(svc: DiscordBridgeService, tx: AppserviceTransaction): Future[void] {.async.} =
  if tx.transactionId in svc.seenTransactions:
    inc svc.duplicateTransactions
    return
  svc.seenTransactions.incl(tx.transactionId)
  inc svc.processedTransactions
  svc.processedEvents += tx.events.len
  svc.processedEphemeral += tx.ephemeral.len

  for event in tx.events:
    if event.sender.len == 0:
      continue
    if event.sender == "@" & svc.reg.senderLocalpart & ":" & svc.cfg.homeserver.domain:
      continue
    if event.eventType != "m.room.message":
      continue
    if svc.handleLoginTokenCommand(event):
      continue
    svc.relayRoomMessageToDiscord(event)

proc initService*(configPath, registrationPath: string): DiscordBridgeService =
  let cfg = loadConfig(configPath)
  let validation = cfg.validate()
  if not validation.ok:
    raise newException(ValueError, validation.err)

  ensureRegFileExists(registrationPath)
  let reg = readRegistration(registrationPath)
  if reg.hsToken.len == 0 or reg.asToken.len == 0:
    raise newException(ValueError, "registration tokens are missing")
  if cfg.bridge.provisioning.sharedSecret.len == 0 or cfg.bridge.provisioning.sharedSecret == "disable":
    raise newException(ValueError, "bridge.provisioning.shared_secret must be configured")

  let db = openBridgeDb(cfg.appservice.database.uri, cfg.appservice.database.dbType)
  let runtime = newDiscordBridgeRuntime(cfg, db)
  let compat = newDiscordBridgeCompat(cfg, runtime)
  let asServer = newAppserviceServer(cfg, reg)
  let provisioning = provisioning_server.newProvisioningApi(cfg, runtime)
  let directMedia = directmedia_api.newDirectMediaApi(cfg, db)

  var svc = DiscordBridgeService(
    cfg: cfg,
    reg: reg,
    db: db,
    runtime: runtime,
    compat: compat,
    appservice: asServer,
    provisioning: provisioning,
    directMedia: directMedia,
    processedTransactions: 0,
    duplicateTransactions: 0,
    processedEvents: 0,
    processedEphemeral: 0,
    failedEvents: 0,
    seenTransactions: initHashSet[string]()
  )

  svc.appservice.onTransaction = proc(tx: AppserviceTransaction): Future[void] {.async.} =
    await svc.handleTransaction(tx)

  svc.appservice.extraHealth = proc(): JsonNode =
    svc.txHealth()

  svc.appservice.onCustomRequest = proc(req: Request): Future[bool] {.async.} =
    if svc.provisioning != nil:
      if await svc.provisioning.handle(req):
        return true
    if svc.directMedia != nil:
      if await svc.directMedia.handle(req):
        return true
    false

  svc

proc close*(svc: DiscordBridgeService) =
  if svc == nil:
    return
  if svc.runtime != nil:
    svc.runtime.stop()
  if svc.db != nil:
    svc.db.close()

proc run*(svc: DiscordBridgeService) =
  if svc.runtime != nil:
    svc.runtime.start()
  info(fmt"Starting bridge-discord-nim as {svc.cfg.appservice.id} on {svc.cfg.appservice.hostname}:{svc.cfg.appservice.port}")
  if svc.provisioning != nil:
    asyncCheck (proc() {.async.} =
      await sleepAsync(0)
      try:
        svc.provisioning.resumePersistedDiscordSessions()
      except CatchableError as e:
        warn("[provisioning] startup resume crashed: " & e.msg)
    )()
  waitFor svc.appservice.runForever()
