## Bridge config compatibility loader for mautrix-discord core keys.

import std/[strutils, parseutils, tables]
import common/simple_yaml

type
  HomeserverConfig* = object
    address*: string
    domain*: string
    software*: string

  AppserviceDbConfig* = object
    dbType*: string
    uri*: string
    maxOpenConns*: int
    maxIdleConns*: int

  AppserviceBotConfig* = object
    username*: string
    displayname*: string
    avatar*: string

  AppserviceConfig* = object
    address*: string
    hostname*: string
    port*: int
    id*: string
    ephemeralEvents*: bool
    asyncTransactions*: bool
    asToken*: string
    hsToken*: string
    database*: AppserviceDbConfig
    bot*: AppserviceBotConfig

  DirectMediaConfig* = object
    enabled*: bool
    serverName*: string
    wellKnownResponse*: string
    allowProxy*: bool
    serverKey*: string

  AnimatedStickerArgs* = object
    width*: int
    height*: int
    fps*: int

  AnimatedStickerConfig* = object
    target*: string
    args*: AnimatedStickerArgs

  BackfillLimitPart* = object
    dm*: int
    channel*: int
    thread*: int

  BackfillConfig* = object
    initial*: BackfillLimitPart
    missed*: BackfillLimitPart
    maxGuildMembers*: int

  ProvisioningConfig* = object
    prefix*: string
    sharedSecret*: string
    debugEndpoints*: bool

  BridgeConfig* = object
    usernameTemplate*: string
    displaynameTemplate*: string
    channelNameTemplate*: string
    guildNameTemplate*: string
    privateChatPortalMeta*: string
    privateChannelCreateLimit*: int

    portalMessageBuffer*: int
    publicAddress*: string
    avatarProxyKey*: string

    deliveryReceipts*: bool
    messageStatusEvents*: bool
    messageErrorNotices*: bool
    restrictedRooms*: bool
    autojoinThreadOnOpen*: bool
    embedFieldsAsTables*: bool
    muteChannelsOnCreate*: bool
    syncDirectChatList*: bool
    resendBridgeInfo*: bool
    customEmojiReactions*: bool
    deletePortalOnChannelDelete*: bool
    deleteGuildOnLeave*: bool
    federateRooms*: bool
    prefixWebhookMessages*: bool
    enableWebhookAvatars*: bool
    useDiscordCDNUpload*: bool

    proxy*: string
    cacheMedia*: string
    commandPrefix*: string

    directMedia*: DirectMediaConfig
    animatedSticker*: AnimatedStickerConfig
    backfill*: BackfillConfig
    provisioning*: ProvisioningConfig
    doublePuppet*: YamlMap
    encryption*: YamlMap
    managementRoomText*: YamlMap
    permissions*: YamlMap

  DisplaynameParams* = object
    globalName*: string
    username*: string
    discriminator*: string
    webhook*: bool
    application*: bool
    bot*: bool

  ChannelNameParams* = object
    name*: string
    parentName*: string
    guildName*: string
    nsfw*: bool
    channelType*: int

  GuildNameParams* = object
    name*: string

  LoggingConfig* = object
    printLevel*: string

  Config* = object
    homeserver*: HomeserverConfig
    appservice*: AppserviceConfig
    bridge*: BridgeConfig
    logging*: LoggingConfig

proc parseBool(s: string, defaultVal = false): bool =
  case s.toLowerAscii().strip()
  of "true", "yes", "1", "on": true
  of "false", "no", "0", "off": false
  else: defaultVal

proc parseIntOr(s: string, defaultVal: int): int =
  if s.len == 0:
    return defaultVal
  var n: int = 0
  let consumed = parseInt(s, n)
  if consumed == s.len:
    return n
  defaultVal

proc boolToInt*(val: bool): int =
  if val:
    1
  else:
    0

proc getResendBridgeInfo*(bc: BridgeConfig): bool =
  bc.resendBridgeInfo

proc enableMessageStatusEvents*(bc: BridgeConfig): bool =
  bc.messageStatusEvents

proc enableMessageErrorNotices*(bc: BridgeConfig): bool =
  bc.messageErrorNotices

proc getDoublePuppetConfig*(bc: BridgeConfig): YamlMap =
  bc.doublePuppet

proc getEncryptionConfig*(bc: BridgeConfig): YamlMap =
  bc.encryption

proc getCommandPrefix*(bc: BridgeConfig): string =
  bc.commandPrefix

proc getManagementRoomTexts*(bc: BridgeConfig): YamlMap =
  bc.managementRoomText

proc homeserverFromUserId(userId: string): string =
  if userId.len < 4 or userId[0] != '@':
    return ""
  let sep = userId.rfind(':')
  if sep <= 1 or sep >= userId.high:
    return ""
  userId[sep + 1 .. ^1]

proc canAutoDoublePuppet*(cfg: Config, userId: string): bool =
  let homeserver = homeserverFromUserId(userId)
  if homeserver.len == 0:
    return false
  if cfg.bridge.doublePuppet.hasKey(homeserver):
    return cfg.bridge.doublePuppet[homeserver].len > 0
  let mapKey = "server_map." & homeserver
  if cfg.bridge.doublePuppet.hasKey(mapKey):
    return cfg.bridge.doublePuppet[mapKey].len > 0
  false

proc formatUsername*(bc: BridgeConfig, userId: string): string =
  if bc.usernameTemplate.contains("{{.}}"):
    return bc.usernameTemplate.replace("{{.}}", userId)
  bc.usernameTemplate

proc simplifyTemplateOutput(raw: string): string =
  result = raw
  for token in ["{{if .Webhook}}", "{{if .Bot}}", "{{if .Application}}", "{{else}}", "{{end}}"]:
    result = result.replace(token, "")
  result = result.strip()

proc formatDisplayname*(bc: BridgeConfig, user: DisplaynameParams): string =
  var rendered = bc.displaynameTemplate

  if rendered.contains("{{if .Webhook}}") and rendered.contains("{{else}}") and rendered.contains("{{end}}"):
    let ifPrefix = "{{if .Webhook}}"
    let elseToken = "{{else}}"
    let endToken = "{{end}}"
    let startIf = rendered.find(ifPrefix)
    let startElse = rendered.find(elseToken)
    let endIdx = rendered.rfind(endToken)
    if startIf >= 0 and startElse > startIf and endIdx > startElse:
      if user.webhook:
        rendered = rendered[startIf + ifPrefix.len ..< startElse]
      else:
        rendered = rendered[startElse + elseToken.len ..< endIdx]

  if rendered.contains("{{if .Bot}}"):
    let token = "{{if .Bot}} (bot){{end}}"
    if rendered.contains(token):
      rendered = rendered.replace(token, if user.bot: " (bot)" else: "")
    elif not user.bot:
      rendered = rendered.replace("{{if .Bot}}", "").replace("{{end}}", "")

  if rendered.contains("{{or .GlobalName .Username}}"):
    let best = if user.globalName.len > 0: user.globalName else: user.username
    rendered = rendered.replace("{{or .GlobalName .Username}}", best)
  rendered = rendered.replace("{{.GlobalName}}", user.globalName)
  rendered = rendered.replace("{{.Username}}", user.username)
  rendered = rendered.replace("{{.Discriminator}}", user.discriminator)
  simplifyTemplateOutput(rendered)

proc formatChannelName*(bc: BridgeConfig, params: ChannelNameParams): string =
  let tmpl = bc.channelNameTemplate
  if tmpl.contains("eq .Type 3") and tmpl.contains("eq .Type 4"):
    if params.channelType == 3 or params.channelType == 4:
      return params.name
    return "#" & params.name

  var rendered = tmpl
  rendered = rendered.replace("{{.Name}}", params.name)
  rendered = rendered.replace("{{.ParentName}}", params.parentName)
  rendered = rendered.replace("{{.GuildName}}", params.guildName)
  rendered = rendered.replace("{{.NSFW}}", if params.nsfw: "true" else: "false")
  rendered = rendered.replace("{{.Type}}", $params.channelType)
  simplifyTemplateOutput(rendered)

proc formatGuildName*(bc: BridgeConfig, params: GuildNameParams): string =
  simplifyTemplateOutput(bc.guildNameTemplate.replace("{{.Name}}", params.name))

proc parseBridgeTemplates*(bc: BridgeConfig): tuple[ok: bool, err: string] =
  if bc.usernameTemplate.len == 0:
    return (false, "bridge.username_template is required")
  if not bc.formatUsername("1234567890").contains("1234567890"):
    return (false, "username template is missing user ID placeholder")
  if bc.displaynameTemplate.len == 0:
    return (false, "bridge.displayname_template is required")
  if bc.channelNameTemplate.len == 0:
    return (false, "bridge.channel_name_template is required")
  if bc.guildNameTemplate.len == 0:
    return (false, "bridge.guild_name_template is required")
  (true, "")

proc validateBridgeConfig*(bc: BridgeConfig): tuple[ok: bool, err: string] =
  let hasWildcard = bc.permissions.hasKey("*")
  let hasExampleDomain = bc.permissions.hasKey("example.com")
  let hasExampleUser = bc.permissions.hasKey("@admin:example.com")
  let exampleLen = boolToInt(hasWildcard) + boolToInt(hasExampleDomain) + boolToInt(hasExampleUser)
  if bc.permissions.len <= exampleLen:
    return (false, "bridge.permissions not configured")
  (true, "")

proc collectPrefixed(y: YamlMap, prefix: string): YamlMap =
  result = initTable[string, string]()
  for key, val in y:
    if key.startsWith(prefix):
      result[key[prefix.len .. ^1]] = val

proc defaultConfig*(): Config =
  result = Config(
    homeserver: HomeserverConfig(
      address: "http://localhost:8008",
      domain: "localhost",
      software: "standard"
    ),
    appservice: AppserviceConfig(
      address: "http://127.0.0.1:29334",
      hostname: "127.0.0.1",
      port: 29334,
      id: "discord",
      ephemeralEvents: true,
      asyncTransactions: false,
      asToken: "",
      hsToken: "",
      database: AppserviceDbConfig(
        dbType: "sqlite3-fk-wal",
        uri: "file:sdk/discord-bridge.db?_txlock=immediate",
        maxOpenConns: 20,
        maxIdleConns: 2
      ),
      bot: AppserviceBotConfig(
        username: "discordbot",
        displayname: "Discord Bridge",
        avatar: ""
      )
    ),
    bridge: BridgeConfig(
      usernameTemplate: "discord_{{.}}",
      displaynameTemplate: "{{or .GlobalName .Username}}",
      channelNameTemplate: "{{.Name}}",
      guildNameTemplate: "{{.Name}}",
      privateChatPortalMeta: "always",
      privateChannelCreateLimit: 200,
      portalMessageBuffer: 128,
      publicAddress: "",
      avatarProxyKey: "",
      deliveryReceipts: true,
      messageStatusEvents: false,
      messageErrorNotices: true,
      restrictedRooms: true,
      autojoinThreadOnOpen: true,
      embedFieldsAsTables: true,
      muteChannelsOnCreate: false,
      syncDirectChatList: false,
      resendBridgeInfo: false,
      customEmojiReactions: true,
      deletePortalOnChannelDelete: false,
      deleteGuildOnLeave: true,
      federateRooms: true,
      prefixWebhookMessages: true,
      enableWebhookAvatars: false,
      useDiscordCDNUpload: true,
      proxy: "",
      cacheMedia: "unencrypted",
      commandPrefix: "!discord",
      directMedia: DirectMediaConfig(
        enabled: false,
        serverName: "",
        wellKnownResponse: "",
        allowProxy: true,
        serverKey: ""
      ),
      animatedSticker: AnimatedStickerConfig(
        target: "webp",
        args: AnimatedStickerArgs(width: 320, height: 320, fps: 25)
      ),
      backfill: BackfillConfig(
        initial: BackfillLimitPart(dm: 200, channel: 0, thread: 0),
        missed: BackfillLimitPart(dm: -1, channel: 0, thread: 0),
        maxGuildMembers: -1
      ),
      provisioning: ProvisioningConfig(
        prefix: "/_matrix/provision",
        sharedSecret: "disable",
        debugEndpoints: false
      ),
      doublePuppet: initTable[string, string](),
      encryption: initTable[string, string](),
      managementRoomText: initTable[string, string](),
      permissions: initTable[string, string]()
    ),
    logging: LoggingConfig(printLevel: "debug")
  )

proc validate*(cfg: Config): tuple[ok: bool, err: string] =
  if cfg.homeserver.domain.len == 0:
    return (false, "homeserver.domain is required")
  if cfg.appservice.port <= 0:
    return (false, "invalid appservice.port")
  if cfg.appservice.id.len == 0:
    return (false, "appservice.id is required")
  if cfg.appservice.bot.username.len == 0:
    return (false, "appservice.bot.username is required")
  if cfg.appservice.database.uri.len == 0:
    return (false, "appservice.database.uri is required")
  (true, "")

proc loadConfig*(path: string): Config =
  result = defaultConfig()
  let y = parseSimpleYamlFile(path)

  result.homeserver.address = y.getOrDefault("homeserver.address", result.homeserver.address)
  result.homeserver.domain = y.getOrDefault("homeserver.domain", result.homeserver.domain)
  result.homeserver.software = y.getOrDefault("homeserver.software", result.homeserver.software)

  result.appservice.address = y.getOrDefault("appservice.address", result.appservice.address)
  result.appservice.hostname = y.getOrDefault("appservice.hostname", result.appservice.hostname)
  result.appservice.port = parseIntOr(y.getOrDefault("appservice.port", $result.appservice.port), result.appservice.port)
  result.appservice.id = y.getOrDefault("appservice.id", result.appservice.id)
  result.appservice.ephemeralEvents = parseBool(y.getOrDefault("appservice.ephemeral_events", $result.appservice.ephemeralEvents), result.appservice.ephemeralEvents)
  result.appservice.asyncTransactions = parseBool(y.getOrDefault("appservice.async_transactions", $result.appservice.asyncTransactions), result.appservice.asyncTransactions)
  result.appservice.asToken = y.getOrDefault("appservice.as_token", result.appservice.asToken)
  result.appservice.hsToken = y.getOrDefault("appservice.hs_token", result.appservice.hsToken)

  result.appservice.database.dbType = y.getOrDefault("appservice.database.type", result.appservice.database.dbType)
  result.appservice.database.uri = y.getOrDefault("appservice.database.uri", result.appservice.database.uri)
  result.appservice.database.maxOpenConns = parseIntOr(y.getOrDefault("appservice.database.max_open_conns", $result.appservice.database.maxOpenConns), result.appservice.database.maxOpenConns)
  result.appservice.database.maxIdleConns = parseIntOr(y.getOrDefault("appservice.database.max_idle_conns", $result.appservice.database.maxIdleConns), result.appservice.database.maxIdleConns)

  result.appservice.bot.username = y.getOrDefault("appservice.bot.username", result.appservice.bot.username)
  result.appservice.bot.displayname = y.getOrDefault("appservice.bot.displayname", result.appservice.bot.displayname)
  result.appservice.bot.avatar = y.getOrDefault("appservice.bot.avatar", result.appservice.bot.avatar)

  result.bridge.usernameTemplate = y.getOrDefault("bridge.username_template", result.bridge.usernameTemplate)
  result.bridge.displaynameTemplate = y.getOrDefault("bridge.displayname_template", result.bridge.displaynameTemplate)
  result.bridge.channelNameTemplate = y.getOrDefault("bridge.channel_name_template", result.bridge.channelNameTemplate)
  result.bridge.guildNameTemplate = y.getOrDefault("bridge.guild_name_template", result.bridge.guildNameTemplate)
  result.bridge.privateChatPortalMeta = y.getOrDefault("bridge.private_chat_portal_meta", result.bridge.privateChatPortalMeta)
  result.bridge.privateChannelCreateLimit = parseIntOr(y.getOrDefault("bridge.startup_private_channel_create_limit", $result.bridge.privateChannelCreateLimit), result.bridge.privateChannelCreateLimit)

  result.bridge.portalMessageBuffer = parseIntOr(y.getOrDefault("bridge.portal_message_buffer", $result.bridge.portalMessageBuffer), result.bridge.portalMessageBuffer)
  result.bridge.publicAddress = y.getOrDefault("bridge.public_address", result.bridge.publicAddress)
  result.bridge.avatarProxyKey = y.getOrDefault("bridge.avatar_proxy_key", result.bridge.avatarProxyKey)

  result.bridge.deliveryReceipts = parseBool(y.getOrDefault("bridge.delivery_receipts", $result.bridge.deliveryReceipts), result.bridge.deliveryReceipts)
  result.bridge.messageStatusEvents = parseBool(y.getOrDefault("bridge.message_status_events", $result.bridge.messageStatusEvents), result.bridge.messageStatusEvents)
  result.bridge.messageErrorNotices = parseBool(y.getOrDefault("bridge.message_error_notices", $result.bridge.messageErrorNotices), result.bridge.messageErrorNotices)
  result.bridge.restrictedRooms = parseBool(y.getOrDefault("bridge.restricted_rooms", $result.bridge.restrictedRooms), result.bridge.restrictedRooms)
  result.bridge.autojoinThreadOnOpen = parseBool(y.getOrDefault("bridge.autojoin_thread_on_open", $result.bridge.autojoinThreadOnOpen), result.bridge.autojoinThreadOnOpen)
  result.bridge.embedFieldsAsTables = parseBool(y.getOrDefault("bridge.embed_fields_as_tables", $result.bridge.embedFieldsAsTables), result.bridge.embedFieldsAsTables)
  result.bridge.muteChannelsOnCreate = parseBool(y.getOrDefault("bridge.mute_channels_on_create", $result.bridge.muteChannelsOnCreate), result.bridge.muteChannelsOnCreate)
  result.bridge.syncDirectChatList = parseBool(y.getOrDefault("bridge.sync_direct_chat_list", $result.bridge.syncDirectChatList), result.bridge.syncDirectChatList)
  result.bridge.resendBridgeInfo = parseBool(y.getOrDefault("bridge.resend_bridge_info", $result.bridge.resendBridgeInfo), result.bridge.resendBridgeInfo)
  result.bridge.customEmojiReactions = parseBool(y.getOrDefault("bridge.custom_emoji_reactions", $result.bridge.customEmojiReactions), result.bridge.customEmojiReactions)
  result.bridge.deletePortalOnChannelDelete = parseBool(y.getOrDefault("bridge.delete_portal_on_channel_delete", $result.bridge.deletePortalOnChannelDelete), result.bridge.deletePortalOnChannelDelete)
  result.bridge.deleteGuildOnLeave = parseBool(y.getOrDefault("bridge.delete_guild_on_leave", $result.bridge.deleteGuildOnLeave), result.bridge.deleteGuildOnLeave)
  result.bridge.federateRooms = parseBool(y.getOrDefault("bridge.federate_rooms", $result.bridge.federateRooms), result.bridge.federateRooms)
  result.bridge.prefixWebhookMessages = parseBool(y.getOrDefault("bridge.prefix_webhook_messages", $result.bridge.prefixWebhookMessages), result.bridge.prefixWebhookMessages)
  result.bridge.enableWebhookAvatars = parseBool(y.getOrDefault("bridge.enable_webhook_avatars", $result.bridge.enableWebhookAvatars), result.bridge.enableWebhookAvatars)
  result.bridge.useDiscordCDNUpload = parseBool(y.getOrDefault("bridge.use_discord_cdn_upload", $result.bridge.useDiscordCDNUpload), result.bridge.useDiscordCDNUpload)

  result.bridge.proxy = y.getOrDefault("bridge.proxy", result.bridge.proxy)
  result.bridge.cacheMedia = y.getOrDefault("bridge.cache_media", result.bridge.cacheMedia)
  result.bridge.commandPrefix = y.getOrDefault("bridge.command_prefix", result.bridge.commandPrefix)

  result.bridge.directMedia.enabled = parseBool(y.getOrDefault("bridge.direct_media.enabled", $result.bridge.directMedia.enabled), result.bridge.directMedia.enabled)
  result.bridge.directMedia.serverName = y.getOrDefault("bridge.direct_media.server_name", result.bridge.directMedia.serverName)
  result.bridge.directMedia.wellKnownResponse = y.getOrDefault("bridge.direct_media.well_known_response", result.bridge.directMedia.wellKnownResponse)
  result.bridge.directMedia.allowProxy = parseBool(y.getOrDefault("bridge.direct_media.allow_proxy", $result.bridge.directMedia.allowProxy), result.bridge.directMedia.allowProxy)
  result.bridge.directMedia.serverKey = y.getOrDefault("bridge.direct_media.server_key", result.bridge.directMedia.serverKey)

  result.bridge.animatedSticker.target = y.getOrDefault("bridge.animated_sticker.target", result.bridge.animatedSticker.target)
  result.bridge.animatedSticker.args.width = parseIntOr(y.getOrDefault("bridge.animated_sticker.args.width", $result.bridge.animatedSticker.args.width), result.bridge.animatedSticker.args.width)
  result.bridge.animatedSticker.args.height = parseIntOr(y.getOrDefault("bridge.animated_sticker.args.height", $result.bridge.animatedSticker.args.height), result.bridge.animatedSticker.args.height)
  result.bridge.animatedSticker.args.fps = parseIntOr(y.getOrDefault("bridge.animated_sticker.args.fps", $result.bridge.animatedSticker.args.fps), result.bridge.animatedSticker.args.fps)

  result.bridge.backfill.initial.dm = parseIntOr(y.getOrDefault("bridge.backfill.forward_limits.initial.dm", $result.bridge.backfill.initial.dm), result.bridge.backfill.initial.dm)
  result.bridge.backfill.initial.channel = parseIntOr(y.getOrDefault("bridge.backfill.forward_limits.initial.channel", $result.bridge.backfill.initial.channel), result.bridge.backfill.initial.channel)
  result.bridge.backfill.initial.thread = parseIntOr(y.getOrDefault("bridge.backfill.forward_limits.initial.thread", $result.bridge.backfill.initial.thread), result.bridge.backfill.initial.thread)

  result.bridge.backfill.missed.dm = parseIntOr(y.getOrDefault("bridge.backfill.forward_limits.missed.dm", $result.bridge.backfill.missed.dm), result.bridge.backfill.missed.dm)
  result.bridge.backfill.missed.channel = parseIntOr(y.getOrDefault("bridge.backfill.forward_limits.missed.channel", $result.bridge.backfill.missed.channel), result.bridge.backfill.missed.channel)
  result.bridge.backfill.missed.thread = parseIntOr(y.getOrDefault("bridge.backfill.forward_limits.missed.thread", $result.bridge.backfill.missed.thread), result.bridge.backfill.missed.thread)
  result.bridge.backfill.maxGuildMembers = parseIntOr(y.getOrDefault("bridge.backfill.max_guild_members", $result.bridge.backfill.maxGuildMembers), result.bridge.backfill.maxGuildMembers)

  result.bridge.provisioning.prefix = y.getOrDefault("bridge.provisioning.prefix", result.bridge.provisioning.prefix)
  result.bridge.provisioning.sharedSecret = y.getOrDefault("bridge.provisioning.shared_secret", result.bridge.provisioning.sharedSecret)
  result.bridge.provisioning.debugEndpoints = parseBool(y.getOrDefault("bridge.provisioning.debug_endpoints", $result.bridge.provisioning.debugEndpoints), result.bridge.provisioning.debugEndpoints)

  result.bridge.doublePuppet = collectPrefixed(y, "bridge.double_puppet.")
  result.bridge.encryption = collectPrefixed(y, "bridge.encryption.")
  result.bridge.managementRoomText = collectPrefixed(y, "bridge.management_room_text.")
  result.bridge.permissions = collectPrefixed(y, "bridge.permissions.")

  result.logging.printLevel = y.getOrDefault("logging.print_level", result.logging.printLevel)

  let parsedTemplates = result.bridge.parseBridgeTemplates()
  if not parsedTemplates.ok:
    raise newException(ValueError, parsedTemplates.err)
