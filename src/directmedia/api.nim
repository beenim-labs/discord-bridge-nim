## Direct media route surface for Matrix media download compatibility.

import std/[asynchttpserver, asyncdispatch, httpcore, json, locks, openssl, strutils, tables, times, uri]
import config/config
import database/[database, store]
import directmedia/media_id

type
  RespError* = object
    code*: string
    message*: string
    status*: HttpCode

  AttachmentCacheValue* = object
    url*: string
    expiry*: Time

  DirectMediaResult* = object
    handled*: bool
    code*: HttpCode
    body*: string
    headers*: HttpHeaders

  DirectMediaApi* = ref object
    cfg*: Config
    db*: BridgeDb
    signatureKey*: array[32, byte]
    serverName*: string
    allowProxy*: bool

    cacheLock: Lock
    attachmentCache: Table[AttachmentCacheKey, AttachmentCacheValue]

proc error*(re: RespError): string =
  re.message

type
  RouteKind = enum
    rkNone
    rkDownload
    rkUploadNotSupported
    rkPreviewURLNotSupported
    rkVersion
    rkUnknown
    rkUnsupportedMethod

  RouteInfo = object
    kind: RouteKind
    isFederation: bool
    serverName: string
    mediaID: string
    fileName: string

const
  ErrCodeNotFound = "M_NOT_FOUND"
  ErrCodeUnrecognized = "M_UNRECOGNIZED"

proc sha256Bytes(data: string): array[32, byte] =
  result = default(array[32, byte])
  let ctx = EVP_MD_CTX_create()
  if ctx.isNil:
    return
  defer:
    EVP_MD_CTX_destroy(ctx)

  if EVP_DigestInit_ex(ctx, EVP_sha256()) != 1:
    return
  if data.len > 0 and EVP_DigestUpdate(ctx, unsafeAddr data[0], cuint(data.len)) != 1:
    return

  var digest: array[64, byte] = default(array[64, byte])
  var digestLen: cuint = 0
  if EVP_DigestFinal_ex(ctx, addr digest[0], addr digestLen) != 1:
    return
  for i in 0 ..< min(int(digestLen), 32):
    result[i] = digest[i]

proc errJson(code, message: string): string =
  $(%*{
    "errcode": code,
    "error": message
  })

proc splitPath(path: string): seq[string] =
  result = @[]
  for part in path.split('/'):
    if part.len > 0:
      result.add(part)

proc hasExpiry(t: Time): bool =
  t.toUnix() > 0

proc parseExpiryTS*(rawUrl: string): tuple[ok: bool, expiry: Time] =
  try:
    let parsed = parseUri(rawUrl)
    for key, val in decodeQuery(parsed.query):
      if key == "ex" and val.len > 0:
        try:
          let ts = int64(parseHexInt(val))
          let nowTs = getTime().toUnix()
          if ts > nowTs and ts < nowTs + 365'i64 * 24'i64 * 3600'i64:
            return (true, fromUnix(ts))
        except CatchableError:
          discard
  except CatchableError:
    discard
  (false, fromUnix(0))

proc toHexLower(data: openArray[byte]): string =
  const hexChars = "0123456789abcdef"
  result = newString(data.len * 2)
  var pos = 0
  for b in data:
    result[pos] = hexChars[int((b shr 4) and 0x0F'u8)]
    result[pos + 1] = hexChars[int(b and 0x0F'u8)]
    pos += 2

proc parseRoute(reqMethod: HttpMethod, path: string): RouteInfo =
  let parts = splitPath(path)
  if parts.len == 0:
    return RouteInfo(kind: rkNone)

  # /_matrix/federation/v1/*
  if parts.len >= 3 and parts[0] == "_matrix" and parts[1] == "federation" and parts[2] == "v1":
    if parts.len == 4 and parts[3] == "version":
      if reqMethod == HttpGet:
        return RouteInfo(kind: rkVersion, isFederation: true)
      return RouteInfo(kind: rkUnsupportedMethod, isFederation: true)

    if parts.len == 6 and parts[3] == "media" and parts[4] == "download":
      if reqMethod == HttpGet:
        return RouteInfo(kind: rkDownload, isFederation: true, mediaID: parts[5])
      return RouteInfo(kind: rkUnsupportedMethod, isFederation: true)
    return RouteInfo(kind: rkUnknown, isFederation: true)

  # /_matrix/media/{v1|v3|r0}/*
  if parts.len >= 4 and parts[0] == "_matrix" and parts[1] == "media" and parts[2] in ["v1", "v3", "r0"]:
    if parts[3] == "download":
      if parts.len in [6, 7]:
        if reqMethod == HttpGet:
          return RouteInfo(
            kind: rkDownload,
            serverName: parts[4],
            mediaID: parts[5],
            fileName: if parts.len == 7: parts[6] else: ""
          )
        return RouteInfo(kind: rkUnsupportedMethod)
      return RouteInfo(kind: rkUnknown)

    if parts[3] == "thumbnail":
      if parts.len == 6:
        if reqMethod == HttpGet:
          return RouteInfo(kind: rkDownload, serverName: parts[4], mediaID: parts[5], fileName: "")
        return RouteInfo(kind: rkUnsupportedMethod)
      return RouteInfo(kind: rkUnknown)

    if parts[3] == "upload":
      if (parts.len == 4 and reqMethod == HttpPost) or (parts.len == 6 and reqMethod == HttpPut):
        return RouteInfo(kind: rkUploadNotSupported)
      return RouteInfo(kind: rkUnsupportedMethod)
    if parts[3] == "create":
      if reqMethod == HttpPost:
        return RouteInfo(kind: rkUploadNotSupported)
      return RouteInfo(kind: rkUnsupportedMethod)
    if parts[3] == "config":
      if reqMethod == HttpGet:
        return RouteInfo(kind: rkUploadNotSupported)
      return RouteInfo(kind: rkUnsupportedMethod)
    if parts[3] == "preview_url":
      if reqMethod == HttpGet:
        return RouteInfo(kind: rkPreviewURLNotSupported)
      return RouteInfo(kind: rkUnsupportedMethod)
    return RouteInfo(kind: rkUnknown)

  # /_matrix/client/v1/media/*
  if parts.len >= 5 and parts[0] == "_matrix" and parts[1] == "client" and parts[2] == "v1" and parts[3] == "media":
    if parts[4] == "download":
      if parts.len in [7, 8]:
        if reqMethod == HttpGet:
          return RouteInfo(
            kind: rkDownload,
            serverName: parts[5],
            mediaID: parts[6],
            fileName: if parts.len == 8: parts[7] else: ""
          )
        return RouteInfo(kind: rkUnsupportedMethod)
      return RouteInfo(kind: rkUnknown)

    if parts[4] == "thumbnail":
      if parts.len == 7:
        if reqMethod == HttpGet:
          return RouteInfo(kind: rkDownload, serverName: parts[5], mediaID: parts[6], fileName: "")
        return RouteInfo(kind: rkUnsupportedMethod)
      return RouteInfo(kind: rkUnknown)

    if parts[4] == "upload":
      if (parts.len == 5 and reqMethod == HttpPost) or (parts.len == 7 and reqMethod == HttpPut):
        return RouteInfo(kind: rkUploadNotSupported)
      return RouteInfo(kind: rkUnsupportedMethod)
    if parts[4] == "create":
      if reqMethod == HttpPost:
        return RouteInfo(kind: rkUploadNotSupported)
      return RouteInfo(kind: rkUnsupportedMethod)
    if parts[4] == "config":
      if reqMethod == HttpGet:
        return RouteInfo(kind: rkUploadNotSupported)
      return RouteInfo(kind: rkUnsupportedMethod)
    if parts[4] == "preview_url":
      if reqMethod == HttpGet:
        return RouteInfo(kind: rkPreviewURLNotSupported)
      return RouteInfo(kind: rkUnsupportedMethod)
    return RouteInfo(kind: rkUnknown)

  RouteInfo(kind: rkNone)

proc parseAllowRedirect(query: string): bool =
  if query.len == 0:
    return false
  for key, val in decodeQuery(query):
    if key == "allow_redirect":
      return val.toLowerAscii() == "true"
  false

proc makeResult(code: HttpCode, body: string, headers: HttpHeaders = nil): DirectMediaResult =
  DirectMediaResult(
    handled: true,
    code: code,
    body: body,
    headers: if headers == nil: newHttpHeaders() else: headers
  )

proc mediaUrlFor(api: DirectMediaApi, encodedMediaID: string): tuple[ok: bool, url: string, expiry: Time, err: RespError] =
  let parsed = parseMediaID(encodedMediaID, api.signatureKey)
  if not parsed.ok:
    return (
      false,
      "",
      fromUnix(0),
      RespError(code: ErrCodeNotFound, message: parsed.err, status: Http404)
    )

  case parsed.media.kind
  of midAttachment:
    let cacheKey = parsed.media.attachment.cacheKey()
    withLock api.cacheLock:
      if api.attachmentCache.hasKey(cacheKey):
        let cached = api.attachmentCache[cacheKey]
        let untilSec = cached.expiry.toUnix() - getTime().toUnix()
        if not cached.expiry.hasExpiry() or untilSec > 300:
          return (true, cached.url, cached.expiry, RespError())

    let byId = api.db.getFileByID($parsed.media.attachment.attachmentId)
    if not byId.found or byId.rec.url.len == 0:
      return (
        false,
        "",
        fromUnix(0),
        RespError(code: ErrCodeNotFound, message: "Attachment not found", status: Http404)
      )
    let expiry = parseExpiryTS(byId.rec.url)
    let realExpiry = if expiry.ok: expiry.expiry else: fromUnix(0)
    withLock api.cacheLock:
      api.attachmentCache[cacheKey] = AttachmentCacheValue(url: byId.rec.url, expiry: realExpiry)
    (true, byId.rec.url, realExpiry, RespError())
  of midEmoji:
    let ext = if parsed.media.emoji.animated: "gif" else: "png"
    (true, "https://cdn.discordapp.com/emojis/" & $parsed.media.emoji.emojiId & "." & ext, fromUnix(0), RespError())
  of midSticker:
    let ext =
      case parsed.media.sticker.format
      of 3'u8: "json"
      of 4'u8: "gif"
      else: "png"
    (true, "https://cdn.discordapp.com/stickers/" & $parsed.media.sticker.stickerId & "." & ext, fromUnix(0), RespError())
  of midUserAvatar:
    let hash = (if parsed.media.userAvatar.animated: "a_" else: "") & toHexLower(parsed.media.userAvatar.avatarId)
    let ext = if parsed.media.userAvatar.animated: "gif" else: "png"
    (
      true,
      "https://cdn.discordapp.com/avatars/" & $parsed.media.userAvatar.userId & "/" & hash & "." & ext,
      fromUnix(0),
      RespError()
    )
  of midGuildMemberAvatar:
    let hash = (if parsed.media.guildMemberAvatar.animated: "a_" else: "") & toHexLower(parsed.media.guildMemberAvatar.avatarId)
    let ext = if parsed.media.guildMemberAvatar.animated: "gif" else: "png"
    (
      true,
      "https://cdn.discordapp.com/guilds/" & $parsed.media.guildMemberAvatar.guildId & "/users/" &
        $parsed.media.guildMemberAvatar.userId & "/avatars/" & hash & "." & ext,
      fromUnix(0),
      RespError()
    )

proc computeCacheControl(expiry: Time): string =
  if not expiry.hasExpiry():
    return "public, max-age=31536000, immutable"
  let maxAge = (expiry.toUnix() - getTime().toUnix()) - 300
  if maxAge > 0:
    return "public, max-age=" & $maxAge & ", immutable"
  "no-store"

proc makeMXC*(api: DirectMediaApi, data: MediaID): string =
  if api == nil:
    return ""
  "mxc://" & api.serverName & "/" & signedString(data, api.signatureKey)

proc getEmojiInfo*(api: DirectMediaApi, mxc: string): tuple[ok: bool, data: EmojiMediaData] =
  if api == nil:
    return (false, EmojiMediaData())
  if not mxc.startsWith("mxc://"):
    return (false, EmojiMediaData())
  let rest = mxc[6 .. ^1]
  let slash = rest.find('/')
  if slash <= 0:
    return (false, EmojiMediaData())
  let hs = rest[0 ..< slash]
  let mediaId = rest[slash + 1 .. ^1]
  if hs != api.serverName:
    return (false, EmojiMediaData())
  let parsed = parseMediaID(mediaId, api.signatureKey)
  if not parsed.ok or parsed.media.kind != midEmoji:
    return (false, EmojiMediaData())
  (true, parsed.media.emoji)

proc attachmentMXC*(api: DirectMediaApi, channelId, messageId, attachmentId: string): string =
  if api == nil:
    return ""
  try:
    let mid = newAttachmentMediaID(parseUInt(channelId), parseUInt(messageId), parseUInt(attachmentId))
    api.makeMXC(mid)
  except CatchableError:
    ""

proc emojiMXC*(api: DirectMediaApi, emojiId, name: string, animated: bool): string =
  if api == nil:
    return ""
  try:
    api.makeMXC(EmojiMediaData(emojiId: parseUInt(emojiId), animated: animated, name: name).wrap())
  except CatchableError:
    ""

proc stickerMXC*(api: DirectMediaApi, stickerId: string, format: uint8): string =
  if api == nil:
    return ""
  try:
    api.makeMXC(StickerMediaData(stickerId: parseUInt(stickerId), format: format).wrap())
  except CatchableError:
    ""

proc avatarMXC*(api: DirectMediaApi, guildId, userId: string, avatarId: array[16, byte], animated: bool): string =
  if api == nil:
    return ""
  try:
    if guildId.len > 0:
      api.makeMXC(GuildMemberAvatarMediaData(guildId: parseUInt(guildId), userId: parseUInt(userId), animated: animated, avatarId: avatarId).wrap())
    else:
      api.makeMXC(UserAvatarMediaData(userId: parseUInt(userId), animated: animated, avatarId: avatarId).wrap())
  except CatchableError:
    ""

proc handleRequest*(
    api: DirectMediaApi,
    reqMethod: HttpMethod,
    path: string,
    query: string
): DirectMediaResult =
  if api == nil:
    return DirectMediaResult(handled: false, code: Http404, body: "", headers: newHttpHeaders())

  let route = parseRoute(reqMethod, path)
  if route.kind == rkNone:
    return DirectMediaResult(handled: false, code: Http404, body: "", headers: newHttpHeaders())

  case route.kind
  of rkNone:
    return DirectMediaResult(handled: false, code: Http404, body: "", headers: newHttpHeaders())
  of rkUnsupportedMethod:
    return makeResult(Http405, errJson(ErrCodeUnrecognized, "Invalid method for endpoint"), newHttpHeaders({"Content-Type": "application/json"}))
  of rkUnknown:
    return makeResult(Http404, errJson(ErrCodeUnrecognized, "Unrecognized endpoint"), newHttpHeaders({"Content-Type": "application/json"}))
  of rkUploadNotSupported:
    return makeResult(Http501, errJson(ErrCodeUnrecognized, "This bridge only supports proxying Discord media downloads and does not support media uploads."), newHttpHeaders({"Content-Type": "application/json"}))
  of rkPreviewURLNotSupported:
    return makeResult(Http501, errJson(ErrCodeUnrecognized, "This bridge only supports proxying Discord media downloads and does not support URL previews."), newHttpHeaders({"Content-Type": "application/json"}))
  of rkVersion:
    return makeResult(Http200, $(%*{"server": {"name": "discord-bridge-nim", "version": "dev"}}), newHttpHeaders({"Content-Type": "application/json"}))
  of rkDownload:
    if not route.isFederation and route.serverName != api.serverName:
      let msg = "This is a Discord media proxy for \"" & api.serverName & "\", other media downloads are not available here"
      return makeResult(Http404, errJson(ErrCodeNotFound, msg), newHttpHeaders({"Content-Type": "application/json"}))

    let resolved = api.mediaUrlFor(route.mediaID)
    if not resolved.ok:
      return makeResult(resolved.err.status, errJson(resolved.err.code, resolved.err.message), newHttpHeaders({"Content-Type": "application/json"}))

    # Until byte-stream proxy parity is implemented, return redirect even when allow_proxy is true.
    discard parseAllowRedirect(query)
    var headers = newHttpHeaders()
    headers["Location"] = resolved.url
    headers["Cache-Control"] = computeCacheControl(resolved.expiry)
    return makeResult(Http307, "", headers)

proc newDirectMediaApi*(cfg: Config, db: BridgeDb): DirectMediaApi =
  if not cfg.bridge.directMedia.enabled:
    return nil

  new(result)
  result.cfg = cfg
  result.db = db
  result.serverName =
    if cfg.bridge.directMedia.serverName.len > 0:
      cfg.bridge.directMedia.serverName
    else:
      cfg.homeserver.domain
  result.allowProxy = cfg.bridge.directMedia.allowProxy
  result.signatureKey = sha256Bytes(cfg.bridge.directMedia.serverKey)
  result.attachmentCache = initTable[AttachmentCacheKey, AttachmentCacheValue]()
  initLock(result.cacheLock)

proc handle*(api: DirectMediaApi, req: Request): Future[bool] {.async.} =
  let result = api.handleRequest(req.reqMethod, req.url.path, req.url.query)
  if not result.handled:
    return false
  await req.respond(result.code, result.body, result.headers)
  true
