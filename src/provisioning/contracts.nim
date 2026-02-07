## Typed provisioning API contracts and error constants.

import std/json

const
  SecWebSocketProtocol* = "com.gitlab.beeper.discord"

  ErrCodeUnknownToken* = "M_UNKNOWN_TOKEN"
  ErrCodeBadJson* = "M_BAD_JSON"
  ErrCodeNotFound* = "M_NOT_FOUND"

  ErrCodeNotConnected* = "FI.MAU.DISCORD.NOT_CONNECTED"
  ErrCodeAlreadyLoggedIn* = "FI.MAU.DISCORD.ALREADY_LOGGED_IN"
  ErrCodeAlreadyConnected* = "FI.MAU.DISCORD.ALREADY_CONNECTED"
  ErrCodeConnectFailed* = "FI.MAU.DISCORD.CONNECT_FAILED"
  ErrCodeDisconnectFailed* = "FI.MAU.DISCORD.DISCONNECT_FAILED"
  ErrCodeLoginPrepareFailed* = "FI.MAU.DISCORD.LOGIN_PREPARE_FAILED"
  ErrCodeLoginConnectionFailed* = "FI.MAU.DISCORD.LOGIN_CONN_FAILED"
  ErrCodeLoginFailed* = "FI.MAU.DISCORD.LOGIN_FAILED"
  ErrCodePostLoginConnFailed* = "FI.MAU.DISCORD.POST_LOGIN_CONNECTION_FAILED"

proc successResponse*(status: string): JsonNode =
  %*{
    "success": true,
    "status": status
  }

proc errorResponse*(message, errcode: string): JsonNode =
  %*{
    "success": false,
    "error": message,
    "errcode": errcode
  }

proc loginResponse*(id, username, discriminator: string): JsonNode =
  %*{
    "success": true,
    "id": id,
    "username": username,
    "discriminator": discriminator
  }

proc pingResponse*(
    mxid,
    managementRoom,
    discordId: string,
    loggedIn,
    connected: bool,
    lastHeartbeatAck,
    lastHeartbeatSent: int64
): JsonNode =
  %*{
    "mxid": mxid,
    "management_room": managementRoom,
    "discord": {
      "id": discordId,
      "logged_in": loggedIn,
      "connected": connected,
      "conn": {
        "last_heartbeat_ack": lastHeartbeatAck,
        "last_heartbeat_sent": lastHeartbeatSent
      }
    }
  }
