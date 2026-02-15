## SQLite-backed query layer for bridge entities.
## This mirrors the local Go schema and query patterns.

import database/[database, entities, store_utils]

const
  userSelect = "SELECT mxid, dcid, discord_token, management_room, space_room, dm_space_room, read_state_version, COALESCE(heartbeat_session,'') FROM \"user\""
  portalSelect = "SELECT dcid, receiver, type, other_user_id, dc_guild_id, dc_parent_id, mxid, plain_name, name, name_set, friend_nick, blocked, topic, topic_set, avatar, avatar_url, avatar_set, encrypted, in_space, first_event_id, relay_webhook_id, relay_webhook_secret FROM portal"
  guildSelect = "SELECT dcid, mxid, plain_name, name, name_set, avatar, avatar_url, avatar_set, bridging_mode FROM guild"
  puppetSelect = "SELECT id, name, name_set, avatar, avatar_url, avatar_set, contact_info_set, global_name, username, discriminator, is_bot, is_webhook, is_application, custom_mxid, access_token, next_batch FROM puppet"
  threadSelect = "SELECT dcid, parent_chan_id, root_msg_dcid, root_msg_mxid, creation_notice_mxid FROM thread"
  messageSelect = "SELECT dcid, dc_attachment_id, dc_chan_id, dc_chan_receiver, dc_sender, timestamp, dc_edit_timestamp, dc_thread_id, mxid, sender_mxid FROM message"
  reactionSelect = "SELECT dc_chan_id, dc_chan_receiver, dc_msg_id, dc_sender, dc_emoji_name, dc_thread_id, dc_first_attachment_id, mxid FROM reaction"
  roleSelect = "SELECT dc_guild_id, dcid, name, COALESCE(icon,''), mentionable, managed, hoist, color, position, permissions FROM role"
  fileSelect = "SELECT url, encrypted, mxc, id, emoji_name, size, COALESCE(width,0), COALESCE(height,0), mime_type, COALESCE(decryption_info,''), timestamp FROM discord_file"
  userPortalSelect = "SELECT discord_id, user_mxid, type, in_space, timestamp FROM user_portal"

proc parseGuildMode(raw: string): GuildBridgingMode =
  let v = parseIntOrZero(raw)
  case v
  of 0: gbmNothing
  of 1: gbmIfPortalExists
  of 2: gbmCreateOnMessage
  of 3: gbmEverything
  else: gbmNothing

proc parseUserRow(row: seq[string]): UserRecord =
  UserRecord(
    mxid: row.getCol(0),
    discordId: row.getCol(1),
    discordToken: row.getCol(2),
    managementRoom: row.getCol(3),
    spaceRoom: row.getCol(4),
    dmSpaceRoom: row.getCol(5),
    readStateVersion: parseIntOrZero(row.getCol(6)),
    heartbeatSessionJson: row.getCol(7)
  )

proc parsePortalRow(row: seq[string]): PortalRecord =
  PortalRecord(
    key: PortalKey(channelId: row.getCol(0), receiver: row.getCol(1)),
    portalType: parseIntOrZero(row.getCol(2)),
    otherUserId: row.getCol(3),
    guildId: row.getCol(4),
    parentId: row.getCol(5),
    mxid: row.getCol(6),
    plainName: row.getCol(7),
    name: row.getCol(8),
    nameSet: parseBool(row.getCol(9)),
    friendNick: parseBool(row.getCol(10)),
    blocked: parseBool(row.getCol(11)),
    topic: row.getCol(12),
    topicSet: parseBool(row.getCol(13)),
    avatar: row.getCol(14),
    avatarUrl: row.getCol(15),
    avatarSet: parseBool(row.getCol(16)),
    encrypted: parseBool(row.getCol(17)),
    inSpace: row.getCol(18),
    firstEventId: row.getCol(19),
    relayWebhookId: row.getCol(20),
    relayWebhookSecret: row.getCol(21)
  )

proc parseGuildRow(row: seq[string]): GuildRecord =
  GuildRecord(
    id: row.getCol(0),
    mxid: row.getCol(1),
    plainName: row.getCol(2),
    name: row.getCol(3),
    nameSet: parseBool(row.getCol(4)),
    avatar: row.getCol(5),
    avatarUrl: row.getCol(6),
    avatarSet: parseBool(row.getCol(7)),
    bridgingMode: parseGuildMode(row.getCol(8))
  )

proc parsePuppetRow(row: seq[string]): PuppetRecord =
  PuppetRecord(
    id: row.getCol(0),
    name: row.getCol(1),
    nameSet: parseBool(row.getCol(2)),
    avatar: row.getCol(3),
    avatarUrl: row.getCol(4),
    avatarSet: parseBool(row.getCol(5)),
    contactInfoSet: parseBool(row.getCol(6)),
    globalName: row.getCol(7),
    username: row.getCol(8),
    discriminator: row.getCol(9),
    isBot: parseBool(row.getCol(10)),
    isWebhook: parseBool(row.getCol(11)),
    isApplication: parseBool(row.getCol(12)),
    customMxid: row.getCol(13),
    accessToken: row.getCol(14),
    nextBatch: row.getCol(15)
  )

proc parseThreadRow(row: seq[string]): ThreadRecord =
  ThreadRecord(
    id: row.getCol(0),
    parentChannelId: row.getCol(1),
    rootDiscordId: row.getCol(2),
    rootMxid: row.getCol(3),
    creationNoticeMxid: row.getCol(4)
  )

proc parseMessageRow(row: seq[string]): MessageRecord =
  MessageRecord(
    discordId: row.getCol(0),
    attachmentId: row.getCol(1),
    channelId: row.getCol(2),
    channelReceiver: row.getCol(3),
    senderId: row.getCol(4),
    timestampMs: parseInt64OrZero(row.getCol(5)),
    editTimestampNs: parseInt64OrZero(row.getCol(6)),
    threadId: row.getCol(7),
    mxid: row.getCol(8),
    senderMxid: row.getCol(9)
  )

proc parseReactionRow(row: seq[string]): ReactionRecord =
  ReactionRecord(
    channelId: row.getCol(0),
    channelReceiver: row.getCol(1),
    messageId: row.getCol(2),
    sender: row.getCol(3),
    emojiName: row.getCol(4),
    threadId: row.getCol(5),
    firstAttachmentId: row.getCol(6),
    mxid: row.getCol(7)
  )

proc parseRoleRow(row: seq[string]): RoleRecord =
  RoleRecord(
    guildId: row.getCol(0),
    id: row.getCol(1),
    name: row.getCol(2),
    icon: row.getCol(3),
    mentionable: parseBool(row.getCol(4)),
    managed: parseBool(row.getCol(5)),
    hoist: parseBool(row.getCol(6)),
    color: parseIntOrZero(row.getCol(7)),
    position: parseIntOrZero(row.getCol(8)),
    permissions: parseInt64OrZero(row.getCol(9))
  )

proc parseFileRow(row: seq[string]): FileRecord =
  FileRecord(
    url: row.getCol(0),
    encrypted: parseBool(row.getCol(1)),
    mxc: row.getCol(2),
    id: row.getCol(3),
    emojiName: row.getCol(4),
    size: parseIntOrZero(row.getCol(5)),
    width: parseIntOrZero(row.getCol(6)),
    height: parseIntOrZero(row.getCol(7)),
    mimeType: row.getCol(8),
    decryptionInfoJson: row.getCol(9),
    timestampMs: parseInt64OrZero(row.getCol(10))
  )

proc parseUserPortalRow(row: seq[string]): UserPortalRecord =
  UserPortalRecord(
    discordId: row.getCol(0),
    userMxid: row.getCol(1),
    portalType: row.getCol(2),
    inSpace: parseBool(row.getCol(3)),
    timestampMs: parseInt64OrZero(row.getCol(4))
  )

proc toSqlNullable(raw: string): string =
  if raw.len == 0:
    "NULL"
  else:
    q(raw)

proc maybeWidth(v: int): string =
  if v > 0: $v else: "NULL"

proc maybeHeight(v: int): string =
  if v > 0: $v else: "NULL"

# User

proc newUserRecord*(mxid: string): UserRecord =
  UserRecord(
    mxid: mxid,
    discordId: "",
    discordToken: "",
    managementRoom: "",
    spaceRoom: "",
    dmSpaceRoom: "",
    readStateVersion: 0,
    heartbeatSessionJson: ""
  )

proc getUserByMXID*(db: BridgeDb, mxid: string): tuple[found: bool, rec: UserRecord] =
  let rows = db.queryRows(userSelect & " WHERE mxid=" & q(mxid) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(UserRecord))
  (true, parseUserRow(rows[0]))

proc getUserByDiscordID*(db: BridgeDb, discordId: string): tuple[found: bool, rec: UserRecord] =
  let rows = db.queryRows(userSelect & " WHERE dcid=" & q(discordId) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(UserRecord))
  (true, parseUserRow(rows[0]))

proc getAllUsersWithToken*(db: BridgeDb): seq[UserRecord] =
  result = @[]
  for row in db.queryRows(userSelect & " WHERE discord_token IS NOT NULL;"):
    result.add(parseUserRow(row))

proc insertUser*(db: BridgeDb, rec: UserRecord) =
  let stmt = "INSERT INTO \"user\" (mxid, dcid, discord_token, management_room, space_room, dm_space_room, read_state_version, heartbeat_session) VALUES (" &
             q(rec.mxid) & ", " & toSqlNullable(rec.discordId) & ", " & toSqlNullable(rec.discordToken) & ", " &
             toSqlNullable(rec.managementRoom) & ", " & toSqlNullable(rec.spaceRoom) & ", " & toSqlNullable(rec.dmSpaceRoom) & ", " &
             $rec.readStateVersion & ", " & toSqlNullable(rec.heartbeatSessionJson) & ");"
  db.execSql(stmt)

proc updateUser*(db: BridgeDb, rec: UserRecord) =
  let stmt = "UPDATE \"user\" SET dcid=" & toSqlNullable(rec.discordId) & ", discord_token=" & toSqlNullable(rec.discordToken) &
             ", management_room=" & toSqlNullable(rec.managementRoom) & ", space_room=" & toSqlNullable(rec.spaceRoom) &
             ", dm_space_room=" & toSqlNullable(rec.dmSpaceRoom) & ", read_state_version=" & $rec.readStateVersion &
             ", heartbeat_session=" & toSqlNullable(rec.heartbeatSessionJson) & " WHERE mxid=" & q(rec.mxid) & ";"
  db.execSql(stmt)

# Portal

proc newPortalRecord*(key: PortalKey, portalType: int): PortalRecord =
  PortalRecord(
    key: key,
    portalType: portalType,
    otherUserId: "",
    guildId: "",
    parentId: "",
    mxid: "",
    plainName: "",
    name: "",
    nameSet: false,
    friendNick: false,
    blocked: false,
    topic: "",
    topicSet: false,
    avatar: "",
    avatarUrl: "",
    avatarSet: false,
    encrypted: false,
    inSpace: "",
    firstEventId: "",
    relayWebhookId: "",
    relayWebhookSecret: ""
  )

proc getPortalByID*(db: BridgeDb, key: PortalKey): tuple[found: bool, rec: PortalRecord] =
  let query = portalSelect & " WHERE dcid=" & q(key.channelId) &
              " AND (receiver=" & q(key.receiver) & " OR receiver='') LIMIT 1;"
  let rows = db.queryRows(query)
  if rows.len == 0:
    return (false, default(PortalRecord))
  (true, parsePortalRow(rows[0]))

proc getPortalByMXID*(db: BridgeDb, mxid: string): tuple[found: bool, rec: PortalRecord] =
  let rows = db.queryRows(portalSelect & " WHERE mxid=" & q(mxid) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(PortalRecord))
  (true, parsePortalRow(rows[0]))

proc getAllPortals*(db: BridgeDb): seq[PortalRecord] =
  result = @[]
  for row in db.queryRows(portalSelect & ";"):
    result.add(parsePortalRow(row))

proc getAllPortalsInGuild*(db: BridgeDb, guildId: string): seq[PortalRecord] =
  result = @[]
  for row in db.queryRows(portalSelect & " WHERE dc_guild_id=" & q(guildId) & ";"):
    result.add(parsePortalRow(row))

proc findPrivateChatBetween*(db: BridgeDb, otherUserId, receiver: string, dmType = 1): tuple[found: bool, rec: PortalRecord] =
  let rows = db.queryRows(portalSelect & " WHERE other_user_id=" & q(otherUserId) &
                          " AND receiver=" & q(receiver) & " AND type=" & $dmType & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(PortalRecord))
  (true, parsePortalRow(rows[0]))

proc findPrivateChatsWith*(db: BridgeDb, otherUserId: string, dmType = 1): seq[PortalRecord] =
  result = @[]
  for row in db.queryRows(portalSelect & " WHERE other_user_id=" & q(otherUserId) & " AND type=" & $dmType & ";"):
    result.add(parsePortalRow(row))

proc findPrivateChatsOf*(db: BridgeDb, receiver: string, dmType = 1): seq[PortalRecord] =
  result = @[]
  for row in db.queryRows(portalSelect & " WHERE receiver=" & q(receiver) & " AND type=" & $dmType & ";"):
    result.add(parsePortalRow(row))

proc insertPortal*(db: BridgeDb, rec: PortalRecord) =
  let stmt = "INSERT INTO portal (dcid, receiver, type, other_user_id, dc_guild_id, dc_parent_id, mxid, plain_name, name, name_set, friend_nick, blocked, topic, topic_set, avatar, avatar_url, avatar_set, encrypted, in_space, first_event_id, relay_webhook_id, relay_webhook_secret) VALUES (" &
             q(rec.key.channelId) & ", " & q(rec.key.receiver) & ", " & $rec.portalType & ", " & toSqlNullable(rec.otherUserId) &
             ", " & toSqlNullable(rec.guildId) & ", " & toSqlNullable(rec.parentId) & ", " & toSqlNullable(rec.mxid) &
             ", " & q(rec.plainName) & ", " & q(rec.name) & ", " & b2i(rec.nameSet) & ", " & b2i(rec.friendNick) &
             ", " & b2i(rec.blocked) & ", " & q(rec.topic) & ", " & b2i(rec.topicSet) & ", " & q(rec.avatar) & ", " & q(rec.avatarUrl) &
             ", " & b2i(rec.avatarSet) & ", " & b2i(rec.encrypted) & ", " & q(rec.inSpace) & ", " & q(rec.firstEventId) &
             ", " & toSqlNullable(rec.relayWebhookId) & ", " & toSqlNullable(rec.relayWebhookSecret) & ");"
  db.execSql(stmt)

proc updatePortal*(db: BridgeDb, rec: PortalRecord) =
  let stmt = "UPDATE portal SET type=" & $rec.portalType & ", other_user_id=" & toSqlNullable(rec.otherUserId) &
             ", dc_guild_id=" & toSqlNullable(rec.guildId) & ", dc_parent_id=" & toSqlNullable(rec.parentId) &
             ", mxid=" & toSqlNullable(rec.mxid) & ", plain_name=" & q(rec.plainName) & ", name=" & q(rec.name) &
             ", name_set=" & b2i(rec.nameSet) & ", friend_nick=" & b2i(rec.friendNick) & ", blocked=" & b2i(rec.blocked) &
             ", topic=" & q(rec.topic) &
             ", topic_set=" & b2i(rec.topicSet) & ", avatar=" & q(rec.avatar) & ", avatar_url=" & q(rec.avatarUrl) &
             ", avatar_set=" & b2i(rec.avatarSet) & ", encrypted=" & b2i(rec.encrypted) & ", in_space=" & q(rec.inSpace) &
             ", first_event_id=" & q(rec.firstEventId) & ", relay_webhook_id=" & toSqlNullable(rec.relayWebhookId) &
             ", relay_webhook_secret=" & toSqlNullable(rec.relayWebhookSecret) &
             " WHERE dcid=" & q(rec.key.channelId) & " AND receiver=" & q(rec.key.receiver) & ";"
  db.execSql(stmt)

proc deletePortal*(db: BridgeDb, key: PortalKey) =
  db.execSql("DELETE FROM portal WHERE dcid=" & q(key.channelId) & " AND receiver=" & q(key.receiver) & ";")

# Guild

proc newGuildRecord*(id: string): GuildRecord =
  GuildRecord(
    id: id,
    mxid: "",
    plainName: "",
    name: "",
    nameSet: false,
    avatar: "",
    avatarUrl: "",
    avatarSet: false,
    bridgingMode: gbmNothing
  )

proc getGuildByID*(db: BridgeDb, id: string): tuple[found: bool, rec: GuildRecord] =
  let rows = db.queryRows(guildSelect & " WHERE dcid=" & q(id) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(GuildRecord))
  (true, parseGuildRow(rows[0]))

proc getGuildByMXID*(db: BridgeDb, mxid: string): tuple[found: bool, rec: GuildRecord] =
  let rows = db.queryRows(guildSelect & " WHERE mxid=" & q(mxid) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(GuildRecord))
  (true, parseGuildRow(rows[0]))

proc getAllGuilds*(db: BridgeDb): seq[GuildRecord] =
  result = @[]
  for row in db.queryRows(guildSelect & ";"):
    result.add(parseGuildRow(row))

proc insertGuild*(db: BridgeDb, rec: GuildRecord) =
  let stmt = "INSERT INTO guild (dcid, mxid, plain_name, name, name_set, avatar, avatar_url, avatar_set, bridging_mode) VALUES (" &
             q(rec.id) & ", " & toSqlNullable(rec.mxid) & ", " & q(rec.plainName) & ", " & q(rec.name) &
             ", " & b2i(rec.nameSet) & ", " & q(rec.avatar) & ", " & q(rec.avatarUrl) &
             ", " & b2i(rec.avatarSet) & ", " & $ord(rec.bridgingMode) & ");"
  db.execSql(stmt)

proc updateGuild*(db: BridgeDb, rec: GuildRecord) =
  let stmt = "UPDATE guild SET mxid=" & toSqlNullable(rec.mxid) & ", plain_name=" & q(rec.plainName) &
             ", name=" & q(rec.name) & ", name_set=" & b2i(rec.nameSet) & ", avatar=" & q(rec.avatar) &
             ", avatar_url=" & q(rec.avatarUrl) & ", avatar_set=" & b2i(rec.avatarSet) &
             ", bridging_mode=" & $ord(rec.bridgingMode) & " WHERE dcid=" & q(rec.id) & ";"
  db.execSql(stmt)

proc deleteGuild*(db: BridgeDb, id: string) =
  db.execSql("DELETE FROM guild WHERE dcid=" & q(id) & ";")

# Puppet

proc newPuppetRecord*(id: string): PuppetRecord =
  PuppetRecord(
    id: id,
    name: "",
    nameSet: false,
    avatar: "",
    avatarUrl: "",
    avatarSet: false,
    contactInfoSet: false,
    globalName: "",
    username: "",
    discriminator: "",
    isBot: false,
    isWebhook: false,
    isApplication: false,
    customMxid: "",
    accessToken: "",
    nextBatch: ""
  )

proc getPuppetByID*(db: BridgeDb, id: string): tuple[found: bool, rec: PuppetRecord] =
  let rows = db.queryRows(puppetSelect & " WHERE id=" & q(id) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(PuppetRecord))
  (true, parsePuppetRow(rows[0]))

proc getPuppetByCustomMXID*(db: BridgeDb, customMxid: string): tuple[found: bool, rec: PuppetRecord] =
  let rows = db.queryRows(puppetSelect & " WHERE custom_mxid=" & q(customMxid) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(PuppetRecord))
  (true, parsePuppetRow(rows[0]))

proc getAllPuppets*(db: BridgeDb): seq[PuppetRecord] =
  result = @[]
  for row in db.queryRows(puppetSelect & ";"):
    result.add(parsePuppetRow(row))

proc getAllPuppetsWithCustomMXID*(db: BridgeDb): seq[PuppetRecord] =
  result = @[]
  for row in db.queryRows(puppetSelect & " WHERE custom_mxid IS NOT NULL AND custom_mxid <> '';"):
    result.add(parsePuppetRow(row))

proc insertPuppet*(db: BridgeDb, rec: PuppetRecord) =
  let stmt = "INSERT INTO puppet (id, name, name_set, avatar, avatar_url, avatar_set, contact_info_set, global_name, username, discriminator, is_bot, is_webhook, is_application, custom_mxid, access_token, next_batch) VALUES (" &
             q(rec.id) & ", " & q(rec.name) & ", " & b2i(rec.nameSet) & ", " & q(rec.avatar) & ", " & q(rec.avatarUrl) &
             ", " & b2i(rec.avatarSet) & ", " & b2i(rec.contactInfoSet) & ", " & q(rec.globalName) & ", " & q(rec.username) &
             ", " & q(rec.discriminator) & ", " & b2i(rec.isBot) & ", " & b2i(rec.isWebhook) & ", " & b2i(rec.isApplication) &
             ", " & toSqlNullable(rec.customMxid) & ", " & toSqlNullable(rec.accessToken) & ", " & toSqlNullable(rec.nextBatch) & ");"
  db.execSql(stmt)

proc updatePuppet*(db: BridgeDb, rec: PuppetRecord) =
  let stmt = "UPDATE puppet SET name=" & q(rec.name) & ", name_set=" & b2i(rec.nameSet) &
             ", avatar=" & q(rec.avatar) & ", avatar_url=" & q(rec.avatarUrl) & ", avatar_set=" & b2i(rec.avatarSet) &
             ", contact_info_set=" & b2i(rec.contactInfoSet) & ", global_name=" & q(rec.globalName) &
             ", username=" & q(rec.username) & ", discriminator=" & q(rec.discriminator) & ", is_bot=" & b2i(rec.isBot) &
             ", is_webhook=" & b2i(rec.isWebhook) & ", is_application=" & b2i(rec.isApplication) &
             ", custom_mxid=" & toSqlNullable(rec.customMxid) & ", access_token=" & toSqlNullable(rec.accessToken) &
             ", next_batch=" & toSqlNullable(rec.nextBatch) & " WHERE id=" & q(rec.id) & ";"
  db.execSql(stmt)

# Thread

proc newThreadRecord*(id: string): ThreadRecord =
  ThreadRecord(
    id: id,
    parentChannelId: "",
    rootDiscordId: "",
    rootMxid: "",
    creationNoticeMxid: ""
  )

proc getThreadByDiscordID*(db: BridgeDb, id: string): tuple[found: bool, rec: ThreadRecord] =
  let rows = db.queryRows(threadSelect & " WHERE dcid=" & q(id) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(ThreadRecord))
  (true, parseThreadRow(rows[0]))

proc getThreadByMatrixRootMsg*(db: BridgeDb, rootMxid: string): tuple[found: bool, rec: ThreadRecord] =
  let rows = db.queryRows(threadSelect & " WHERE root_msg_mxid=" & q(rootMxid) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(ThreadRecord))
  (true, parseThreadRow(rows[0]))

proc getThreadByMatrixRootOrCreationNoticeMsg*(db: BridgeDb, mxid: string): tuple[found: bool, rec: ThreadRecord] =
  let rows = db.queryRows(threadSelect & " WHERE root_msg_mxid=" & q(mxid) &
                          " OR creation_notice_mxid=" & q(mxid) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(ThreadRecord))
  (true, parseThreadRow(rows[0]))

proc insertThread*(db: BridgeDb, rec: ThreadRecord) =
  let stmt = "INSERT INTO thread (dcid, parent_chan_id, root_msg_dcid, root_msg_mxid, creation_notice_mxid) VALUES (" &
             q(rec.id) & ", " & q(rec.parentChannelId) & ", " & q(rec.rootDiscordId) & ", " & q(rec.rootMxid) &
             ", " & q(rec.creationNoticeMxid) & ");"
  db.execSql(stmt)

proc updateThread*(db: BridgeDb, rec: ThreadRecord) =
  let stmt = "UPDATE thread SET creation_notice_mxid=" & q(rec.creationNoticeMxid) & " WHERE dcid=" & q(rec.id) & ";"
  db.execSql(stmt)

proc deleteThread*(db: BridgeDb, rec: ThreadRecord) =
  let stmt = "DELETE FROM thread WHERE dcid=" & q(rec.id) & " AND parent_chan_id=" & q(rec.parentChannelId) & ";"
  db.execSql(stmt)

# Message

proc newMessageRecord*(discordId, attachmentId: string): MessageRecord =
  MessageRecord(
    discordId: discordId,
    attachmentId: attachmentId,
    channelId: "",
    channelReceiver: "",
    senderId: "",
    timestampMs: 0,
    editTimestampNs: 0,
    threadId: "",
    mxid: "",
    senderMxid: ""
  )

proc getMessagesByDiscordID*(db: BridgeDb, key: PortalKey, discordId: string): seq[MessageRecord] =
  result = @[]
  let query = messageSelect & " WHERE dc_chan_id=" & q(key.channelId) & " AND dc_chan_receiver=" & q(key.receiver) &
              " AND dcid=" & q(discordId) & " ORDER BY dc_attachment_id ASC;"
  for row in db.queryRows(query):
    result.add(parseMessageRow(row))

proc getFirstMessageByDiscordID*(db: BridgeDb, key: PortalKey, discordId: string): tuple[found: bool, rec: MessageRecord] =
  let query = messageSelect & " WHERE dc_chan_id=" & q(key.channelId) & " AND dc_chan_receiver=" & q(key.receiver) &
              " AND dcid=" & q(discordId) & " ORDER BY dc_attachment_id ASC LIMIT 1;"
  let rows = db.queryRows(query)
  if rows.len == 0:
    return (false, default(MessageRecord))
  (true, parseMessageRow(rows[0]))

proc getLastMessageByDiscordID*(db: BridgeDb, key: PortalKey, discordId: string): tuple[found: bool, rec: MessageRecord] =
  let query = messageSelect & " WHERE dc_chan_id=" & q(key.channelId) & " AND dc_chan_receiver=" & q(key.receiver) &
              " AND dcid=" & q(discordId) & " ORDER BY dc_attachment_id DESC LIMIT 1;"
  let rows = db.queryRows(query)
  if rows.len == 0:
    return (false, default(MessageRecord))
  (true, parseMessageRow(rows[0]))

proc getMessageByMXID*(db: BridgeDb, key: PortalKey, mxid: string): tuple[found: bool, rec: MessageRecord] =
  let query = messageSelect & " WHERE dc_chan_id=" & q(key.channelId) & " AND dc_chan_receiver=" & q(key.receiver) &
              " AND mxid=" & q(mxid) & " LIMIT 1;"
  let rows = db.queryRows(query)
  if rows.len == 0:
    return (false, default(MessageRecord))
  (true, parseMessageRow(rows[0]))

proc getLastMessage*(db: BridgeDb, key: PortalKey): tuple[found: bool, rec: MessageRecord] =
  let query = messageSelect & " WHERE dc_chan_id=" & q(key.channelId) & " AND dc_chan_receiver=" & q(key.receiver) &
              " ORDER BY timestamp DESC LIMIT 1;"
  let rows = db.queryRows(query)
  if rows.len == 0:
    return (false, default(MessageRecord))
  (true, parseMessageRow(rows[0]))

proc getOldestMessage*(db: BridgeDb, key: PortalKey): tuple[found: bool, rec: MessageRecord] =
  let query = messageSelect & " WHERE dc_chan_id=" & q(key.channelId) & " AND dc_chan_receiver=" & q(key.receiver) &
              " ORDER BY timestamp ASC, dcid ASC, dc_attachment_id ASC LIMIT 1;"
  let rows = db.queryRows(query)
  if rows.len == 0:
    return (false, default(MessageRecord))
  (true, parseMessageRow(rows[0]))

proc getRecentMessages*(db: BridgeDb, key: PortalKey, limit: int): seq[MessageRecord] =
  result = @[]
  let capped = max(1, min(200, limit))
  let query = messageSelect & " WHERE dc_chan_id=" & q(key.channelId) & " AND dc_chan_receiver=" & q(key.receiver) &
              " ORDER BY timestamp DESC, dcid DESC, dc_attachment_id DESC LIMIT " & $capped & ";"
  for row in db.queryRows(query):
    result.add(parseMessageRow(row))

proc getLastMessageInThread*(db: BridgeDb, key: PortalKey, threadId: string): tuple[found: bool, rec: MessageRecord] =
  let query = messageSelect & " WHERE dc_chan_id=" & q(key.channelId) & " AND dc_chan_receiver=" & q(key.receiver) &
              " AND dc_thread_id=" & q(threadId) & " ORDER BY timestamp DESC, dc_attachment_id DESC LIMIT 1;"
  let rows = db.queryRows(query)
  if rows.len == 0:
    return (false, default(MessageRecord))
  (true, parseMessageRow(rows[0]))

proc getClosestMessageBefore*(db: BridgeDb, key: PortalKey, threadId: string, tsMs: int64): tuple[found: bool, rec: MessageRecord] =
  let query = messageSelect & " WHERE dc_chan_id=" & q(key.channelId) & " AND dc_chan_receiver=" & q(key.receiver) &
              " AND dc_thread_id=" & q(threadId) & " AND timestamp<=" & $tsMs &
              " ORDER BY timestamp DESC, dc_attachment_id DESC LIMIT 1;"
  let rows = db.queryRows(query)
  if rows.len == 0:
    return (false, default(MessageRecord))
  (true, parseMessageRow(rows[0]))

proc insertMessage*(db: BridgeDb, rec: MessageRecord) =
  let stmt = "INSERT INTO message (dcid, dc_attachment_id, dc_chan_id, dc_chan_receiver, dc_sender, timestamp, dc_edit_timestamp, dc_thread_id, mxid, sender_mxid) VALUES (" &
             q(rec.discordId) & ", " & q(rec.attachmentId) & ", " & q(rec.channelId) & ", " & q(rec.channelReceiver) &
             ", " & q(rec.senderId) & ", " & $rec.timestampMs & ", " & $rec.editTimestampNs & ", " & q(rec.threadId) &
             ", " & q(rec.mxid) & ", " & q(rec.senderMxid) & ");"
  db.execSql(stmt)

proc massInsertMessages*(db: BridgeDb, key: PortalKey, msgs: seq[MessageRecord]) =
  for msg in msgs:
    var row = msg
    row.channelId = key.channelId
    row.channelReceiver = key.receiver
    db.insertMessage(row)

type
  MessagePart* = object
    attachmentId*: string
    mxid*: string

proc massInsertMessageParts*(db: BridgeDb, base: MessageRecord, msgs: seq[MessagePart]) =
  for msg in msgs:
    var row = base
    row.attachmentId = msg.attachmentId
    row.mxid = msg.mxid
    db.insertMessage(row)

proc updateMessageEditTimestamp*(db: BridgeDb, rec: MessageRecord, tsNs: int64) =
  let stmt = "UPDATE message SET dc_edit_timestamp=" & $tsNs &
             " WHERE dcid=" & q(rec.discordId) & " AND dc_attachment_id=" & q(rec.attachmentId) &
             " AND dc_chan_id=" & q(rec.channelId) & " AND dc_chan_receiver=" & q(rec.channelReceiver) &
             " AND dc_edit_timestamp<" & $tsNs & ";"
  db.execSql(stmt)

proc deleteMessage*(db: BridgeDb, rec: MessageRecord) =
  let stmt = "DELETE FROM message WHERE dcid=" & q(rec.discordId) &
             " AND dc_attachment_id=" & q(rec.attachmentId) &
             " AND dc_chan_id=" & q(rec.channelId) &
             " AND dc_chan_receiver=" & q(rec.channelReceiver) & ";"
  db.execSql(stmt)

proc deleteAllMessages*(db: BridgeDb, key: PortalKey) =
  let stmt = "DELETE FROM message WHERE dc_chan_id=" & q(key.channelId) & " AND dc_chan_receiver=" & q(key.receiver) & ";"
  db.execSql(stmt)

# Reaction

proc newReactionRecord*(): ReactionRecord =
  ReactionRecord(
    channelId: "",
    channelReceiver: "",
    messageId: "",
    sender: "",
    emojiName: "",
    threadId: "",
    firstAttachmentId: "",
    mxid: ""
  )

proc getAllReactionsForMessage*(db: BridgeDb, key: PortalKey, messageId: string): seq[ReactionRecord] =
  result = @[]
  let query = reactionSelect & " WHERE dc_chan_id=" & q(key.channelId) & " AND dc_chan_receiver=" & q(key.receiver) &
              " AND dc_msg_id=" & q(messageId) & ";"
  for row in db.queryRows(query):
    result.add(parseReactionRow(row))

proc getReactionByDiscordID*(db: BridgeDb, key: PortalKey, messageId, sender, emojiName: string): tuple[found: bool, rec: ReactionRecord] =
  let query = reactionSelect & " WHERE dc_chan_id=" & q(key.channelId) &
              " AND dc_chan_receiver=" & q(key.receiver) &
              " AND dc_msg_id=" & q(messageId) &
              " AND dc_sender=" & q(sender) &
              " AND dc_emoji_name=" & q(emojiName) & " LIMIT 1;"
  let rows = db.queryRows(query)
  if rows.len == 0:
    return (false, default(ReactionRecord))
  (true, parseReactionRow(rows[0]))

proc getReactionByMXID*(db: BridgeDb, mxid: string): tuple[found: bool, rec: ReactionRecord] =
  let rows = db.queryRows(reactionSelect & " WHERE mxid=" & q(mxid) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(ReactionRecord))
  (true, parseReactionRow(rows[0]))

proc insertReaction*(db: BridgeDb, rec: ReactionRecord) =
  let stmt = "INSERT INTO reaction (dc_msg_id, dc_first_attachment_id, dc_sender, dc_emoji_name, dc_chan_id, dc_chan_receiver, dc_thread_id, mxid) VALUES (" &
             q(rec.messageId) & ", " & q(rec.firstAttachmentId) & ", " & q(rec.sender) & ", " & q(rec.emojiName) &
             ", " & q(rec.channelId) & ", " & q(rec.channelReceiver) & ", " & q(rec.threadId) & ", " & q(rec.mxid) & ");"
  db.execSql(stmt)

proc deleteReaction*(db: BridgeDb, rec: ReactionRecord) =
  let stmt = "DELETE FROM reaction WHERE dc_msg_id=" & q(rec.messageId) &
             " AND dc_sender=" & q(rec.sender) &
             " AND dc_emoji_name=" & q(rec.emojiName) & ";"
  db.execSql(stmt)

# Role

proc newRoleRecord*(guildId, id: string): RoleRecord =
  RoleRecord(
    guildId: guildId,
    id: id,
    name: "",
    icon: "",
    mentionable: false,
    managed: false,
    hoist: false,
    color: 0,
    position: 0,
    permissions: 0'i64
  )

proc getRoleByID*(db: BridgeDb, guildId, id: string): tuple[found: bool, rec: RoleRecord] =
  let rows = db.queryRows(roleSelect & " WHERE dc_guild_id=" & q(guildId) & " AND dcid=" & q(id) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(RoleRecord))
  (true, parseRoleRow(rows[0]))

proc getAllRoles*(db: BridgeDb, guildId: string): seq[RoleRecord] =
  result = @[]
  for row in db.queryRows(roleSelect & " WHERE dc_guild_id=" & q(guildId) & ";"):
    result.add(parseRoleRow(row))

proc upsertRole*(db: BridgeDb, rec: RoleRecord) =
  let stmt = "INSERT INTO role (dc_guild_id, dcid, name, icon, mentionable, managed, hoist, color, position, permissions) VALUES (" &
             q(rec.guildId) & ", " & q(rec.id) & ", " & q(rec.name) & ", " & toSqlNullable(rec.icon) &
             ", " & b2i(rec.mentionable) & ", " & b2i(rec.managed) & ", " & b2i(rec.hoist) &
             ", " & $rec.color & ", " & $rec.position & ", " & $rec.permissions & ") " &
             "ON CONFLICT (dc_guild_id, dcid) DO UPDATE SET name=excluded.name, icon=excluded.icon, mentionable=excluded.mentionable, managed=excluded.managed, hoist=excluded.hoist, color=excluded.color, position=excluded.position, permissions=excluded.permissions;"
  db.execSql(stmt)

proc deleteRoleByID*(db: BridgeDb, guildId, id: string) =
  db.execSql("DELETE FROM role WHERE dc_guild_id=" & q(guildId) & " AND dcid=" & q(id) & ";")

# File

proc newFileRecord*(url: string, encrypted: bool): FileRecord =
  FileRecord(
    url: url,
    encrypted: encrypted,
    mxc: "",
    id: "",
    emojiName: "",
    size: 0,
    width: 0,
    height: 0,
    mimeType: "",
    decryptionInfoJson: "",
    timestampMs: 0
  )

proc getFile*(db: BridgeDb, url: string, encrypted: bool): tuple[found: bool, rec: FileRecord] =
  let rows = db.queryRows(fileSelect & " WHERE url=" & q(url) & " AND encrypted=" & b2i(encrypted) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(FileRecord))
  (true, parseFileRow(rows[0]))

proc getFileByID*(db: BridgeDb, id: string): tuple[found: bool, rec: FileRecord] =
  let rows = db.queryRows(fileSelect & " WHERE id=" & q(id) & " LIMIT 1;")
  if rows.len == 0:
    return (false, default(FileRecord))
  (true, parseFileRow(rows[0]))

proc getEmojiFileByMXC*(db: BridgeDb, mxc: string): tuple[found: bool, rec: FileRecord] =
  let rows = db.queryRows(fileSelect & " WHERE mxc=" & q(mxc) & " AND emoji_name<>'' LIMIT 1;")
  if rows.len == 0:
    return (false, default(FileRecord))
  (true, parseFileRow(rows[0]))

proc insertFile*(db: BridgeDb, rec: FileRecord) =
  let stmt = "INSERT INTO discord_file (url, encrypted, mxc, id, emoji_name, size, width, height, mime_type, decryption_info, timestamp) VALUES (" &
             q(rec.url) & ", " & b2i(rec.encrypted) & ", " & q(rec.mxc) & ", " & toSqlNullable(rec.id) &
             ", " & toSqlNullable(rec.emojiName) & ", " & $rec.size & ", " & maybeWidth(rec.width) &
             ", " & maybeHeight(rec.height) & ", " & q(rec.mimeType) & ", " & toSqlNullable(rec.decryptionInfoJson) &
             ", " & $rec.timestampMs & ");"
  db.execSql(stmt)

proc deleteFile*(db: BridgeDb, url: string, encrypted: bool) =
  db.execSql("DELETE FROM discord_file WHERE url=" & q(url) & " AND encrypted=" & b2i(encrypted) & ";")

# User portal

proc getUsersInPortal*(db: BridgeDb, discordId: string): seq[string] =
  result = @[]
  for row in db.queryRows("SELECT user_mxid FROM user_portal WHERE discord_id=" & q(discordId) & ";"):
    result.add(row.getCol(0))

proc getUserPortals*(db: BridgeDb, userMxid: string): seq[UserPortalRecord] =
  result = @[]
  for row in db.queryRows(userPortalSelect & " WHERE user_mxid=" & q(userMxid) & ";"):
    result.add(parseUserPortalRow(row))

proc markUserInPortal*(db: BridgeDb, rec: UserPortalRecord) =
  let stmt = "INSERT INTO user_portal (discord_id, user_mxid, type, in_space, timestamp) VALUES (" &
             q(rec.discordId) & ", " & q(rec.userMxid) & ", " & q(rec.portalType) & ", " & b2i(rec.inSpace) &
             ", " & $rec.timestampMs & ") ON CONFLICT (discord_id, user_mxid) DO UPDATE SET timestamp=excluded.timestamp, in_space=excluded.in_space;"
  db.execSql(stmt)

proc markUserNotInPortal*(db: BridgeDb, userMxid, discordId: string) =
  db.execSql("DELETE FROM user_portal WHERE user_mxid=" & q(userMxid) & " AND discord_id=" & q(discordId) & ";")

proc isUserInPortal*(db: BridgeDb, userMxid, discordId: string): bool =
  let rows = db.queryRows("SELECT EXISTS(SELECT 1 FROM user_portal WHERE user_mxid=" & q(userMxid) & " AND discord_id=" & q(discordId) & ");")
  rows.len > 0 and parseBool(rows[0].getCol(0))

proc isUserInSpace*(db: BridgeDb, userMxid, discordId: string): bool =
  let rows = db.queryRows("SELECT in_space FROM user_portal WHERE user_mxid=" & q(userMxid) & " AND discord_id=" & q(discordId) & " LIMIT 1;")
  rows.len > 0 and parseBool(rows[0].getCol(0))

proc portalHasOtherUsers*(db: BridgeDb, userMxid, discordId: string): bool =
  let rows = db.queryRows("SELECT COUNT(*) > 0 FROM user_portal WHERE user_mxid<>" & q(userMxid) & " AND discord_id=" & q(discordId) & ";")
  rows.len > 0 and parseBool(rows[0].getCol(0))

proc pruneUserPortals*(db: BridgeDb, userMxid: string, beforeTsMs: int64): seq[UserPortalRecord] =
  result = @[]
  let selectQuery = userPortalSelect & " WHERE user_mxid=" & q(userMxid) &
                    " AND timestamp<" & $beforeTsMs & " AND type IN ('dm', 'guild');"
  for row in db.queryRows(selectQuery):
    result.add(parseUserPortalRow(row))
  let deleteQuery = "DELETE FROM user_portal WHERE user_mxid=" & q(userMxid) &
                    " AND timestamp<" & $beforeTsMs & " AND type IN ('dm', 'guild');"
  db.execSql(deleteQuery)
