import std/[unittest, tables, strutils]
import config/upgrade

proc fixedSecret(length: int): string =
  repeat("s", length)

proc fixedKey(): string =
  "ed25519:test-key"

suite "config upgrade":
  test "doUpgrade migrates legacy private chat value and generates secrets":
    var source = initTable[string, string]()
    source["bridge.username_template"] = "discord_{{.}}"
    source["bridge.private_chat_portal_meta"] = "true"
    source["bridge.avatar_proxy_key"] = "generate"
    source["bridge.provisioning.shared_secret"] = "generate"
    source["bridge.direct_media.server_key"] = "generate"
    source["bridge.management_room_text.welcome"] = "hello"
    source["bridge.permissions.@admin:example.com"] = "admin"
    source["bridge.double_puppet_server_map.example.com"] = "https://example.com"
    source["bridge.login_shared_secret_map.example.com"] = "secret"

    let upgraded = doUpgrade(source, fixedSecret, fixedKey)
    check upgraded["bridge.username_template"] == "discord_{{.}}"
    check upgraded["bridge.private_chat_portal_meta"] == "always"
    check upgraded["bridge.avatar_proxy_key"] == repeat("s", 32)
    check upgraded["bridge.provisioning.shared_secret"] == repeat("s", 64)
    check upgraded["bridge.direct_media.server_key"] == "ed25519:test-key"
    check upgraded["bridge.management_room_text.welcome"] == "hello"
    check upgraded["bridge.permissions.@admin:example.com"] == "admin"
    check upgraded["bridge.double_puppet_server_map.example.com"] == "https://example.com"
    check upgraded["bridge.login_shared_secret_map.example.com"] == "secret"

  test "doUpgrade keeps explicit secret values and false legacy mode":
    var source = initTable[string, string]()
    source["bridge.private_chat_portal_meta"] = "false"
    source["bridge.avatar_proxy_key"] = "existing-avatar-key"
    source["bridge.provisioning.shared_secret"] = "existing-shared"
    source["bridge.direct_media.server_key"] = "ed25519:existing"

    let upgraded = doUpgrade(source, fixedSecret, fixedKey)
    check upgraded["bridge.private_chat_portal_meta"] == "default"
    check upgraded["bridge.avatar_proxy_key"] == "existing-avatar-key"
    check upgraded["bridge.provisioning.shared_secret"] == "existing-shared"
    check upgraded["bridge.direct_media.server_key"] == "ed25519:existing"
