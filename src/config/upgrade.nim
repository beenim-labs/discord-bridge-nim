## Config upgrade helper adapted from config/upgrade.go.
## Operates on flattened YAML key/value maps used by simple_yaml.

import std/[random, strutils, tables]
import common/simple_yaml

type
  SecretGenerator* = proc(length: int): string {.closure, gcsafe.}
  SigningKeyGenerator* = proc(): string {.closure, gcsafe.}

const AlphaNum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

proc defaultSecret(length: int): string {.gcsafe.} =
  if length <= 0:
    return ""
  randomize()
  result = newString(length)
  for i in 0 ..< length:
    result[i] = AlphaNum[rand(AlphaNum.high)]

proc defaultSigningKey(): string {.gcsafe.} =
  "ed25519:auto:" & defaultSecret(32)

proc makeSecret(secretGenerator: SecretGenerator, length: int): string {.gcsafe.} =
  if secretGenerator == nil:
    return defaultSecret(length)
  secretGenerator(length)

proc makeSigningKey(signingKeyGenerator: SigningKeyGenerator): string {.gcsafe.} =
  if signingKeyGenerator == nil:
    return defaultSigningKey()
  signingKeyGenerator()

proc copyKey(source: YamlMap, target: var YamlMap, key: string) =
  if source.hasKey(key):
    target[key] = source[key]

proc copyPrefix(source: YamlMap, target: var YamlMap, prefix: string) =
  let prefixWithDot = prefix & "."
  for key, value in source:
    if key == prefix or key.startsWith(prefixWithDot):
      target[key] = value

proc parseLegacyPrivateChatPortalMeta(raw: string): string =
  case raw.toLowerAscii().strip()
  of "true":
    "always"
  of "false":
    "default"
  else:
    raw

proc doUpgrade*(
    source: YamlMap,
    secretGenerator: SecretGenerator = nil,
    signingKeyGenerator: SigningKeyGenerator = nil
): YamlMap =
  result = initTable[string, string]()

  let scalarKeys = @[
    "bridge.username_template",
    "bridge.displayname_template",
    "bridge.channel_name_template",
    "bridge.guild_name_template",
    "bridge.startup_private_channel_create_limit",
    "bridge.public_address",
    "bridge.portal_message_buffer",
    "bridge.delivery_receipts",
    "bridge.message_status_events",
    "bridge.message_error_notices",
    "bridge.restricted_rooms",
    "bridge.autojoin_thread_on_open",
    "bridge.embed_fields_as_tables",
    "bridge.mute_channels_on_create",
    "bridge.sync_direct_chat_list",
    "bridge.resend_bridge_info",
    "bridge.custom_emoji_reactions",
    "bridge.delete_portal_on_channel_delete",
    "bridge.delete_guild_on_leave",
    "bridge.federate_rooms",
    "bridge.prefix_webhook_messages",
    "bridge.enable_webhook_avatars",
    "bridge.use_discord_cdn_upload",
    "bridge.proxy",
    "bridge.cache_media",
    "bridge.command_prefix",
    "bridge.animated_sticker.target",
    "bridge.animated_sticker.args.width",
    "bridge.animated_sticker.args.height",
    "bridge.animated_sticker.args.fps",
    "bridge.backfill.enabled",
    "bridge.backfill.forward_limits.initial.dm",
    "bridge.backfill.forward_limits.initial.channel",
    "bridge.backfill.forward_limits.initial.thread",
    "bridge.backfill.forward_limits.missed.dm",
    "bridge.backfill.forward_limits.missed.channel",
    "bridge.backfill.forward_limits.missed.thread",
    "bridge.backfill.max_guild_members",
    "bridge.encryption.allow",
    "bridge.encryption.default",
    "bridge.encryption.require",
    "bridge.encryption.appservice",
    "bridge.encryption.msc4190",
    "bridge.encryption.allow_key_sharing",
    "bridge.encryption.plaintext_mentions",
    "bridge.encryption.delete_keys.delete_outbound_on_ack",
    "bridge.encryption.delete_keys.dont_store_outbound",
    "bridge.encryption.delete_keys.ratchet_on_decrypt",
    "bridge.encryption.delete_keys.delete_fully_used_on_decrypt",
    "bridge.encryption.delete_keys.delete_prev_on_new_session",
    "bridge.encryption.delete_keys.delete_on_device_delete",
    "bridge.encryption.delete_keys.periodically_delete_expired",
    "bridge.encryption.delete_keys.delete_outdated_inbound",
    "bridge.encryption.verification_levels.receive",
    "bridge.encryption.verification_levels.send",
    "bridge.encryption.verification_levels.share",
    "bridge.encryption.rotation.enable_custom",
    "bridge.encryption.rotation.milliseconds",
    "bridge.encryption.rotation.messages",
    "bridge.encryption.rotation.disable_device_change_key_rotation",
    "bridge.provisioning.prefix",
    "bridge.provisioning.debug_endpoints",
    "bridge.direct_media.enabled",
    "bridge.direct_media.server_name",
    "bridge.direct_media.well_known_response",
    "bridge.direct_media.allow_proxy"
  ]
  for key in scalarKeys:
    source.copyKey(result, key)

  if source.hasKey("bridge.private_chat_portal_meta"):
    result["bridge.private_chat_portal_meta"] = parseLegacyPrivateChatPortalMeta(source["bridge.private_chat_portal_meta"])

  let avatarProxyKey = source.getOrDefault("bridge.avatar_proxy_key", "")
  if avatarProxyKey.len == 0 or avatarProxyKey == "generate":
    result["bridge.avatar_proxy_key"] = makeSecret(secretGenerator, 32)
  else:
    result["bridge.avatar_proxy_key"] = avatarProxyKey

  let sharedSecret = source.getOrDefault("bridge.provisioning.shared_secret", "")
  if sharedSecret.len == 0 or sharedSecret == "generate":
    result["bridge.provisioning.shared_secret"] = makeSecret(secretGenerator, 64)
  else:
    result["bridge.provisioning.shared_secret"] = sharedSecret

  let serverKey = source.getOrDefault("bridge.direct_media.server_key", "")
  if serverKey.len == 0 or serverKey == "generate":
    result["bridge.direct_media.server_key"] = makeSigningKey(signingKeyGenerator)
  else:
    result["bridge.direct_media.server_key"] = serverKey

  source.copyPrefix(result, "bridge.management_room_text")
  source.copyPrefix(result, "bridge.permissions")
  source.copyPrefix(result, "bridge.double_puppet_server_map")
  source.copyPrefix(result, "bridge.login_shared_secret_map")
  source.copyPrefix(result, "bridge.encryption")
