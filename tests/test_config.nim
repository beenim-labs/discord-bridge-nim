import std/[unittest, tables]
import config/config

suite "config":
  test "load sample config":
    let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
    check cfg.appservice.id == "discord"
    check cfg.appservice.port == 29334
    check cfg.appservice.bot.username == "discordbot"
    check cfg.bridge.commandPrefix == "!discord"
    check cfg.bridge.directMedia.serverName == "discord-media.example.com"
    check cfg.bridge.backfill.initial.dm == 200
    check cfg.bridge.backfill.missed.dm == -1
    check cfg.homeserver.domain == "localhost"

    let v = cfg.validate()
    check v.ok

  test "invalid config fails validation":
    var cfg = defaultConfig()
    cfg.appservice.port = 0
    let v = cfg.validate()
    check not v.ok

  test "bridge template formatting helpers":
    let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
    let bc = cfg.bridge

    check bc.getResendBridgeInfo() == false
    check bc.enableMessageStatusEvents() == false
    check bc.enableMessageErrorNotices() == true
    check bc.getCommandPrefix() == "!discord"
    check bc.formatUsername("123456") == "discord_123456"

    let display = bc.formatDisplayname(DisplaynameParams(
      globalName: "Alice Name",
      username: "alice",
      discriminator: "0001",
      webhook: false,
      application: false,
      bot: true
    ))
    check display == "Alice Name (bot)"

    let webhookDisplay = bc.formatDisplayname(DisplaynameParams(
      globalName: "",
      username: "ignored",
      discriminator: "0001",
      webhook: true,
      application: false,
      bot: false
    ))
    check webhookDisplay == "Webhook"

    check bc.formatChannelName(ChannelNameParams(name: "general", channelType: 0)) == "#general"
    check bc.formatChannelName(ChannelNameParams(name: "group", channelType: 3)) == "group"
    check bc.formatGuildName(GuildNameParams(name: "Guild A")) == "Guild A"

  test "bridge template parse and permissions validation":
    var bc = defaultConfig().bridge
    bc.usernameTemplate = "discord_{{.}}"
    bc.displaynameTemplate = "{{.Username}}"
    bc.channelNameTemplate = "{{.Name}}"
    bc.guildNameTemplate = "{{.Name}}"
    let parsed = bc.parseBridgeTemplates()
    check parsed.ok

    bc.usernameTemplate = "discord_no_placeholder"
    let badParsed = bc.parseBridgeTemplates()
    check not badParsed.ok

    bc.permissions = initTable[string, string]()
    bc.permissions["*"] = "relay"
    bc.permissions["@admin:example.com"] = "admin"
    bc.permissions["example.com"] = "user"
    let badPerms = bc.validateBridgeConfig()
    check not badPerms.ok

    bc.permissions["@real:localhost"] = "admin"
    let okPerms = bc.validateBridgeConfig()
    check okPerms.ok

  test "auto double puppet homeserver map lookup":
    var cfg = defaultConfig()
    cfg.bridge.doublePuppet["server_map.localhost"] = "secret-local"
    cfg.bridge.doublePuppet["example.com"] = "secret-example"
    cfg.bridge.doublePuppet["server_map.empty.example"] = ""

    check cfg.canAutoDoublePuppet("@alice:localhost")
    check cfg.canAutoDoublePuppet("@bob:example.com")
    check not cfg.canAutoDoublePuppet("@carol:missing.example")
    check not cfg.canAutoDoublePuppet("@dave:empty.example")
    check not cfg.canAutoDoublePuppet("not-a-user-id")
