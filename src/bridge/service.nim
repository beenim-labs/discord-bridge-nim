## Bridge lifecycle and wiring for appservice and provisioning shell.

import std/[os, asyncdispatch, asynchttpserver, json, strformat]
import config/config
import appservice/[registration, server]
import provisioning/server as provisioning_server
import directmedia/api as directmedia_api
import database/database
import bridge/runtime
import bridge/main_compat
import common/logging

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
    processedEvents*: int
    processedEphemeral*: int

proc txHealth(svc: DiscordBridgeService): JsonNode =
  result = %*{
    "svc_transactions_processed": svc.processedTransactions,
    "svc_events_processed": svc.processedEvents,
    "svc_ephemeral_processed": svc.processedEphemeral
  }
  if svc.runtime != nil:
    let rt = svc.runtime.health()
    if rt.kind == JObject:
      for k, v in rt:
        result[k] = v

proc ensureRegFileExists(path: string) =
  if not fileExists(path):
    raise newException(IOError, "registration file not found: " & path)

proc handleTransaction(svc: DiscordBridgeService, tx: AppserviceTransaction): Future[void] {.async.} =
  inc svc.processedTransactions
  svc.processedEvents += tx.events.len
  svc.processedEphemeral += tx.ephemeral.len

proc initService*(configPath, registrationPath: string): DiscordBridgeService =
  let cfg = loadConfig(configPath)
  let validation = cfg.validate()
  if not validation.ok:
    raise newException(ValueError, validation.err)

  ensureRegFileExists(registrationPath)
  let reg = readRegistration(registrationPath)
  if reg.hsToken.len == 0 or reg.asToken.len == 0:
    raise newException(ValueError, "registration tokens are missing")

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
    processedEvents: 0,
    processedEphemeral: 0
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
  waitFor svc.appservice.runForever()
