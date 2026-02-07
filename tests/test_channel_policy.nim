import std/unittest
import discord/channel_policy

suite "discord channel policy":
  test "guild text and news require view permission when known":
    check channelIsBridgeable(ChannelBridgeabilityInput(
      channelType: ChannelTypeGuildText,
      permissionKnown: true,
      canViewChannel: true
    ))
    check not channelIsBridgeable(ChannelBridgeabilityInput(
      channelType: ChannelTypeGuildNews,
      permissionKnown: true,
      canViewChannel: false
    ))

  test "guild text defaults to bridgeable when permission lookup fails":
    check channelIsBridgeable(ChannelBridgeabilityInput(
      channelType: ChannelTypeGuildText,
      permissionKnown: false,
      canViewChannel: false
    ))

  test "dm and group dm are always bridgeable":
    check channelIsBridgeable(ChannelBridgeabilityInput(channelType: ChannelTypeDM))
    check channelIsBridgeable(ChannelBridgeabilityInput(channelType: ChannelTypeGroupDM))

  test "unsupported channel types are not bridgeable":
    check not channelIsBridgeable(ChannelBridgeabilityInput(channelType: ChannelTypeGuildVoice))
    check not channelIsBridgeable(ChannelBridgeabilityInput(channelType: ChannelTypeGuildCategory))
