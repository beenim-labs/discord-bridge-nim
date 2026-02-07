import std/[strutils, times, unittest]
import msgconv/[formatter, formatter_tag, formatter_everyone]

suite "formatter":
  test "escape discord markdown parity cases":
    let tests = @[
      ("Simple text", "Lorem ipsum dolor sit amet, consectetuer adipiscing elit.", "Lorem ipsum dolor sit amet, consectetuer adipiscing elit."),
      ("Backslash", """foo\bar""", """foo\\bar"""),
      ("Underscore", "foo_bar", "foo\\_bar"),
      ("Asterisk", "foo*bar", "foo\\*bar"),
      ("Tilde", "foo~bar", "foo\\~bar"),
      ("Backtick", "foo`bar", "foo\\`bar"),
      ("Forward tick", "foo´bar", "foo´bar"),
      ("Pipe", "foo|bar", "foo\\|bar"),
      ("Less than", "foo<bar", "foo\\<bar"),
      ("Greater than", "foo>bar", "foo>bar"),
      ("Multiple things", """\_*~|""", """\\\_\*\~\|"""),
      ("URL", "https://example.com/foo_bar", "https://example.com/foo_bar"),
      ("Multiple URLs", "hello_world https://example.com/foo_bar *testing* https://a_b_c/*def*", "hello\\_world https://example.com/foo_bar \\*testing\\* https://a_b_c/*def*"),
      ("URL ends with no-break zero-width space", "https://example.com\ufefffoo_bar", "https://example.com\ufefffoo\\_bar"),
      ("URL ends with less than", "https://example.com<foo_bar", "https://example.com<foo\\_bar"),
      ("Short URL", "https://_", "https://_"),
      ("Insecure URL", "http://example.com/foo_bar", "http://example.com/foo_bar")
    ]
    for tc in tests:
      check escapeDiscordMarkdown(tc[1]) == tc[2]

  test "appendIfNotContains keeps uniqueness":
    check appendIfNotContains(@["a", "b"], "c") == @["a", "b", "c"]
    check appendIfNotContains(@["a", "b"], "b") == @["a", "b"]

  test "pill converter room and mention resolution":
    var ctx = PillConvertContext(
      resolveAliasRoom: proc(alias: string): string =
        if alias == "#room:test":
          "!roomid:test"
        else:
          "",
      resolveRoomMention: proc(roomId, eventId: string): string =
        if eventId.len == 0:
          "<#123>"
        else:
          "https://discord.com/channels/g/c/m",
      resolveUserMention: proc(mxid: string): string =
        if mxid == "@alice:test":
          "555"
        else:
          "",
      inputAllowedMentions: @["@alice:test"]
    )

    check pillConverter("room", "#room:test", "", ctx) == "<#123>"
    check pillConverter("event", "!roomid:test", "$e", ctx) == "https://discord.com/channels/g/c/m"
    check pillConverter("alice", "@alice:test", "", ctx) == "<@555>"
    check ctx.allowedMentions == @["555"]
    check pillConverter("blocked", "@bob:test", "", ctx) == "blocked"

  test "parse matrix html falls back to escaped text":
    var ctx = PillConvertContext()
    let parsed = parseMatrixHTML(
      MatrixHtmlMessage(
        body: "a_b",
        format: "",
        formattedBody: "",
        mentionedUserIds: @[]
      ),
      @[],
      ctx
    )
    check parsed.text == "a\\_b"
    check parsed.allowedMentions.repliedUser

suite "formatter tag":
  test "parse user role channel timestamp emoji tags":
    let user = parseTag("<@123>")
    check user.ok
    check user.tag.kind == dtkUserMention
    check user.tag.id == 123'u64
    check user.tag.hasNick == false
    check userMentionString(user.tag.id, user.tag.hasNick) == "<@123>"

    let nick = parseTag("<@!123>")
    check nick.ok
    check nick.tag.hasNick

    let role = parseTag("<@&42>")
    check role.ok
    check role.tag.kind == dtkRoleMention
    check roleMentionString(role.tag.id) == "<@&42>"

    let channel = parseTag("<#222:333:general>")
    check channel.ok
    check channel.tag.kind == dtkChannelMention
    check channelMentionString(channel.tag.id, channel.tag.guildId, channel.tag.channelName) == "<#222:333:general>"

    let ts = parseTag("<t:1735689600:R>")
    check ts.ok
    check ts.tag.kind == dtkTimestamp
    check timestampString(ts.tag.timestamp, ts.tag.style) == "<t:1735689600:R>"

    let emoji = parseTag("<a:party:555>")
    check emoji.ok
    check emoji.tag.kind == dtkCustomEmoji
    check emoji.tag.animated
    check emoji.tag.emojiName == ":party:"
    check customEmojiString(emoji.tag.id, emoji.tag.emojiName, emoji.tag.animated) == "<a:party:555>"

  test "relative time format deterministic":
    let now = fromUnix(1_700_000_000)
    check relativeTimeFormat(fromUnix(1_700_000_005), now) == "in 5 seconds"
    check relativeTimeFormat(fromUnix(1_699_999_995), now) == "5 seconds ago"

  test "render mention html with resolver callbacks":
    let renderer = defaultDiscordTagHtmlRenderer
    let userTag = parseTag("<@123>")
    check userTag.ok
    let roleTag = parseTag("<@&444>")
    check roleTag.ok
    let channelTag = parseTag("<#987>")
    check channelTag.ok
    let emojiTag = parseTag("<:blob:777>")
    check emojiTag.ok

    let ctx = DiscordTagRenderContext(
      resolveUser: proc(id: uint64): DiscordUserInfo =
        if id == 123'u64: DiscordUserInfo(mxid: "@alice:test", name: "alice") else: DiscordUserInfo(),
      resolveRole: proc(id: uint64): DiscordRoleInfo =
        if id == 444'u64: DiscordRoleInfo(name: "admins", color: 0xABCDEF) else: DiscordRoleInfo(),
      resolveChannel: proc(id: uint64): DiscordChannelInfo =
        if id == 987'u64: DiscordChannelInfo(name: "general", mxid: "!room:test") else: DiscordChannelInfo(),
      resolveEmojiMxc: proc(id: uint64, name: string, animated: bool): string =
        if id == 777'u64 and name == ":blob:" and not animated: "mxc://hs/blob" else: ""
    )

    check renderer.renderDiscordMention(userTag.tag, true, ctx).contains("""href="https://matrix.to/#/@alice:test"""")
    check renderer.renderDiscordMention(roleTag.tag, true, ctx).contains("""@admins""")
    check renderer.renderDiscordMention(channelTag.tag, true, ctx).contains("""href="https://matrix.to/#/!room:test"""")
    check renderer.renderDiscordMention(emojiTag.tag, true, ctx).contains("""src="mxc://hs/blob"""")

suite "formatter everyone":
  test "parse and render everyone/here mentions":
    let parser = defaultDiscordEveryoneParser
    let parsedEveryone = parser.parse("@everyone hi")
    check parsedEveryone.ok
    check parsedEveryone.node.toDiscordString() == "@everyone"
    check parsedEveryone.consumed == "@everyone".len

    let parsedHere = parser.parse("@here")
    check parsedHere.ok
    check parsedHere.node.onlyHere
    check parsedHere.node.kind() == DiscordEveryoneKind

    let renderer = defaultDiscordEveryoneHtmlRenderer
    check renderer.renderDiscordEveryone(parsedEveryone.node, entering = true) == """<span class="discord-mention-everyone">@room</span>"""
    check renderer.renderDiscordEveryone(parsedHere.node, entering = true) == """<span class="discord-mention-here">@room</span>"""
