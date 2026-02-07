## Channel bridgeability policy adapted from discord.go.

const
  ChannelTypeGuildText* = 0
  ChannelTypeDM* = 1
  ChannelTypeGuildVoice* = 2
  ChannelTypeGroupDM* = 3
  ChannelTypeGuildCategory* = 4
  ChannelTypeGuildNews* = 5

type
  ChannelBridgeabilityInput* = object
    channelType*: int
    permissionKnown*: bool
    canViewChannel*: bool

proc channelIsBridgeable*(input: ChannelBridgeabilityInput): bool =
  case input.channelType
  of ChannelTypeGuildText, ChannelTypeGuildNews:
    if not input.permissionKnown:
      return true
    input.canViewChannel
  of ChannelTypeDM, ChannelTypeGroupDM:
    true
  else:
    false
