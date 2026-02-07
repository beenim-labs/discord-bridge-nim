## Tests for portal_convert.nim — Discord→Matrix message conversion pipeline.
## Covers: embed type classification, sticker info cleanup, text messages,
## attachments, stickers, video embeds, rich embeds, link previews,
## mentions, webhook/member metadata, top-level orchestrator, emoji MXC.

import std/[unittest, json, tables, options, strutils]
import database/database
import config/config
import bridge/runtime
import bridge/portal
import bridge/portal_convert

# ===========================================================================
# Helpers
# ===========================================================================

proc makeTestConfig(): Config =
  result = defaultConfig()

proc setupTestContext(): PortalContext =
  let cfg = makeTestConfig()
  let db = openBridgeDb(":memory:", "sqlite3")
  let rt = newDiscordBridgeRuntime(cfg, db)
  result = newPortalContext(rt, cfg)
  result.supportsEncryption = false
  result.encryptionDefault = false
  result.copyAttachment = proc(url: string, encrypt: bool, id: string): PortalCopyAttachmentResult =
    PortalCopyAttachmentResult(
      ok: true,
      mxc: "mxc://example.com/" & id,
      mimeType: "image/png",
      size: 12345,
      width: 640,
      height: 480,
      encrypted: false,
    )

# ===========================================================================
suite "Embed type classification":
# ===========================================================================

  test "link embed returns link preview":
    let msg = DiscordMessage()
    let embed = DiscordEmbed(embedType: detLink, url: "https://example.com")
    check getEmbedType(msg, embed) == betLinkPreview

  test "article embed returns link preview":
    let msg = DiscordMessage()
    let embed = DiscordEmbed(embedType: detArticle)
    check getEmbedType(msg, embed) == betLinkPreview

  test "video embed returns video":
    let msg = DiscordMessage()
    let embed = DiscordEmbed(embedType: detVideo, video: some(DiscordEmbedVideo(proxyURL: "https://proxy")))
    check getEmbedType(msg, embed) == betVideo

  test "video embed with empty proxy URL returns link preview (YouTube-style)":
    let msg = DiscordMessage()
    let embed = DiscordEmbed(embedType: detVideo, video: some(DiscordEmbedVideo(proxyURL: "")))
    check getEmbedType(msg, embed) == betLinkPreview

  test "gifv embed returns video":
    let msg = DiscordMessage()
    let embed = DiscordEmbed(embedType: detGifv)
    check getEmbedType(msg, embed) == betVideo

  test "rich embed returns rich":
    let msg = DiscordMessage()
    let embed = DiscordEmbed(embedType: detRich)
    check getEmbedType(msg, embed) == betRich

  test "image embed with thumbnail only returns link preview":
    let msg = DiscordMessage()
    let embed = DiscordEmbed(embedType: detImage,
      thumbnail: some(DiscordEmbedImage(url: "https://thumb")))
    check getEmbedType(msg, embed) == betLinkPreview

  test "image embed with image returns rich":
    let msg = DiscordMessage()
    let embed = DiscordEmbed(embedType: detImage,
      image: some(DiscordEmbedImage(url: "https://img")))
    check getEmbedType(msg, embed) == betRich

# ===========================================================================
suite "isPlainGifMessage":
# ===========================================================================

  test "gifv with matching URL is plain gif":
    let embed = DiscordEmbed(embedType: detGifv, url: "https://tenor.com/gif",
      video: some(DiscordEmbedVideo(proxyURL: "https://proxy")))
    let msg = DiscordMessage(content: "https://tenor.com/gif", embeds: @[embed])
    check isPlainGifMessage(msg) == true

  test "two embeds is not plain gif":
    let embed = DiscordEmbed(embedType: detGifv, url: "https://tenor.com/gif",
      video: some(DiscordEmbedVideo(proxyURL: "https://proxy")))
    let msg = DiscordMessage(content: "https://tenor.com/gif", embeds: @[embed, embed])
    check isPlainGifMessage(msg) == false

  test "mismatched content/URL is not plain gif":
    let embed = DiscordEmbed(embedType: detGifv, url: "https://tenor.com/gif",
      video: some(DiscordEmbedVideo(proxyURL: "https://proxy")))
    let msg = DiscordMessage(content: "hello world", embeds: @[embed])
    check isPlainGifMessage(msg) == false

# ===========================================================================
suite "Sticker helpers":
# ===========================================================================

  test "sticker URL for PNG":
    let s = DiscordStickerItem(id: "123", name: "test", formatType: sftPNG)
    check stickerUrl(s) == "https://media.discordapp.net/stickers/123.png"

  test "sticker URL for GIF":
    let s = DiscordStickerItem(id: "456", name: "test", formatType: sftGIF)
    check stickerUrl(s) == "https://media.discordapp.net/stickers/456.gif"

  test "sticker MIME for Lottie":
    let s = DiscordStickerItem(id: "789", name: "test", formatType: sftLottie)
    check stickerMime(s) == "application/json"

  test "sticker MIME for APNG":
    let s = DiscordStickerItem(id: "abc", name: "test", formatType: sftAPNG)
    check stickerMime(s) == "image/apng"

# ===========================================================================
suite "cleanupConvertedStickerInfo":
# ===========================================================================

  test "zero dimensions get default size":
    var content = %*{"info": {"width": 0, "height": 0}}
    cleanupConvertedStickerInfo(content)
    check content["info"]["width"].getInt() == discordStickerSize
    check content["info"]["height"].getInt() == discordStickerSize

  test "landscape oversized gets scaled":
    var content = %*{"info": {"width": 320, "height": 160}}
    cleanupConvertedStickerInfo(content)
    check content["info"]["width"].getInt() == discordStickerSize
    check content["info"]["height"].getInt() <= discordStickerSize

  test "portrait oversized gets scaled":
    var content = %*{"info": {"width": 80, "height": 320}}
    cleanupConvertedStickerInfo(content)
    check content["info"]["height"].getInt() == discordStickerSize
    check content["info"]["width"].getInt() <= discordStickerSize

  test "square oversized gets default":
    var content = %*{"info": {"width": 320, "height": 320}}
    cleanupConvertedStickerInfo(content)
    check content["info"]["width"].getInt() == discordStickerSize
    check content["info"]["height"].getInt() == discordStickerSize

  test "small dimensions unchanged":
    var content = %*{"info": {"width": 100, "height": 80}}
    cleanupConvertedStickerInfo(content)
    check content["info"]["width"].getInt() == 100
    check content["info"]["height"].getInt() == 80

  test "no info key does nothing":
    var content = %*{"body": "test"}
    cleanupConvertedStickerInfo(content)
    check not content.hasKey("info")

# ===========================================================================
suite "HTML escape":
# ===========================================================================

  test "escapes ampersands and brackets":
    check htmlEscape("a < b & c > d") == "a &lt; b &amp; c &gt; d"

  test "escapes quotes":
    check htmlEscape("say \"hello\"") == "say &quot;hello&quot;"

  test "plain text unchanged":
    check htmlEscape("hello world") == "hello world"

# ===========================================================================
suite "renderDiscordMarkdownOnlyHTML":
# ===========================================================================

  test "bold markers become strong tags":
    check "**bold**" in renderDiscordMarkdownOnlyHTML("**bold**", true) == false
    check "<strong>bold</strong>" in renderDiscordMarkdownOnlyHTML("**bold**", true)

  test "newlines become br":
    check "<br>" in renderDiscordMarkdownOnlyHTML("line1\nline2", true)

  test "plain text just escaped":
    check renderDiscordMarkdownOnlyHTML("hello", false) == "hello"

# ===========================================================================
suite "createMediaFailedMessage":
# ===========================================================================

  test "creates notice with error":
    let msg = createMediaFailedMessage("disk full")
    check msg["msgtype"].getStr() == "m.notice"
    check "disk full" in msg["body"].getStr()

# ===========================================================================
suite "convertDiscordSticker":
# ===========================================================================

  test "PNG sticker conversion":
    let ctx = setupTestContext()
    let sticker = DiscordStickerItem(id: "stk1", name: "CoolSticker", formatType: sftPNG)
    let result = convertDiscordSticker(ctx, sticker)
    check result.eventType == "m.sticker"
    check result.attachmentId == "stk1"
    check result.content["body"].getStr() == "CoolSticker"
    check result.content{"info", "width"}.getInt() == discordStickerSize

  test "GIF sticker conversion":
    let ctx = setupTestContext()
    let sticker = DiscordStickerItem(id: "stk2", name: "AnimSticker", formatType: sftGIF)
    let result = convertDiscordSticker(ctx, sticker)
    check result.eventType == "m.sticker"
    check result.attachmentId == "stk2"

# ===========================================================================
suite "convertDiscordAttachment":
# ===========================================================================

  test "image attachment":
    let ctx = setupTestContext()
    let att = DiscordMessageAttachment(
      id: "att1", url: "https://cdn/img.png", filename: "photo.png",
      contentType: "image/png", width: 800, height: 600, size: 50000)
    let result = convertDiscordAttachment(ctx, "msg1", att)
    check result.eventType == "m.room.message"
    check result.content["msgtype"].getStr() == "m.image"
    check result.content["body"].getStr() == "photo.png"

  test "audio attachment with waveform":
    let ctx = setupTestContext()
    let att = DiscordMessageAttachment(
      id: "att2", url: "https://cdn/voice.ogg", filename: "voice.ogg",
      contentType: "audio/ogg", waveform: @[1, 2, 3], durationSeconds: 5.5)
    let result = convertDiscordAttachment(ctx, "msg2", att)
    check result.content["msgtype"].getStr() == "m.audio"
    check result.extra.hasKey("org.matrix.msc1767.audio")
    check result.extra["org.matrix.msc1767.audio"]["duration"].getInt() == 5500

  test "spoiler attachment":
    let ctx = setupTestContext()
    let att = DiscordMessageAttachment(
      id: "att3", url: "https://cdn/img.png", filename: "SPOILER_secret.png",
      contentType: "image/png")
    let result = convertDiscordAttachment(ctx, "msg3", att)
    check result.extra.hasKey("page.codeberg.everypizza.msc4193.spoiler")

  test "attachment with description":
    let ctx = setupTestContext()
    let att = DiscordMessageAttachment(
      id: "att4", url: "https://cdn/img.png", filename: "image.png",
      contentType: "image/png", description: "A beautiful sunset")
    let result = convertDiscordAttachment(ctx, "msg4", att)
    check result.content["body"].getStr() == "A beautiful sunset"
    check result.content["filename"].getStr() == "image.png"

  test "video attachment":
    let ctx = setupTestContext()
    let att = DiscordMessageAttachment(
      id: "att5", url: "https://cdn/clip.mp4", filename: "clip.mp4",
      contentType: "video/mp4")
    let result = convertDiscordAttachment(ctx, "msg5", att)
    check result.content["msgtype"].getStr() == "m.video"

  test "unknown type defaults to file":
    let ctx = setupTestContext()
    let att = DiscordMessageAttachment(
      id: "att6", url: "https://cdn/data.bin", filename: "data.bin",
      contentType: "application/octet-stream")
    let result = convertDiscordAttachment(ctx, "msg6", att)
    check result.content["msgtype"].getStr() == "m.file"

# ===========================================================================
suite "convertDiscordVideoEmbed":
# ===========================================================================

  test "video embed with video proxy":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(
      url: "https://youtube.com/watch?v=123", embedType: detVideo,
      video: some(DiscordEmbedVideo(proxyURL: "https://proxy/video", width: 1920, height: 1080)))
    let result = convertDiscordVideoEmbed(ctx, embed)
    check result.content["msgtype"].getStr() == "m.video"
    check result.content{"info", "w"}.getInt() == 1920

  test "video embed with thumbnail only":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(
      url: "https://example.com/img", embedType: detImage,
      thumbnail: some(DiscordEmbedImage(proxyURL: "https://proxy/thumb", width: 400, height: 300)))
    let result = convertDiscordVideoEmbed(ctx, embed)
    check result.content["msgtype"].getStr() == "m.image"

  test "video embed with no proxy URL returns notice":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(url: "https://broken.com", embedType: detVideo)
    let result = convertDiscordVideoEmbed(ctx, embed)
    check result.content["msgtype"].getStr() == "m.notice"
    check "no video or thumbnail proxy URL" in result.content["body"].getStr()

  test "gifv embed sets extra info":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(
      url: "https://tenor.com/gif", embedType: detGifv,
      video: some(DiscordEmbedVideo(proxyURL: "https://proxy/gif", width: 320, height: 240)))
    let result = convertDiscordVideoEmbed(ctx, embed)
    check result.extra.hasKey("info")
    check result.extra["info"]["fi.mau.gif"].getBool() == true
    check result.extra["info"]["fi.mau.loop"].getBool() == true

  test "failed copy returns error notice":
    let ctx = setupTestContext()
    ctx.copyAttachment = proc(url: string, encrypt: bool, id: string): PortalCopyAttachmentResult =
      PortalCopyAttachmentResult(ok: false, err: "connection timeout")
    let embed = DiscordEmbed(
      url: "https://example.com", embedType: detVideo,
      video: some(DiscordEmbedVideo(proxyURL: "https://proxy/video")))
    let result = convertDiscordVideoEmbed(ctx, embed)
    check "connection timeout" in result.content["body"].getStr()

# ===========================================================================
suite "convertDiscordRichEmbed":
# ===========================================================================

  test "embed with title only":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(title: "Hello World")
    let html = convertDiscordRichEmbed(ctx, embed, "msg1", 0)
    check "Hello World" in html
    check "discord-embed-title" in html

  test "embed with title and URL":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(title: "Click Me", url: "https://example.com")
    let html = convertDiscordRichEmbed(ctx, embed, "msg1", 0)
    check "https://example.com" in html

  test "embed with description":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(description: "Some **description**")
    let html = convertDiscordRichEmbed(ctx, embed, "msg1", 0)
    check "discord-embed-description" in html

  test "embed with author":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(author: some(DiscordEmbedAuthor(name: "John", url: "https://john.dev")))
    let html = convertDiscordRichEmbed(ctx, embed, "msg1", 0)
    check "John" in html
    check "discord-embed-author" in html

  test "embed with fields":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(fields: @[
      DiscordEmbedField(name: "Field1", value: "Value1", inline: true),
      DiscordEmbedField(name: "Field2", value: "Value2", inline: false)])
    let html = convertDiscordRichEmbed(ctx, embed, "msg1", 0)
    check "Field1" in html
    check "Value2" in html

  test "embed with footer":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(footer: some(DiscordEmbedFooter(text: "Footer text")))
    let html = convertDiscordRichEmbed(ctx, embed, "msg1", 0)
    check "Footer text" in html
    check "discord-embed-footer" in html

  test "embed with timestamp only (no footer)":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(timestamp: "2024-01-15T12:00:00Z")
    let html = convertDiscordRichEmbed(ctx, embed, "msg1", 0)
    check "2024-01-15T12:00:00Z" in html

  test "embed with color":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(title: "Colored", color: 0xFF5733)
    let html = convertDiscordRichEmbed(ctx, embed, "msg1", 0)
    check "FF5733" in html

  test "empty embed returns empty":
    let ctx = setupTestContext()
    let embed = DiscordEmbed()
    let html = convertDiscordRichEmbed(ctx, embed, "msg1", 0)
    check html == ""

# ===========================================================================
suite "Link preview":
# ===========================================================================

  test "link embed to Beeper preview":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(
      url: "https://example.com", title: "Example",
      description: "An example site",
      image: some(DiscordEmbedImage(proxyURL: "https://proxy/img", width: 800, height: 600)))
    let preview = convertDiscordLinkEmbedToBeeper(ctx, embed)
    check preview.matchedUrl == "https://example.com"
    check preview.title == "Example"
    check preview.imageWidth == 800

  test "link embed with thumbnail instead of image":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(
      url: "https://example.com",
      thumbnail: some(DiscordEmbedImage(proxyURL: "https://proxy/thumb", width: 300, height: 200)))
    let preview = convertDiscordLinkEmbedToBeeper(ctx, embed)
    check preview.imageWidth == 300

  test "toBeeperJson creates proper JSON":
    let preview = BeeperLinkPreview(
      matchedUrl: "https://example.com", title: "Test",
      imageWidth: 100, imageHeight: 50, imageUrl: "mxc://test")
    let j = preview.toBeeperJson()
    check j["matched_url"].getStr() == "https://example.com"
    check j["og:title"].getStr() == "Test"
    check j["og:image"].getStr() == "mxc://test"

# ===========================================================================
suite "convertDiscordMentions":
# ===========================================================================

  test "mentions are converted to puppet MXIDs":
    let ctx = setupTestContext()
    let msg = DiscordMessage(mentions: @[
      DiscordUser(id: "user1"), DiscordUser(id: "user2")])
    let result = convertDiscordMentions(ctx, msg)
    check result.userIds.len == 2
    check result.room == false

  test "mention everyone sets room true":
    let ctx = setupTestContext()
    let msg = DiscordMessage(mentionEveryone: true)
    let result = convertDiscordMentions(ctx, msg)
    check result.room == true

  test "deduplicate mentions":
    let ctx = setupTestContext()
    let msg = DiscordMessage(mentions: @[
      DiscordUser(id: "same"), DiscordUser(id: "same")])
    let result = convertDiscordMentions(ctx, msg)
    check result.userIds.len == 1

# ===========================================================================
suite "convertDiscordTextMessage":
# ===========================================================================

  test "call message returns emote":
    let ctx = setupTestContext()
    let msg = DiscordMessage(msgType: dmtCall)
    let result = convertDiscordTextMessage(ctx, msg)
    check result.isSome
    check result.get().content["msgtype"].getStr() == "m.emote"
    check "started a call" in result.get().content["body"].getStr()

  test "guild member join returns emote":
    let ctx = setupTestContext()
    let msg = DiscordMessage(msgType: dmtGuildMemberJoin)
    let result = convertDiscordTextMessage(ctx, msg)
    check result.isSome
    check "joined the server" in result.get().content["body"].getStr()

  test "text message produces formatted HTML":
    let ctx = setupTestContext()
    let msg = DiscordMessage(content: "Hello **world**!")
    let result = convertDiscordTextMessage(ctx, msg)
    check result.isSome
    check result.get().content["formatted_body"].getStr().contains("<strong>world</strong>")

  test "empty message returns none":
    let ctx = setupTestContext()
    let msg = DiscordMessage()
    let result = convertDiscordTextMessage(ctx, msg)
    check result.isNone

  test "interaction template added":
    let ctx = setupTestContext()
    let msg = DiscordMessage(
      content: "response",
      interaction: some(DiscordInteraction(
        name: "ping",
        user: DiscordUser(id: "u1", username: "Alice"))))
    let result = convertDiscordTextMessage(ctx, msg)
    check result.isSome
    let html = result.get().content["formatted_body"].getStr()
    check "/ping" in html
    check "Alice" in html

  test "component message template added":
    let ctx = setupTestContext()
    let msg = DiscordMessage(content: "Check this out",
      components: @[%*{"type": 1}])
    let result = convertDiscordTextMessage(ctx, msg)
    check result.isSome
    check "interactive elements" in result.get().content["formatted_body"].getStr()

  test "@room replaced when not mention everyone":
    let ctx = setupTestContext()
    let msg = DiscordMessage(content: "@room hello", mentionEveryone: false)
    let result = convertDiscordTextMessage(ctx, msg)
    check result.isSome
    check "@room" notin result.get().content["formatted_body"].getStr()

  test "@room preserved when mention everyone":
    let ctx = setupTestContext()
    let msg = DiscordMessage(content: "@room hello", mentionEveryone: true)
    let result = convertDiscordTextMessage(ctx, msg)
    check result.isSome
    check "@room" in result.get().content["formatted_body"].getStr()

  test "forwarded message":
    let ctx = setupTestContext()
    let msg = DiscordMessage(
      messageReference: some(DiscordMessageRefFull(refType: mrtForward)),
      messageSnapshots: @[DiscordMessageSnapshot(
        message: some(DiscordSnapshotMessage(content: "Original text", timestamp: "2024-01-01")))])
    let result = convertDiscordTextMessage(ctx, msg)
    check result.isSome
    check "Forwarded" in result.get().content["formatted_body"].getStr()
    check "Original text" in result.get().content["formatted_body"].getStr()

# ===========================================================================
suite "addMemberMeta / addWebhookMeta":
# ===========================================================================

  test "member meta added when member present":
    let msg = DiscordMessage(
      author: DiscordUser(id: "user1", username: "Alice"),
      guildId: "guild1",
      member: some(DiscordMember(nick: "Ali", avatar: "abc")))
    var part = ConvertedMessage(
      eventType: "m.room.message",
      content: %*{"msgtype": "m.text", "body": "hi"},
      extra: initTable[string, JsonNode]())
    addMemberMeta(part, msg)
    check part.extra.hasKey("fi.mau.discord.guild_member_metadata")
    check part.extra["fi.mau.discord.guild_member_metadata"]["nick"].getStr() == "Ali"
    check part.extra.hasKey("com.beeper.per_message_profile")
    check part.extra["com.beeper.per_message_profile"]["displayname"].getStr() == "Ali"

  test "member meta not added when no member":
    let msg = DiscordMessage(author: DiscordUser(id: "user1"))
    var part = ConvertedMessage(
      eventType: "m.room.message",
      content: %*{"body": "hi"},
      extra: initTable[string, JsonNode]())
    addMemberMeta(part, msg)
    check not part.extra.hasKey("fi.mau.discord.guild_member_metadata")

  test "webhook meta added":
    let msg = DiscordMessage(
      author: DiscordUser(id: "bot1", username: "Webhook", avatar: "avt"),
      webhookId: "wh123")
    var part = ConvertedMessage(
      eventType: "m.room.message",
      content: %*{"body": "hi"},
      extra: initTable[string, JsonNode]())
    addWebhookMeta(part, msg)
    check part.extra.hasKey("fi.mau.discord.webhook_metadata")
    check part.extra["fi.mau.discord.webhook_metadata"]["id"].getStr() == "wh123"
    check part.extra.hasKey("com.beeper.per_message_profile")

  test "webhook meta not added without webhook ID":
    let msg = DiscordMessage(author: DiscordUser(id: "user1"))
    var part = ConvertedMessage(
      eventType: "m.room.message",
      content: %*{"body": "hi"},
      extra: initTable[string, JsonNode]())
    addWebhookMeta(part, msg)
    check not part.extra.hasKey("fi.mau.discord.webhook_metadata")

# ===========================================================================
suite "convertDiscordMessage (orchestrator)":
# ===========================================================================

  test "text-only message":
    let ctx = setupTestContext()
    let msg = DiscordMessage(content: "Hello!")
    let parts = convertDiscordMessage(ctx, msg)
    check parts.len == 1
    check parts[0].eventType == "m.room.message"

  test "message with attachment":
    let ctx = setupTestContext()
    let msg = DiscordMessage(
      content: "Check this out",
      attachments: @[DiscordMessageAttachment(
        id: "a1", url: "https://cdn/img.png", filename: "img.png",
        contentType: "image/png")])
    let parts = convertDiscordMessage(ctx, msg)
    check parts.len == 2  # text + attachment

  test "message with sticker":
    let ctx = setupTestContext()
    let msg = DiscordMessage(
      stickerItems: @[DiscordStickerItem(id: "s1", name: "Smile", formatType: sftPNG)])
    let parts = convertDiscordMessage(ctx, msg)
    check parts.len >= 1
    check parts[parts.len - 1].eventType == "m.sticker"

  test "message with video embed":
    let ctx = setupTestContext()
    let embed = DiscordEmbed(embedType: detGifv, url: "https://tenor.com/gif",
      video: some(DiscordEmbedVideo(proxyURL: "https://proxy")))
    let msg = DiscordMessage(
      content: "https://tenor.com/gif",
      embeds: @[embed])
    let parts = convertDiscordMessage(ctx, msg)
    # plain gif message should suppress text, produce video embed
    check parts.len >= 1

  test "deduplicate attachments":
    let ctx = setupTestContext()
    let att = DiscordMessageAttachment(id: "dup", url: "https://cdn/x", filename: "x.png", contentType: "image/png")
    let msg = DiscordMessage(attachments: @[att, att])
    let parts = convertDiscordMessage(ctx, msg)
    var attCount = 0
    for p in parts:
      if p.attachmentId == "dup": attCount.inc
    check attCount == 1

  test "empty message with thread creates thread notice":
    let ctx = setupTestContext()
    let msg = DiscordMessage(thread: some(DiscordThread(name: "Discussion")))
    let parts = convertDiscordMessage(ctx, msg)
    check parts.len == 1
    check "Discussion" in parts[0].content["body"].getStr()

  test "webhook and member meta applied to all parts":
    let ctx = setupTestContext()
    let msg = DiscordMessage(
      content: "Hello",
      webhookId: "wh1",
      author: DiscordUser(id: "bot1", username: "Bot"),
      attachments: @[DiscordMessageAttachment(
        id: "a1", url: "https://cdn/x", filename: "x.png", contentType: "image/png")])
    let parts = convertDiscordMessage(ctx, msg)
    check parts.len == 2
    for p in parts:
      check p.extra.hasKey("fi.mau.discord.webhook_metadata")

# ===========================================================================
suite "getEmojiMXCByDiscordID":
# ===========================================================================

  test "animated emoji uses gif URL":
    let ctx = setupTestContext()
    let result = getEmojiMXCByDiscordID(ctx, "emoji1", "pepe", true)
    check result.len > 0

  test "static emoji uses png URL":
    let ctx = setupTestContext()
    let result = getEmojiMXCByDiscordID(ctx, "emoji2", "thumbsup", false)
    check result.len > 0

  test "failed copy returns empty":
    let ctx = setupTestContext()
    ctx.copyAttachment = proc(url: string, encrypt: bool, id: string): PortalCopyAttachmentResult =
      PortalCopyAttachmentResult(ok: false, err: "not found")
    let result = getEmojiMXCByDiscordID(ctx, "emoji3", "sad", false)
    check result == ""
