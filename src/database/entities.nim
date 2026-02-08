## Bridge domain entities mapped from local Go schema.
## Query implementations will be expanded in parity milestones.

import std/strutils

type
  GuildBridgingMode* = enum
    gbmNothing
    gbmIfPortalExists
    gbmCreateOnMessage
    gbmEverything

  PortalKey* = object
    channelId*: string
    receiver*: string

  GuildRecord* = object
    id*: string
    mxid*: string
    plainName*: string
    name*: string
    nameSet*: bool
    avatar*: string
    avatarUrl*: string
    avatarSet*: bool
    bridgingMode*: GuildBridgingMode

  PortalRecord* = object
    key*: PortalKey
    portalType*: int
    otherUserId*: string
    guildId*: string
    parentId*: string
    mxid*: string
    plainName*: string
    name*: string
    nameSet*: bool
    friendNick*: bool
    topic*: string
    topicSet*: bool
    avatar*: string
    avatarUrl*: string
    avatarSet*: bool
    encrypted*: bool
    inSpace*: string
    firstEventId*: string
    relayWebhookId*: string
    relayWebhookSecret*: string

  ThreadRecord* = object
    id*: string
    parentChannelId*: string
    rootDiscordId*: string
    rootMxid*: string
    creationNoticeMxid*: string

  UserRecord* = object
    mxid*: string
    discordId*: string
    discordToken*: string
    managementRoom*: string
    spaceRoom*: string
    dmSpaceRoom*: string
    readStateVersion*: int
    heartbeatSessionJson*: string

  PuppetRecord* = object
    id*: string
    name*: string
    nameSet*: bool
    avatar*: string
    avatarUrl*: string
    avatarSet*: bool
    contactInfoSet*: bool
    globalName*: string
    username*: string
    discriminator*: string
    isBot*: bool
    isWebhook*: bool
    isApplication*: bool
    customMxid*: string
    accessToken*: string
    nextBatch*: string

  MessageRecord* = object
    discordId*: string
    attachmentId*: string
    channelId*: string
    channelReceiver*: string
    senderId*: string
    timestampMs*: int64
    editTimestampNs*: int64
    threadId*: string
    mxid*: string
    senderMxid*: string

  ReactionRecord* = object
    channelId*: string
    channelReceiver*: string
    messageId*: string
    sender*: string
    emojiName*: string
    threadId*: string
    firstAttachmentId*: string
    mxid*: string

  RoleRecord* = object
    guildId*: string
    id*: string
    name*: string
    icon*: string
    mentionable*: bool
    managed*: bool
    hoist*: bool
    color*: int
    position*: int
    permissions*: int64

  FileRecord* = object
    url*: string
    encrypted*: bool
    mxc*: string
    id*: string
    emojiName*: string
    size*: int
    width*: int
    height*: int
    mimeType*: string
    decryptionInfoJson*: string
    timestampMs*: int64

  UserPortalRecord* = object
    discordId*: string
    userMxid*: string
    portalType*: string
    inSpace*: bool
    timestampMs*: int64

proc discordProtoChannelID*(rec: ReactionRecord): string =
  if rec.threadId.len > 0:
    rec.threadId
  else:
    rec.channelId

proc description*(mode: GuildBridgingMode): string =
  case mode
  of gbmNothing: "not bridging"
  of gbmIfPortalExists: "portal exists"
  of gbmCreateOnMessage: "create portal on message"
  of gbmEverything: "bridging everything"

proc modeString*(mode: GuildBridgingMode): string =
  case mode
  of gbmNothing: "nothing"
  of gbmIfPortalExists: "if-portal-exists"
  of gbmCreateOnMessage: "create-on-message"
  of gbmEverything: "everything"

proc parseGuildBridgingMode*(s: string): GuildBridgingMode =
  case s.toLowerAscii()
  of "nothing": gbmNothing
  of "if-portal-exists": gbmIfPortalExists
  of "create-on-message": gbmCreateOnMessage
  of "everything": gbmEverything
  else: gbmNothing  # GuildBridgeInvalid maps to Nothing as sentinel
