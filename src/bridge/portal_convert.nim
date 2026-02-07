## Portal message conversion ported from portal_convert.go / attachments.go.
## Covers: Discord→Matrix message, attachment, sticker, embed, video embed,
## link preview, rich embed HTML, mentions, text message, forward handling,
## attachment copy pipeline and emoji MXC resolution.
##
## 25+ functions total from portal_convert.go, plus 7 from attachments.go.

import std/[strutils, json, tables, options, algorithm, sequtils]
import bridge/portal

# ===========================================================================
# Discord API types (matching discordgo structs)
# ===========================================================================

type
  StickerFormatType* = enum
    sftPNG = 1
    sftAPNG = 2
    sftLottie = 3
    sftGIF = 4

  DiscordStickerItem* = object
    id*: string
    name*: string
    formatType*: StickerFormatType

  DiscordMessageAttachment* = object
    id*: string
    url*: string
    proxyUrl*: string
    filename*: string
    contentType*: string
    description*: string
    size*: int
    width*: int
    height*: int
    waveform*: seq[int]
    durationSeconds*: float

  DiscordEmbedImage* = object
    url*: string
    proxyURL*: string
    width*: int
    height*: int

  DiscordEmbedVideo* = object
    url*: string
    proxyURL*: string
    width*: int
    height*: int

  DiscordEmbedAuthor* = object
    name*: string
    url*: string
    proxyIconURL*: string

  DiscordEmbedField* = object
    name*: string
    value*: string
    inline*: bool

  DiscordEmbedFooter* = object
    text*: string
    proxyIconURL*: string

  DiscordEmbedType* = enum
    detRich = "rich"
    detImage = "image"
    detVideo = "video"
    detGifv = "gifv"
    detArticle = "article"
    detLink = "link"

  DiscordEmbed* = object
    url*: string
    embedType*: DiscordEmbedType
    title*: string
    description*: string
    color*: int
    timestamp*: string
    author*: Option[DiscordEmbedAuthor]
    fields*: seq[DiscordEmbedField]
    image*: Option[DiscordEmbedImage]
    thumbnail*: Option[DiscordEmbedImage]
    video*: Option[DiscordEmbedVideo]
    footer*: Option[DiscordEmbedFooter]

  DiscordMessageType* = enum
    dmtDefault = 0
    dmtRecipientAdd = 1
    dmtRecipientRemove = 2
    dmtCall = 3
    dmtChannelNameChange = 4
    dmtChannelIconChange = 5
    dmtChannelPinnedMessage = 6
    dmtGuildMemberJoin = 7
    dmtUserPremiumGuildSubscription = 8
    dmtReply = 19
    dmtChatInputCommand = 20
    dmtThreadStarterMessage = 21
    dmtGuildInviteReminder = 22
    dmtContextMenuCommand = 23
    dmtAutoModerationAction = 24

  MessageReferenceType* = enum
    mrtDefault = 0
    mrtForward = 1

  DiscordMessageRefFull* = object
    messageId*: string
    channelId*: string
    guildId*: string
    refType*: MessageReferenceType

  DiscordInteraction* = object
    name*: string
    user*: DiscordUser

  DiscordUser* = object
    id*: string
    username*: string
    avatar*: string
    globalName*: string
    discriminator*: string

  DiscordMember* = object
    nick*: string
    avatar*: string

  DiscordMessageSnapshot* = object
    message*: Option[DiscordSnapshotMessage]

  DiscordSnapshotMessage* = object
    content*: string
    timestamp*: string

  DiscordThread* = object
    name*: string

  DiscordMessage* = object
    id*: string
    channelId*: string
    guildId*: string
    content*: string
    msgType*: DiscordMessageType
    author*: DiscordUser
    member*: Option[DiscordMember]
    attachments*: seq[DiscordMessageAttachment]
    stickerItems*: seq[DiscordStickerItem]
    embeds*: seq[DiscordEmbed]
    mentions*: seq[DiscordUser]
    mentionEveryone*: bool
    webhookId*: string
    applicationId*: string
    interaction*: Option[DiscordInteraction]
    messageReference*: Option[DiscordMessageRefFull]
    messageSnapshots*: seq[DiscordMessageSnapshot]
    components*: seq[JsonNode]
    thread*: Option[DiscordThread]

# ===========================================================================
# Converted message result type
# ===========================================================================

type
  ConvertedMessage* = object
    attachmentId*: string
    eventType*: string           ## e.g. "m.room.message", "m.sticker"
    content*: JsonNode
    extra*: Table[string, JsonNode]

  BridgeEmbedType* = enum
    betUnknown
    betRich
    betLinkPreview
    betVideo

  BeeperLinkPreview* = object
    matchedUrl*: string
    title*: string
    description*: string
    imageUrl*: string
    imageWidth*: int
    imageHeight*: int
    imageSize*: int
    imageType*: string
    imageEncrypted*: bool
    imageEncryptionJson*: string

  MatrixMentions* = object
    userIds*: seq[string]
    room*: bool

# ===========================================================================
# Constants
# ===========================================================================

const
  discordStickerSize* = 160

  embedHTMLWrapper*          = """<blockquote class="discord-embed">$1</blockquote>"""
  embedHTMLWrapperColor*     = """<blockquote class="discord-embed" background-color="#$1">$2</blockquote>"""
  embedHTMLAuthorWithImage*  = """<p class="discord-embed-author"><img data-mx-emoticon height="24" src="$1" title="Author icon" alt="">&nbsp;<span>$2</span></p>"""
  embedHTMLAuthorPlain*      = """<p class="discord-embed-author"><span>$1</span></p>"""
  embedHTMLAuthorLink*       = """<a href="$1">$2</a>"""
  embedHTMLTitleWithLink*    = """<p class="discord-embed-title"><a href="$1"><strong>$2</strong></a></p>"""
  embedHTMLTitlePlain*       = """<p class="discord-embed-title"><strong>$1</strong></p>"""
  embedHTMLDescription*      = """<p class="discord-embed-description">$1</p>"""
  embedHTMLLinearField*      = """<p class="discord-embed-field" x-inline="$1"><strong>$2</strong><br><span>$3</span></p>"""
  embedHTMLImage*            = """<p class="discord-embed-image"><img src="$1" alt="" title="Embed image"></p>"""
  embedHTMLFooterWithImage*  = """<p class="discord-embed-footer"><sub><img data-mx-emoticon height="20" src="$1" title="Footer icon" alt="">&nbsp;<span>$2</span>$3</sub></p>"""
  embedHTMLFooterPlain*      = """<p class="discord-embed-footer"><sub><span>$1</span>$2</sub></p>"""
  embedHTMLFooterOnlyDate*   = """<p class="discord-embed-footer"><sub>$1</sub></p>"""
  embedHTMLDate*             = """<time datetime="$1">$2</time>"""
  embedFooterDateSeparator*  = """ • """

  msgInteractionTemplateHTML* = """<blockquote>
<a href="https://matrix.to/#/$1">$2</a> used <font color="#3771bb">/$3</font>
</blockquote>"""

  msgComponentTemplateHTML* = """<p>This message contains interactive elements. Use the Discord app to interact with the message.</p>"""

  forwardTemplateHTML* = """<blockquote>
<p>↷ Forwarded</p>
$1
<p>$2</p>
</blockquote>"""

# ===========================================================================
# Helpers
# ===========================================================================

proc stickerUrl*(sticker: DiscordStickerItem): string =
  let ext = case sticker.formatType
    of sftPNG: "png"
    of sftAPNG: "png"
    of sftLottie: "json"
    of sftGIF: "gif"
  "https://media.discordapp.net/stickers/" & sticker.id & "." & ext

proc stickerMime*(sticker: DiscordStickerItem): string =
  case sticker.formatType
  of sftPNG: "image/png"
  of sftAPNG: "image/apng"
  of sftLottie: "application/json"
  of sftGIF: "image/gif"

proc htmlEscape*(s: string): string =
  result = s
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")

proc renderDiscordMarkdownOnlyHTML*(text: string, allowLinks: bool): string =
  ## Simplified Discord markdown → HTML.
  result = htmlEscape(text)
  while "**" in result:
    let i = result.find("**")
    let j = result.find("**", i + 2)
    if j < 0: break
    result = result[0 ..< i] & "<strong>" & result[i+2 ..< j] & "</strong>" & result[j+2 .. ^1]
  result = result.replace("\n", "<br>")

proc toBeeperJson*(p: BeeperLinkPreview): JsonNode =
  result = %*{
    "matched_url": p.matchedUrl,
    "og:title": p.title,
    "og:description": p.description,
    "og:image:width": p.imageWidth,
    "og:image:height": p.imageHeight,
    "matrix:image:size": p.imageSize,
    "og:image:type": p.imageType,
  }
  if p.imageEncrypted:
    result["beeper:image:encryption"] = parseJson(p.imageEncryptionJson)
  else:
    result["og:image"] = %p.imageUrl

proc mentionsToJson*(m: MatrixMentions): JsonNode =
  result = %*{"user_ids": m.userIds}
  if m.room:
    result["room"] = %true

# ===========================================================================
# Embed type classification
# ===========================================================================

proc isActuallyLinkPreview*(embed: DiscordEmbed): bool =
  embed.video.isSome and embed.video.get().proxyURL == ""

proc isPlainGifMessage*(msg: DiscordMessage): bool =
  if msg.embeds.len != 1: return false
  let embed = msg.embeds[0]
  let isGifVideo = embed.embedType == detGifv and embed.video.isSome
  let isGifImage = embed.embedType == detImage and embed.image.isNone and
                   embed.thumbnail.isSome and embed.title == ""
  let contentIsOnlyURL = msg.content == embed.url
  contentIsOnlyURL and (isGifVideo or isGifImage)

proc getEmbedType*(msg: DiscordMessage, embed: DiscordEmbed): BridgeEmbedType =
  case embed.embedType
  of detLink, detArticle: betLinkPreview
  of detVideo:
    if isActuallyLinkPreview(embed): betLinkPreview else: betVideo
  of detGifv: betVideo
  of detImage:
    if isPlainGifMessage(msg): betVideo
    elif embed.image.isNone and embed.thumbnail.isSome: betLinkPreview
    else: betRich
  of detRich: betRich

# ===========================================================================
# createMediaFailedMessage
# ===========================================================================

proc createMediaFailedMessage*(err: string): JsonNode =
  %*{"msgtype": "m.notice", "body": "Failed to bridge media: " & err}

# ===========================================================================
# cleanupConvertedStickerInfo
# ===========================================================================

proc cleanupConvertedStickerInfo*(content: var JsonNode) =
  if not content.hasKey("info"): return
  let info = content["info"]
  var w = info{"width"}.getInt(0)
  var h = info{"height"}.getInt(0)
  if w == 0 and h == 0:
    content["info"]["width"] = %discordStickerSize
    content["info"]["height"] = %discordStickerSize
  elif w > discordStickerSize or h > discordStickerSize:
    if w > h:
      content["info"]["height"] = %(h div (w div discordStickerSize))
      content["info"]["width"] = %discordStickerSize
    elif w < h:
      content["info"]["width"] = %(w div (h div discordStickerSize))
      content["info"]["height"] = %discordStickerSize
    else:
      content["info"]["width"] = %discordStickerSize
      content["info"]["height"] = %discordStickerSize

# ===========================================================================
# convertDiscordFile
# ===========================================================================

proc convertDiscordFile*(ctx: PortalContext, typeName: string,
                         id, url: string, content: var JsonNode): JsonNode =
  let res = ctx.copyAttachment(url, ctx.supportsEncryption and ctx.encryptionDefault, id)
  if not res.ok:
    return createMediaFailedMessage(res.err)
  if typeName == "sticker" and content{"info", "mimetype"}.getStr() == "application/json":
    content["info"]["mimetype"] = %res.mimeType
  content["info"]["size"] = %res.size
  if content{"info", "w"}.getInt(0) == 0 and content{"info", "h"}.getInt(0) == 0:
    content["info"]["w"] = %res.width
    content["info"]["h"] = %res.height
  if res.encrypted:
    content["file"] = %*{"url": res.mxc, "encryption_info": res.decryptionInfoJson}
  else:
    content["url"] = %res.mxc
  content

# ===========================================================================
# convertDiscordSticker
# ===========================================================================

proc convertDiscordSticker*(ctx: PortalContext, sticker: DiscordStickerItem): ConvertedMessage =
  let mime = stickerMime(sticker)
  var content = %*{"body": sticker.name, "info": {"mimetype": mime}}
  content = convertDiscordFile(ctx, "sticker", sticker.id, stickerUrl(sticker), content)
  cleanupConvertedStickerInfo(content)
  ConvertedMessage(attachmentId: sticker.id, eventType: "m.sticker", content: content)

# ===========================================================================
# convertDiscordAttachment
# ===========================================================================

proc convertDiscordAttachment*(ctx: PortalContext, messageId: string,
                               att: DiscordMessageAttachment): ConvertedMessage =
  var content = %*{
    "body": att.filename,
    "info": {"mimetype": att.contentType, "w": att.width, "h": att.height, "size": att.size}
  }
  var extra = initTable[string, JsonNode]()

  if att.filename.startsWith("SPOILER_"):
    extra["page.codeberg.everypizza.msc4193.spoiler"] = %true

  if att.description != "":
    content["body"] = %att.description
    content["filename"] = %att.filename

  let category = att.contentType.split("/")[0].toLowerAscii
  let msgType = case category
    of "audio": "m.audio"
    of "image": "m.image"
    of "video": "m.video"
    else: "m.file"
  content["msgtype"] = %msgType

  if category == "audio" and att.waveform.len > 0:
    extra["org.matrix.msc1767.audio"] = %*{"duration": int(att.durationSeconds * 1000)}
    extra["org.matrix.msc3245.voice"] = %*{}

  content = convertDiscordFile(ctx, "attachment", att.id, att.url, content)
  ConvertedMessage(attachmentId: att.id, eventType: "m.room.message", content: content, extra: extra)

# ===========================================================================
# convertDiscordVideoEmbed
# ===========================================================================

proc convertDiscordVideoEmbed*(ctx: PortalContext, embed: DiscordEmbed): ConvertedMessage =
  let attachmentId = "video_" & embed.url
  var proxyUrl = ""
  var isVideo = false
  if embed.video.isSome:
    proxyUrl = embed.video.get().proxyURL
    isVideo = true
  elif embed.thumbnail.isSome:
    proxyUrl = embed.thumbnail.get().proxyURL

  if proxyUrl == "":
    return ConvertedMessage(attachmentId: attachmentId, eventType: "m.room.message",
      content: %*{"body": "Failed to bridge media: no video or thumbnail proxy URL found in embed", "msgtype": "m.notice"})

  let res = ctx.copyAttachment(proxyUrl, ctx.supportsEncryption and ctx.encryptionDefault, "")
  if not res.ok:
    return ConvertedMessage(attachmentId: attachmentId, eventType: "m.room.message",
      content: createMediaFailedMessage(res.err))

  let msgType = if isVideo: "m.video" else: "m.image"
  var w: int = 0
  var h: int = 0
  if isVideo and embed.video.isSome:
    w = embed.video.get().width; h = embed.video.get().height
  elif embed.thumbnail.isSome:
    w = embed.thumbnail.get().width; h = embed.thumbnail.get().height
  if w == 0 and h == 0:
    w = res.width; h = res.height

  var content = %*{
    "body": embed.url, "msgtype": msgType,
    "info": {"mimetype": res.mimeType, "size": res.size, "w": w, "h": h}
  }
  if res.encrypted: content["file"] = %*{"url": res.mxc}
  else: content["url"] = %res.mxc

  var extra = initTable[string, JsonNode]()
  if msgType == "m.video" and embed.embedType == detGifv:
    extra["info"] = %*{
      "fi.mau.discord.gifv": true, "fi.mau.gif": true, "fi.mau.loop": true,
      "fi.mau.autoplay": true, "fi.mau.hide_controls": true, "fi.mau.no_audio": true}

  ConvertedMessage(attachmentId: attachmentId, eventType: "m.room.message", content: content, extra: extra)

# ===========================================================================
# convertDiscordRichEmbed
# ===========================================================================

proc convertDiscordRichEmbed*(ctx: PortalContext, embed: DiscordEmbed,
                              msgId: string, index: int): string =
  var htmlParts: seq[string] = @[]

  if embed.author.isSome:
    let auth = embed.author.get()
    var authorNameHTML = htmlEscape(auth.name)
    if auth.url != "":
      authorNameHTML = embedHTMLAuthorLink.replace("$1", auth.url).replace("$2", authorNameHTML)
    var authorHTML = embedHTMLAuthorPlain.replace("$1", authorNameHTML)
    if auth.proxyIconURL != "":
      let iconRes = ctx.copyAttachment(auth.proxyIconURL, false, "")
      if iconRes.ok:
        authorHTML = embedHTMLAuthorWithImage.replace("$1", iconRes.mxc).replace("$2", authorNameHTML)
    htmlParts.add(authorHTML)

  if embed.title != "":
    let baseTitleHTML = renderDiscordMarkdownOnlyHTML(embed.title, false)
    if embed.url != "":
      htmlParts.add(embedHTMLTitleWithLink.replace("$1", htmlEscape(embed.url)).replace("$2", baseTitleHTML))
    else:
      htmlParts.add(embedHTMLTitlePlain.replace("$1", baseTitleHTML))

  if embed.description != "":
    htmlParts.add(embedHTMLDescription.replace("$1", renderDiscordMarkdownOnlyHTML(embed.description, true)))

  for i in 0 ..< embed.fields.len:
    let field = embed.fields[i]
    htmlParts.add(embedHTMLLinearField
      .replace("$1", $field.inline)
      .replace("$2", renderDiscordMarkdownOnlyHTML(field.name, false))
      .replace("$3", renderDiscordMarkdownOnlyHTML(field.value, true)))

  if embed.image.isSome:
    let imgRes = ctx.copyAttachment(embed.image.get().proxyURL, false, "")
    if imgRes.ok:
      htmlParts.add(embedHTMLImage.replace("$1", imgRes.mxc))

  var embedDateHTML = ""
  if embed.timestamp != "":
    embedDateHTML = embedHTMLDate.replace("$1", embed.timestamp).replace("$2", embed.timestamp)

  if embed.footer.isSome:
    let ftr = embed.footer.get()
    var datePart = ""
    if embedDateHTML != "": datePart = embedFooterDateSeparator & embedDateHTML
    var footerHTML = embedHTMLFooterPlain.replace("$1", htmlEscape(ftr.text)).replace("$2", datePart)
    if ftr.proxyIconURL != "":
      let iconRes = ctx.copyAttachment(ftr.proxyIconURL, false, "")
      if iconRes.ok:
        footerHTML = embedHTMLFooterWithImage.replace("$1", iconRes.mxc)
          .replace("$2", htmlEscape(ftr.text)).replace("$3", datePart)
    htmlParts.add(footerHTML)
  elif embed.timestamp != "":
    htmlParts.add(embedHTMLFooterOnlyDate.replace("$1", embedDateHTML))

  if htmlParts.len == 0: return ""

  let compiledHTML = htmlParts.join("")
  if embed.color != 0:
    embedHTMLWrapperColor.replace("$1", embed.color.toHex(6)).replace("$2", compiledHTML)
  else:
    embedHTMLWrapper.replace("$1", compiledHTML)

# ===========================================================================
# convertDiscordLinkEmbedImage / convertDiscordLinkEmbedToBeeper
# ===========================================================================

proc convertDiscordLinkEmbedImage*(ctx: PortalContext, url: string,
                                   width, height: int,
                                   preview: var BeeperLinkPreview) =
  let res = ctx.copyAttachment(url, ctx.supportsEncryption and ctx.encryptionDefault, "")
  if not res.ok: return
  preview.imageWidth = if width != 0 or height != 0: width else: res.width
  preview.imageHeight = if width != 0 or height != 0: height else: res.height
  preview.imageSize = res.size
  preview.imageType = res.mimeType
  preview.imageEncrypted = res.encrypted
  if res.encrypted: preview.imageEncryptionJson = res.decryptionInfoJson
  else: preview.imageUrl = res.mxc

proc convertDiscordLinkEmbedToBeeper*(ctx: PortalContext,
                                     embed: DiscordEmbed): BeeperLinkPreview =
  result = BeeperLinkPreview(matchedUrl: embed.url, title: embed.title, description: embed.description)
  if embed.image.isSome:
    let img = embed.image.get()
    convertDiscordLinkEmbedImage(ctx, img.proxyURL, img.width, img.height, result)
  elif embed.thumbnail.isSome:
    let thumb = embed.thumbnail.get()
    convertDiscordLinkEmbedImage(ctx, thumb.proxyURL, thumb.width, thumb.height, result)

# ===========================================================================
# convertDiscordMentions
# ===========================================================================

proc convertDiscordMentions*(ctx: PortalContext, msg: DiscordMessage): MatrixMentions =
  result = MatrixMentions(userIds: @[], room: false)
  for mention in msg.mentions:
    let puppetMxid = ctx.formatPuppetMXID(mention.id)
    if puppetMxid notin result.userIds:
      result.userIds.add(puppetMxid)
  result.userIds.sort()
  result.userIds = deduplicate(result.userIds, isSorted = true)
  if msg.mentionEveryone:
    result.room = true

# ===========================================================================
# convertDiscordTextMessage
# ===========================================================================

proc convertDiscordTextMessage*(ctx: PortalContext,
                                msg: DiscordMessage): Option[ConvertedMessage] =
  if msg.msgType == dmtCall:
    return some(ConvertedMessage(eventType: "m.room.message",
      content: %*{"msgtype": "m.emote", "body": "started a call"}))
  if msg.msgType == dmtGuildMemberJoin:
    return some(ConvertedMessage(eventType: "m.room.message",
      content: %*{"msgtype": "m.emote", "body": "joined the server"}))

  var htmlParts: seq[string] = @[]

  if msg.interaction.isSome:
    let inter = msg.interaction.get()
    let puppetMxid = ctx.formatPuppetMXID(inter.user.id)
    htmlParts.add(msgInteractionTemplateHTML
      .replace("$1", puppetMxid)
      .replace("$2", htmlEscape(inter.user.username))
      .replace("$3", htmlEscape(inter.name)))

  if msg.content != "" and not isPlainGifMessage(msg):
    htmlParts.add(renderDiscordMarkdownOnlyHTML(msg.content, true))
  elif msg.messageReference.isSome and
       msg.messageReference.get().refType == mrtForward and
       msg.messageSnapshots.len > 0 and
       msg.messageSnapshots[0].message.isSome:
    let snapshot = msg.messageSnapshots[0].message.get()
    let forwardedHTML = renderDiscordMarkdownOnlyHTML(snapshot.content, true)
    let origLink = "unknown channel • " & snapshot.timestamp
    htmlParts.add(forwardTemplateHTML.replace("$1", forwardedHTML).replace("$2", origLink))

  var previews: seq[BeeperLinkPreview] = @[]
  for i, embed in msg.embeds:
    case getEmbedType(msg, embed)
    of betRich:
      let html = convertDiscordRichEmbed(ctx, embed, msg.id, i)
      if html != "": htmlParts.add(html)
    of betLinkPreview:
      previews.add(convertDiscordLinkEmbedToBeeper(ctx, embed))
    of betVideo: discard
    of betUnknown: discard

  if msg.components.len > 0:
    htmlParts.add(msgComponentTemplateHTML)

  if htmlParts.len == 0:
    return none(ConvertedMessage)

  var fullHTML = htmlParts.join("\n")
  if not msg.mentionEveryone:
    fullHTML = fullHTML.replace("@room", "@\u2063ro\u2063om")

  let plainBody = fullHTML
    .replace("<br>", "\n")
    .replace("<strong>", "").replace("</strong>", "")
    .replace("<blockquote>", "").replace("</blockquote>", "")

  var extra = initTable[string, JsonNode]()
  extra["com.beeper.linkpreviews"] = %previews.map(proc(p: BeeperLinkPreview): JsonNode = p.toBeeperJson())

  let mentions = convertDiscordMentions(ctx, msg)
  var content = %*{
    "msgtype": "m.text", "body": plainBody,
    "format": "org.matrix.custom.html", "formatted_body": fullHTML,
    "m.mentions": mentions.mentionsToJson()
  }

  some(ConvertedMessage(eventType: "m.room.message", content: content, extra: extra))

# ===========================================================================
# addMemberMeta / addWebhookMeta
# ===========================================================================

proc addMemberMeta*(part: var ConvertedMessage, msg: DiscordMessage) =
  if msg.member.isNone: return
  let member = msg.member.get()
  part.extra["fi.mau.discord.guild_member_metadata"] = %*{
    "nick": member.nick, "avatar_id": member.avatar}
  if member.nick != "" or member.avatar != "":
    part.extra["com.beeper.per_message_profile"] = %*{
      "id": msg.guildId & "_" & msg.author.id,
      "displayname": (if member.nick != "": member.nick else: msg.author.username),
      "avatar_url": ""}

proc addWebhookMeta*(part: var ConvertedMessage, msg: DiscordMessage) =
  if msg.webhookId == "": return
  part.extra["fi.mau.discord.webhook_metadata"] = %*{
    "id": msg.webhookId, "name": msg.author.username, "avatar_id": msg.author.avatar}
  part.extra["com.beeper.per_message_profile"] = %*{
    "id": msg.author.username & ":" & msg.author.avatar,
    "displayname": msg.author.username, "avatar_url": "", "has_fallback": false}

# ===========================================================================
# convertDiscordMessage — top-level orchestrator
# ===========================================================================

proc convertDiscordMessage*(ctx: PortalContext, msg: DiscordMessage): seq[ConvertedMessage] =
  var parts: seq[ConvertedMessage] = @[]
  let textPart = convertDiscordTextMessage(ctx, msg)
  if textPart.isSome: parts.add(textPart.get())

  var handledIds = initTable[string, bool]()

  for att in msg.attachments:
    if handledIds.hasKey(att.id): continue
    handledIds[att.id] = true
    parts.add(convertDiscordAttachment(ctx, msg.id, att))

  for sticker in msg.stickerItems:
    if handledIds.hasKey(sticker.id): continue
    handledIds[sticker.id] = true
    parts.add(convertDiscordSticker(ctx, sticker))

  for i, embed in msg.embeds:
    if getEmbedType(msg, embed) != betVideo: continue
    if handledIds.hasKey(embed.url): continue
    handledIds[embed.url] = true
    parts.add(convertDiscordVideoEmbed(ctx, embed))

  if parts.len == 0 and msg.thread.isSome:
    parts.add(ConvertedMessage(eventType: "m.room.message",
      content: %*{"msgtype": "m.text", "body": "Created a thread: " & msg.thread.get().name}))

  for i in 0 ..< parts.len:
    addWebhookMeta(parts[i], msg)
    addMemberMeta(parts[i], msg)

  parts

# ===========================================================================
# getEmojiMXCByDiscordID
# ===========================================================================

proc getEmojiMXCByDiscordID*(ctx: PortalContext, emojiId, name: string,
                             animated: bool): string =
  let url = if animated:
    "https://cdn.discordapp.com/emojis/" & emojiId & ".gif"
  else:
    "https://cdn.discordapp.com/emojis/" & emojiId & ".png"
  let res = ctx.copyAttachment(url, false, emojiId)
  if res.ok: res.mxc else: ""
