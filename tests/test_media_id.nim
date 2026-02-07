import std/[unittest, strutils]
import directmedia/media_id

suite "media id":
  test "attachment roundtrip":
    var key: array[32, byte]
    for i in 0 ..< key.len:
      key[i] = byte(i)

    let mid = newAttachmentMediaID(123'u64, 456'u64, 789'u64)
    let encoded = signedString(mid, key)
    check encoded.len > 0

    let parsed = parseMediaID(encoded, key)
    check parsed.ok
    check parsed.media.version == MediaIDVersion
    check parsed.media.kind == midAttachment
    check parsed.media.attachment.channelId == 123'u64
    check parsed.media.attachment.messageId == 456'u64
    check parsed.media.attachment.attachmentId == 789'u64

  test "checksum mismatch":
    var key: array[32, byte]
    for i in 0 ..< key.len:
      key[i] = byte(i)

    let mid = newAttachmentMediaID(1'u64, 2'u64, 3'u64)
    var encoded = signedString(mid, key)
    encoded[^1] = if encoded[^1] == 'A': 'B' else: 'A'

    let parsed = parseMediaID(encoded, key)
    check not parsed.ok

  test "attachment write/read helpers":
    let data = AttachmentMediaData(channelId: 11'u64, messageId: 22'u64, attachmentId: 33'u64)
    check data.size() == 24

    let key = data.cacheKey()
    check key.channelId == 11'u64
    check key.attachmentId == 33'u64

    let wrapped = data.wrap()
    check wrapped.kind == midAttachment
    check wrapped.size() == MediaIDPrefix.len + 2 + data.size() + TruncatedHashLength

    var parsed = AttachmentMediaData()
    let readRes = parsed.readBytes(data.writeBytes())
    check readRes.ok
    check parsed.channelId == data.channelId
    check parsed.messageId == data.messageId
    check parsed.attachmentId == data.attachmentId

  test "emoji wrap and parse helpers":
    let data = EmojiMediaData(emojiId: 12345'u64, animated: true, name: "party_blob")
    let wrapped = data.wrap()
    check wrapped.kind == midEmoji

    var parsed = EmojiMediaData()
    let readRes = parsed.readBytes(data.writeBytes())
    check readRes.ok
    check parsed.emojiId == data.emojiId
    check parsed.animated == data.animated
    check parsed.name == data.name

  test "media readBytes validates version and class":
    var payload: seq[byte] = @[]
    for b in MediaIDPrefix:
      payload.add(b)
    payload.add(99'u8) # unsupported version
    payload.add(1'u8)
    payload.add(newSeq[byte](24))

    var mid = MediaID()
    let parsed = mid.readBytes(payload)
    check not parsed.ok
    check parsed.err.find(ErrUnsupportedMediaID) >= 0
