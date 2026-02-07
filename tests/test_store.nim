import std/[unittest, os, times]
import database/[database, entities, store]

proc cleanupDb(path: string) =
  for suffix in ["", "-wal", "-shm"]:
    let p = path & suffix
    if fileExists(p):
      removeFile(p)

proc openTempDb(name: string): tuple[db: BridgeDb, path: string] =
  let dbPath = "tests/fixtures/" & name & "-" & $getTime().toUnix() & "-" & $epochTime().int64 & ".db"
  cleanupDb(dbPath)
  let db = openBridgeDb("file:" & dbPath, "sqlite")
  (db, dbPath)

suite "database store":
  test "user guild portal puppet thread flows":
    let opened = openTempDb("store-core")
    let db = opened.db
    let dbPath = opened.path
    try:
      var user = newUserRecord("@alice:test")
      user.discordId = "u-alice"
      user.discordToken = "token-a"
      user.managementRoom = "!manage:test"
      user.spaceRoom = "!space:test"
      user.dmSpaceRoom = "!dmspace:test"
      user.readStateVersion = 2
      user.heartbeatSessionJson = """{"session":"s1"}"""
      db.insertUser(user)

      let byMxid = db.getUserByMXID("@alice:test")
      check byMxid.found
      check byMxid.rec.discordId == "u-alice"
      check byMxid.rec.readStateVersion == 2

      let byDiscord = db.getUserByDiscordID("u-alice")
      check byDiscord.found
      check byDiscord.rec.mxid == "@alice:test"

      let withToken = db.getAllUsersWithToken()
      check withToken.len == 1
      check withToken[0].mxid == "@alice:test"

      user.discordToken = ""
      user.readStateVersion = 3
      db.updateUser(user)
      let updatedUser = db.getUserByMXID("@alice:test")
      check updatedUser.found
      check updatedUser.rec.discordToken == ""
      check updatedUser.rec.readStateVersion == 3

      var guild = newGuildRecord("guild-1")
      guild.mxid = "!guild:test"
      guild.plainName = "Guild One"
      guild.name = "Guild One"
      guild.nameSet = true
      guild.avatar = "a1"
      guild.avatarUrl = "mxc://test/a1"
      guild.avatarSet = true
      guild.bridgingMode = gbmEverything
      db.insertGuild(guild)

      let guildById = db.getGuildByID("guild-1")
      check guildById.found
      check guildById.rec.bridgingMode == gbmEverything

      let guildByMxid = db.getGuildByMXID("!guild:test")
      check guildByMxid.found
      check guildByMxid.rec.id == "guild-1"

      guild.bridgingMode = gbmIfPortalExists
      db.updateGuild(guild)
      let guildUpdated = db.getGuildByID("guild-1")
      check guildUpdated.found
      check guildUpdated.rec.bridgingMode == gbmIfPortalExists

      var dmPortal = newPortalRecord(PortalKey(channelId: "dm-1", receiver: "u-alice"), 1)
      dmPortal.otherUserId = "u-bob"
      dmPortal.mxid = "!dm1:test"
      dmPortal.plainName = "Bob"
      dmPortal.name = "Bob"
      dmPortal.nameSet = true
      dmPortal.friendNick = true
      dmPortal.topic = "DM"
      dmPortal.topicSet = true
      dmPortal.avatar = "av1"
      dmPortal.avatarUrl = "mxc://test/av1"
      dmPortal.avatarSet = true
      dmPortal.inSpace = "!space:test"
      dmPortal.firstEventId = "$evt1"
      db.insertPortal(dmPortal)

      let portalById = db.getPortalByID(PortalKey(channelId: "dm-1", receiver: "u-alice"))
      check portalById.found
      check portalById.rec.otherUserId == "u-bob"

      let portalByMxid = db.getPortalByMXID("!dm1:test")
      check portalByMxid.found
      check portalByMxid.rec.key.channelId == "dm-1"

      let privateBetween = db.findPrivateChatBetween("u-bob", "u-alice")
      check privateBetween.found
      check privateBetween.rec.key.channelId == "dm-1"

      let privateWith = db.findPrivateChatsWith("u-bob")
      check privateWith.len == 1
      check privateWith[0].key.channelId == "dm-1"

      let privateOf = db.findPrivateChatsOf("u-alice")
      check privateOf.len == 1
      check privateOf[0].otherUserId == "u-bob"

      dmPortal.topic = "Updated DM"
      dmPortal.relayWebhookId = "wh1"
      dmPortal.relayWebhookSecret = "sec1"
      db.updatePortal(dmPortal)
      let dmPortalUpdated = db.getPortalByID(PortalKey(channelId: "dm-1", receiver: "u-alice"))
      check dmPortalUpdated.found
      check dmPortalUpdated.rec.topic == "Updated DM"
      check dmPortalUpdated.rec.relayWebhookId == "wh1"

      var threadParent = newPortalRecord(PortalKey(channelId: "guild-chan-1", receiver: ""), 0)
      threadParent.guildId = "guild-1"
      threadParent.mxid = "!guildchan:test"
      threadParent.plainName = "general"
      threadParent.name = "general"
      threadParent.inSpace = "!guildspace:test"
      threadParent.firstEventId = "$evt-parent"
      db.insertPortal(threadParent)

      var thread = newThreadRecord("thread-1")
      thread.parentChannelId = "guild-chan-1"
      thread.rootDiscordId = "msg-root-1"
      thread.rootMxid = "$mx-root-1"
      thread.creationNoticeMxid = "$mx-create-1"
      db.insertThread(thread)

      let threadByDiscord = db.getThreadByDiscordID("thread-1")
      check threadByDiscord.found
      check threadByDiscord.rec.parentChannelId == "guild-chan-1"

      let threadByRoot = db.getThreadByMatrixRootMsg("$mx-root-1")
      check threadByRoot.found
      check threadByRoot.rec.id == "thread-1"

      let threadByEither = db.getThreadByMatrixRootOrCreationNoticeMsg("$mx-create-1")
      check threadByEither.found
      check threadByEither.rec.id == "thread-1"

      thread.creationNoticeMxid = "$mx-create-2"
      db.updateThread(thread)
      let updatedThread = db.getThreadByDiscordID("thread-1")
      check updatedThread.found
      check updatedThread.rec.creationNoticeMxid == "$mx-create-2"

      var puppet = newPuppetRecord("puppet-1")
      puppet.name = "Alice Puppet"
      puppet.nameSet = true
      puppet.avatar = "pa1"
      puppet.avatarUrl = "mxc://test/pa1"
      puppet.avatarSet = true
      puppet.contactInfoSet = true
      puppet.globalName = "Alice"
      puppet.username = "alice"
      puppet.discriminator = "0001"
      puppet.customMxid = "@alice-puppet:test"
      puppet.accessToken = "accesstoken"
      puppet.nextBatch = "nextbatch"
      db.insertPuppet(puppet)

      let puppetById = db.getPuppetByID("puppet-1")
      check puppetById.found
      check puppetById.rec.username == "alice"

      let puppetByMxid = db.getPuppetByCustomMXID("@alice-puppet:test")
      check puppetByMxid.found
      check puppetByMxid.rec.id == "puppet-1"

      let allPuppets = db.getAllPuppets()
      check allPuppets.len == 1

      let allWithCustom = db.getAllPuppetsWithCustomMXID()
      check allWithCustom.len == 1

      puppet.name = "Alice Puppet Updated"
      db.updatePuppet(puppet)
      let puppetUpdated = db.getPuppetByID("puppet-1")
      check puppetUpdated.found
      check puppetUpdated.rec.name == "Alice Puppet Updated"

      db.deleteThread(thread)
      let deletedThread = db.getThreadByDiscordID("thread-1")
      check not deletedThread.found

      db.deletePortal(dmPortal.key)
      let deletedPortal = db.getPortalByID(dmPortal.key)
      check not deletedPortal.found

      db.deleteGuild("guild-1")
      let deletedGuild = db.getGuildByID("guild-1")
      check not deletedGuild.found
    finally:
      db.close()
      cleanupDb(dbPath)

  test "message and reaction flows":
    let opened = openTempDb("store-message")
    let db = opened.db
    let dbPath = opened.path
    try:
      var parentGuild = newGuildRecord("guild-msg")
      parentGuild.name = "Messages"
      parentGuild.plainName = "Messages"
      db.insertGuild(parentGuild)

      let portalKey = PortalKey(channelId: "chan-msg", receiver: "recv-1")
      var portal = newPortalRecord(portalKey, 0)
      portal.guildId = "guild-msg"
      portal.mxid = "!chan-msg:test"
      portal.plainName = "chan"
      portal.name = "chan"
      portal.firstEventId = "$evt-chan"
      db.insertPortal(portal)

      var msg1 = newMessageRecord("dmsg-1", "att-1")
      msg1.channelId = portalKey.channelId
      msg1.channelReceiver = portalKey.receiver
      msg1.senderId = "sender-1"
      msg1.timestampMs = 1000
      msg1.threadId = "thread-msg"
      msg1.mxid = "$mx-msg-1"
      msg1.senderMxid = "@sender:test"
      db.insertMessage(msg1)

      var msg2 = newMessageRecord("dmsg-1", "att-2")
      msg2.channelId = portalKey.channelId
      msg2.channelReceiver = portalKey.receiver
      msg2.senderId = "sender-1"
      msg2.timestampMs = 2000
      msg2.threadId = "thread-msg"
      msg2.mxid = "$mx-msg-2"
      msg2.senderMxid = "@sender:test"
      db.insertMessage(msg2)

      let all = db.getMessagesByDiscordID(portalKey, "dmsg-1")
      check all.len == 2
      check all[0].attachmentId == "att-1"
      check all[1].attachmentId == "att-2"

      let first = db.getFirstMessageByDiscordID(portalKey, "dmsg-1")
      check first.found
      check first.rec.attachmentId == "att-1"

      let lastById = db.getLastMessageByDiscordID(portalKey, "dmsg-1")
      check lastById.found
      check lastById.rec.attachmentId == "att-2"

      let byMxid = db.getMessageByMXID(portalKey, "$mx-msg-2")
      check byMxid.found
      check byMxid.rec.discordId == "dmsg-1"

      let last = db.getLastMessage(portalKey)
      check last.found
      check last.rec.timestampMs == 2000

      let lastInThread = db.getLastMessageInThread(portalKey, "thread-msg")
      check lastInThread.found
      check lastInThread.rec.attachmentId == "att-2"

      let closest = db.getClosestMessageBefore(portalKey, "thread-msg", 1500)
      check closest.found
      check closest.rec.attachmentId == "att-1"

      db.updateMessageEditTimestamp(msg1, 9999)
      db.updateMessageEditTimestamp(msg1, 100)
      let msg1Updated = db.getFirstMessageByDiscordID(portalKey, "dmsg-1")
      check msg1Updated.found
      check msg1Updated.rec.editTimestampNs == 9999

      var bulkA = newMessageRecord("bulk-1", "a1")
      bulkA.senderId = "sender-2"
      bulkA.timestampMs = 3000
      bulkA.threadId = ""
      bulkA.mxid = "$bulk-1"
      bulkA.senderMxid = "@bulk:test"

      var bulkB = newMessageRecord("bulk-2", "a1")
      bulkB.senderId = "sender-2"
      bulkB.timestampMs = 3100
      bulkB.threadId = ""
      bulkB.mxid = "$bulk-2"
      bulkB.senderMxid = "@bulk:test"
      db.massInsertMessages(portalKey, @[bulkA, bulkB])

      var base = newMessageRecord("bulk-part", "p0")
      base.channelId = portalKey.channelId
      base.channelReceiver = portalKey.receiver
      base.senderId = "sender-3"
      base.timestampMs = 3200
      base.threadId = ""
      base.senderMxid = "@bulk:test"
      db.massInsertMessageParts(base, @[
        MessagePart(attachmentId: "p1", mxid: "$bulk-part-1"),
        MessagePart(attachmentId: "p2", mxid: "$bulk-part-2")
      ])

      let bulkMsgs = db.getMessagesByDiscordID(portalKey, "bulk-part")
      check bulkMsgs.len == 2

      var reaction = newReactionRecord()
      reaction.channelId = portalKey.channelId
      reaction.channelReceiver = portalKey.receiver
      reaction.messageId = "dmsg-1"
      reaction.firstAttachmentId = "att-1"
      reaction.sender = "sender-1"
      reaction.emojiName = "thumbsup"
      reaction.threadId = "thread-msg"
      reaction.mxid = "$mx-react-1"
      db.insertReaction(reaction)

      let reactions = db.getAllReactionsForMessage(portalKey, "dmsg-1")
      check reactions.len == 1
      check reactions[0].emojiName == "thumbsup"

      let byDiscordReaction = db.getReactionByDiscordID(portalKey, "dmsg-1", "sender-1", "thumbsup")
      check byDiscordReaction.found
      check byDiscordReaction.rec.mxid == "$mx-react-1"

      let byMxidReaction = db.getReactionByMXID("$mx-react-1")
      check byMxidReaction.found
      check byMxidReaction.rec.threadId == "thread-msg"
      check byMxidReaction.rec.discordProtoChannelID() == "thread-msg"

      db.deleteReaction(reaction)
      let deletedReaction = db.getReactionByMXID("$mx-react-1")
      check not deletedReaction.found

      db.deleteMessage(msg1)
      let afterDeleteOne = db.getMessagesByDiscordID(portalKey, "dmsg-1")
      check afterDeleteOne.len == 1
      check afterDeleteOne[0].attachmentId == "att-2"

      db.deleteAllMessages(portalKey)
      let afterDeleteAll = db.getLastMessage(portalKey)
      check not afterDeleteAll.found
    finally:
      db.close()
      cleanupDb(dbPath)

  test "role file and user_portal flows":
    let opened = openTempDb("store-misc")
    let db = opened.db
    let dbPath = opened.path
    try:
      var guild = newGuildRecord("guild-role")
      guild.name = "Guild Roles"
      guild.plainName = "Guild Roles"
      db.insertGuild(guild)

      var role = newRoleRecord("guild-role", "role-1")
      role.name = "Admin"
      role.icon = "icon-1"
      role.mentionable = true
      role.managed = false
      role.hoist = true
      role.color = 12345
      role.position = 3
      role.permissions = 8
      db.upsertRole(role)

      let roleById = db.getRoleByID("guild-role", "role-1")
      check roleById.found
      check roleById.rec.name == "Admin"

      role.name = "Moderator"
      db.upsertRole(role)
      let roleUpdated = db.getRoleByID("guild-role", "role-1")
      check roleUpdated.found
      check roleUpdated.rec.name == "Moderator"

      let allRoles = db.getAllRoles("guild-role")
      check allRoles.len == 1

      db.deleteRoleByID("guild-role", "role-1")
      let deletedRole = db.getRoleByID("guild-role", "role-1")
      check not deletedRole.found

      var fileRec = newFileRecord("https://cdn.example/file.png", false)
      fileRec.mxc = "mxc://example/file"
      fileRec.id = "file-1"
      fileRec.emojiName = "smile"
      fileRec.size = 321
      fileRec.width = 64
      fileRec.height = 64
      fileRec.mimeType = "image/png"
      fileRec.decryptionInfoJson = """{"kty":"oct"}"""
      fileRec.timestampMs = 111
      db.insertFile(fileRec)

      let fileByKey = db.getFile("https://cdn.example/file.png", false)
      check fileByKey.found
      check fileByKey.rec.id == "file-1"
      check fileByKey.rec.width == 64

      let fileByEmoji = db.getEmojiFileByMXC("mxc://example/file")
      check fileByEmoji.found
      check fileByEmoji.rec.emojiName == "smile"

      db.deleteFile("https://cdn.example/file.png", false)
      let deletedFile = db.getFile("https://cdn.example/file.png", false)
      check not deletedFile.found

      var alice = newUserRecord("@alice:test")
      alice.discordId = "alice-discord"
      db.insertUser(alice)

      var bob = newUserRecord("@bob:test")
      bob.discordId = "bob-discord"
      db.insertUser(bob)

      db.markUserInPortal(UserPortalRecord(
        discordId: "chan-shared",
        userMxid: "@alice:test",
        portalType: "dm",
        inSpace: true,
        timestampMs: 100
      ))
      db.markUserInPortal(UserPortalRecord(
        discordId: "chan-shared",
        userMxid: "@bob:test",
        portalType: "dm",
        inSpace: false,
        timestampMs: 90
      ))
      db.markUserInPortal(UserPortalRecord(
        discordId: "chan-dm-old",
        userMxid: "@alice:test",
        portalType: "dm",
        inSpace: false,
        timestampMs: 10
      ))
      db.markUserInPortal(UserPortalRecord(
        discordId: "chan-guild-old",
        userMxid: "@alice:test",
        portalType: "guild",
        inSpace: false,
        timestampMs: 20
      ))
      db.markUserInPortal(UserPortalRecord(
        discordId: "chan-thread-old",
        userMxid: "@alice:test",
        portalType: "thread",
        inSpace: false,
        timestampMs: 30
      ))
      db.markUserInPortal(UserPortalRecord(
        discordId: "chan-dm-new",
        userMxid: "@alice:test",
        portalType: "dm",
        inSpace: true,
        timestampMs: 200
      ))

      let sharedUsers = db.getUsersInPortal("chan-shared")
      check sharedUsers.len == 2
      check sharedUsers.contains("@alice:test")
      check sharedUsers.contains("@bob:test")

      let alicePortals = db.getUserPortals("@alice:test")
      check alicePortals.len == 5

      check db.isUserInPortal("@alice:test", "chan-shared")
      check db.isUserInSpace("@alice:test", "chan-shared")
      check db.portalHasOtherUsers("@alice:test", "chan-shared")

      db.markUserNotInPortal("@bob:test", "chan-shared")
      check not db.portalHasOtherUsers("@alice:test", "chan-shared")

      let pruned = db.pruneUserPortals("@alice:test", 60)
      check pruned.len == 2
      for rec in pruned:
        check rec.portalType == "dm" or rec.portalType == "guild"

      let remaining = db.getUserPortals("@alice:test")
      var hasThread = false
      var hasNewDm = false
      for rec in remaining:
        if rec.discordId == "chan-thread-old":
          hasThread = true
        if rec.discordId == "chan-dm-new":
          hasNewDm = true
      check hasThread
      check hasNewDm
    finally:
      db.close()
      cleanupDb(dbPath)
