## Direct media ID encoding/parsing compatible with local Go bridge.

import std/[base64, strutils, openssl]

type
  MediaIDClass* = enum
    midAttachment = 1
    midEmoji = 2
    midSticker = 3
    midUserAvatar = 4
    midGuildMemberAvatar = 5

  AttachmentCacheKey* = object
    channelId*: uint64
    attachmentId*: uint64

  AttachmentMediaData* = object
    channelId*: uint64
    messageId*: uint64
    attachmentId*: uint64

  StickerMediaData* = object
    stickerId*: uint64
    format*: uint8

  EmojiMediaData* = object
    emojiId*: uint64
    animated*: bool
    name*: string

  UserAvatarMediaData* = object
    userId*: uint64
    animated*: bool
    avatarId*: array[16, byte]

  GuildMemberAvatarMediaData* = object
    guildId*: uint64
    userId*: uint64
    animated*: bool
    avatarId*: array[16, byte]

  MediaID* = object
    version*: uint8
    kind*: MediaIDClass
    attachment*: AttachmentMediaData
    sticker*: StickerMediaData
    emoji*: EmojiMediaData
    userAvatar*: UserAvatarMediaData
    guildMemberAvatar*: GuildMemberAvatarMediaData

const
  MediaIDVersion* = 1'u8
  TruncatedHashLength* = 16

  ErrInvalidMediaID* = "invalid media ID"
  ErrMediaIDChecksumMismatch* = "invalid checksum in media ID"
  ErrUnsupportedMediaID* = "unsupported media ID"

  MediaIDPrefix*: array[11, byte] = [
    0xF0'u8, 0x9F'u8, 0x90'u8, 0x88'u8,
    byte('D'), byte('I'), byte('S'), byte('C'), byte('O'), byte('R'), byte('D')
  ]

proc bytesToString(data: openArray[byte]): string =
  result = newString(data.len)
  for i, b in data:
    result[i] = char(b)

proc stringToBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ch)

proc encodeRawUrlBase64(data: seq[byte]): string =
  result = encode(bytesToString(data), safe = true)
  while result.len > 0 and result[^1] == '=':
    result.setLen(result.len - 1)

proc decodeRawUrlBase64(s: string): tuple[ok: bool, data: seq[byte], err: string] =
  var normalized = s.replace('-', '+').replace('_', '/')
  while normalized.len mod 4 != 0:
    normalized.add('=')
  try:
    (true, stringToBytes(decode(normalized)), "")
  except CatchableError as e:
    (false, @[], "failed to decode base64: " & e.msg)

proc hmacSha256(data: seq[byte], key: array[32, byte]): seq[byte] =
  var mdBuf = newString(64)
  var mdLen: cuint = 0
  let dataStr = bytesToString(data)
  discard HMAC(EVP_sha256(), unsafeAddr key[0], cint(key.len), dataStr.cstring, csize_t(dataStr.len), mdBuf.cstring, addr mdLen)
  result = newSeq[byte](int(mdLen))
  for i in 0 ..< int(mdLen):
    result[i] = byte(mdBuf[i])

proc addU8(outBuf: var seq[byte], v: uint8) =
  outBuf.add(v)

proc addBool(outBuf: var seq[byte], v: bool) =
  outBuf.add(if v: 1'u8 else: 0'u8)

proc addU64BE(outBuf: var seq[byte], v: uint64) =
  outBuf.add(uint8((v shr 56) and 0xFF'u64))
  outBuf.add(uint8((v shr 48) and 0xFF'u64))
  outBuf.add(uint8((v shr 40) and 0xFF'u64))
  outBuf.add(uint8((v shr 32) and 0xFF'u64))
  outBuf.add(uint8((v shr 24) and 0xFF'u64))
  outBuf.add(uint8((v shr 16) and 0xFF'u64))
  outBuf.add(uint8((v shr 8) and 0xFF'u64))
  outBuf.add(uint8(v and 0xFF'u64))

proc readU8(data: openArray[byte], pos: var int): tuple[ok: bool, value: uint8] =
  if pos >= data.len:
    return (false, 0'u8)
  let v = data[pos]
  inc pos
  (true, v)

proc readBool(data: openArray[byte], pos: var int): tuple[ok: bool, value: bool] =
  let r = readU8(data, pos)
  if not r.ok:
    return (false, false)
  (true, r.value != 0)

proc readU64BE(data: openArray[byte], pos: var int): tuple[ok: bool, value: uint64] =
  if pos + 8 > data.len:
    return (false, 0'u64)
  var v = 0'u64
  for _ in 0 ..< 8:
    v = (v shl 8) or uint64(data[pos])
    inc pos
  (true, v)

proc size*(amd: AttachmentMediaData): int = 8 + 8 + 8
proc size*(smd: StickerMediaData): int = 8 + 1
proc size*(emd: EmojiMediaData): int = 8 + 1 + emd.name.len
proc size*(uamd: UserAvatarMediaData): int = 8 + 1 + 16
proc size*(guamd: GuildMemberAvatarMediaData): int = 8 + 8 + 1 + 16

proc writeBytes*(amd: AttachmentMediaData): seq[byte] =
  result = @[]
  result.addU64BE(amd.channelId)
  result.addU64BE(amd.messageId)
  result.addU64BE(amd.attachmentId)

proc writeBytes*(smd: StickerMediaData): seq[byte] =
  result = @[]
  result.addU64BE(smd.stickerId)
  result.addU8(smd.format)

proc writeBytes*(emd: EmojiMediaData): seq[byte] =
  result = @[]
  result.addU64BE(emd.emojiId)
  result.addBool(emd.animated)
  for b in stringToBytes(emd.name):
    result.add(b)

proc writeBytes*(uamd: UserAvatarMediaData): seq[byte] =
  result = @[]
  result.addU64BE(uamd.userId)
  result.addBool(uamd.animated)
  for b in uamd.avatarId:
    result.add(b)

proc writeBytes*(guamd: GuildMemberAvatarMediaData): seq[byte] =
  result = @[]
  result.addU64BE(guamd.guildId)
  result.addU64BE(guamd.userId)
  result.addBool(guamd.animated)
  for b in guamd.avatarId:
    result.add(b)

proc readBytes*(amd: var AttachmentMediaData, payload: openArray[byte]): tuple[ok: bool, err: string] =
  var pos = 0
  let c = readU64BE(payload, pos)
  let m = readU64BE(payload, pos)
  let a = readU64BE(payload, pos)
  if not c.ok or not m.ok or not a.ok:
    return (false, "failed to parse attachment media ID data")
  amd = AttachmentMediaData(channelId: c.value, messageId: m.value, attachmentId: a.value)
  (true, "")

proc readBytes*(smd: var StickerMediaData, payload: openArray[byte]): tuple[ok: bool, err: string] =
  var pos = 0
  let sid = readU64BE(payload, pos)
  let fmt = readU8(payload, pos)
  if not sid.ok or not fmt.ok:
    return (false, "failed to parse sticker media ID data")
  smd = StickerMediaData(stickerId: sid.value, format: fmt.value)
  (true, "")

proc readBytes*(emd: var EmojiMediaData, payload: openArray[byte]): tuple[ok: bool, err: string] =
  var pos = 0
  let eid = readU64BE(payload, pos)
  let anim = readBool(payload, pos)
  if not eid.ok or not anim.ok:
    return (false, "failed to parse emoji media ID data")
  let nm = if pos < payload.len: bytesToString(payload.toOpenArray(pos, payload.len - 1)) else: ""
  emd = EmojiMediaData(emojiId: eid.value, animated: anim.value, name: nm)
  (true, "")

proc readBytes*(uamd: var UserAvatarMediaData, payload: openArray[byte]): tuple[ok: bool, err: string] =
  var pos = 0
  let uid = readU64BE(payload, pos)
  let anim = readBool(payload, pos)
  if not uid.ok or not anim.ok or pos + 16 > payload.len:
    return (false, "failed to parse user avatar media ID data")
  var avatar: array[16, byte] = default(array[16, byte])
  for i in 0 ..< 16:
    avatar[i] = payload[pos + i]
  uamd = UserAvatarMediaData(userId: uid.value, animated: anim.value, avatarId: avatar)
  (true, "")

proc readBytes*(guamd: var GuildMemberAvatarMediaData, payload: openArray[byte]): tuple[ok: bool, err: string] =
  var pos = 0
  let gid = readU64BE(payload, pos)
  let uid = readU64BE(payload, pos)
  let anim = readBool(payload, pos)
  if not gid.ok or not uid.ok or not anim.ok or pos + 16 > payload.len:
    return (false, "failed to parse guild member avatar media ID data")
  var avatar: array[16, byte] = default(array[16, byte])
  for i in 0 ..< 16:
    avatar[i] = payload[pos + i]
  guamd = GuildMemberAvatarMediaData(guildId: gid.value, userId: uid.value, animated: anim.value, avatarId: avatar)
  (true, "")

proc wrap*(amd: AttachmentMediaData): MediaID =
  MediaID(version: MediaIDVersion, kind: midAttachment, attachment: amd)

proc wrap*(smd: StickerMediaData): MediaID =
  MediaID(version: MediaIDVersion, kind: midSticker, sticker: smd)

proc wrap*(emd: EmojiMediaData): MediaID =
  MediaID(version: MediaIDVersion, kind: midEmoji, emoji: emd)

proc wrap*(uamd: UserAvatarMediaData): MediaID =
  MediaID(version: MediaIDVersion, kind: midUserAvatar, userAvatar: uamd)

proc wrap*(guamd: GuildMemberAvatarMediaData): MediaID =
  MediaID(version: MediaIDVersion, kind: midGuildMemberAvatar, guildMemberAvatar: guamd)

proc cacheKey*(amd: AttachmentMediaData): AttachmentCacheKey =
  AttachmentCacheKey(channelId: amd.channelId, attachmentId: amd.attachmentId)

proc writeBytes*(mid: MediaID): seq[byte] =
  result = @[]
  for b in MediaIDPrefix:
    result.add(b)
  result.add(mid.version)
  result.add(uint8(mid.kind))
  case mid.kind
  of midAttachment:
    result.add(mid.attachment.writeBytes())
  of midSticker:
    result.add(mid.sticker.writeBytes())
  of midEmoji:
    result.add(mid.emoji.writeBytes())
  of midUserAvatar:
    result.add(mid.userAvatar.writeBytes())
  of midGuildMemberAvatar:
    result.add(mid.guildMemberAvatar.writeBytes())

proc size*(mid: MediaID): int =
  let dataSize =
    case mid.kind
    of midAttachment:
      mid.attachment.size()
    of midSticker:
      mid.sticker.size()
    of midEmoji:
      mid.emoji.size()
    of midUserAvatar:
      mid.userAvatar.size()
    of midGuildMemberAvatar:
      mid.guildMemberAvatar.size()
  MediaIDPrefix.len + 2 + dataSize + TruncatedHashLength

proc readBytes*(mid: var MediaID, payload: openArray[byte]): tuple[ok: bool, err: string] =
  var pos = 0
  for b in MediaIDPrefix:
    if pos >= payload.len or payload[pos] != b:
      return (false, ErrInvalidMediaID & ": prefix not found")
    inc pos

  let ver = readU8(payload, pos)
  if not ver.ok:
    return (false, ErrInvalidMediaID & ": version and class not found")
  if ver.value != MediaIDVersion:
    return (false, ErrUnsupportedMediaID & ": unknown version " & $ver.value)

  let cls = readU8(payload, pos)
  if not cls.ok:
    return (false, ErrInvalidMediaID & ": version and class not found")

  mid.version = ver.value
  case cls.value
  of 1'u8:
    mid.kind = midAttachment
    let parsed = mid.attachment.readBytes(payload.toOpenArray(pos, payload.len - 1))
    if not parsed.ok:
      return (false, parsed.err)
  of 2'u8:
    mid.kind = midEmoji
    let parsed = mid.emoji.readBytes(payload.toOpenArray(pos, payload.len - 1))
    if not parsed.ok:
      return (false, parsed.err)
  of 3'u8:
    mid.kind = midSticker
    let parsed = mid.sticker.readBytes(payload.toOpenArray(pos, payload.len - 1))
    if not parsed.ok:
      return (false, parsed.err)
  of 4'u8:
    mid.kind = midUserAvatar
    let parsed = mid.userAvatar.readBytes(payload.toOpenArray(pos, payload.len - 1))
    if not parsed.ok:
      return (false, parsed.err)
  of 5'u8:
    mid.kind = midGuildMemberAvatar
    let parsed = mid.guildMemberAvatar.readBytes(payload.toOpenArray(pos, payload.len - 1))
    if not parsed.ok:
      return (false, parsed.err)
  else:
    return (false, ErrUnsupportedMediaID & ": unrecognized type class " & $cls.value)
  (true, "")

proc signedString*(mid: MediaID, key: array[32, byte]): string =
  let payload = mid.writeBytes()
  let digest = hmacSha256(payload, key)
  var combined = payload
  for i in 0 ..< TruncatedHashLength:
    combined.add(digest[i])
  encodeRawUrlBase64(combined)

proc parseMediaID*(id: string, key: array[32, byte]): tuple[ok: bool, media: MediaID, err: string] =
  let decoded = decodeRawUrlBase64(id)
  if not decoded.ok:
    return (false, MediaID(), decoded.err)
  if decoded.data.len < TruncatedHashLength:
    return (false, MediaID(), ErrInvalidMediaID & ": too short")

  let payloadLen = decoded.data.len - TruncatedHashLength
  let payload = decoded.data[0 ..< payloadLen]
  let checksum = decoded.data[payloadLen .. ^1]
  let expected = hmacSha256(payload, key)
  for i in 0 ..< TruncatedHashLength:
    if checksum[i] != expected[i]:
      return (false, MediaID(), ErrMediaIDChecksumMismatch)

  var mid = MediaID()
  let parsed = mid.readBytes(payload)
  if not parsed.ok:
    return (false, MediaID(), "failed to parse media ID: " & parsed.err)
  (true, mid, "")

proc newAttachmentMediaID*(channelId, messageId, attachmentId: uint64): MediaID =
  AttachmentMediaData(
    channelId: channelId,
    messageId: messageId,
    attachmentId: attachmentId
  ).wrap()
