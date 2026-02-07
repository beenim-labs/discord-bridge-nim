## Discord REST client primitives used by bridge runtime flows.

import std/[httpclient, json, strutils, uri]

type
  DiscordRestClient* = ref object
    token*: string
    baseUrl*: string
    userAgent*: string
    http*: HttpClient

  DiscordRestResult* = tuple[ok: bool, status: int, body: JsonNode, err: string]

proc normalizeBaseUrl(base: string): string =
  var b = base.strip()
  if b.endsWith("/"):
    b.setLen(b.len - 1)
  b

proc newDiscordRestClient*(token: string, baseUrl = "https://discord.com/api/v10", userAgent = "DiscordBot (bridge-discord-nim, 0.1.0)"): DiscordRestClient =
  DiscordRestClient(
    token: token,
    baseUrl: normalizeBaseUrl(baseUrl),
    userAgent: userAgent,
    http: newHttpClient()
  )

proc buildHeaders(c: DiscordRestClient): HttpHeaders =
  var h = newHttpHeaders()
  h["Authorization"] = c.token
  h["User-Agent"] = c.userAgent
  h["Content-Type"] = "application/json"
  h

proc request*(c: DiscordRestClient, httpMethod: HttpMethod, path: string, payload: JsonNode = newJNull()): DiscordRestResult =
  let url = c.baseUrl & path
  var data = ""
  if payload.kind != JNull:
    data = $payload

  c.http.headers = c.buildHeaders()
  try:
    let resp = if data.len > 0:
      c.http.request(url, httpMethod, body = data)
    else:
      c.http.request(url, httpMethod)

    let raw = resp.body
    var body = newJNull()
    if raw.len > 0:
      try:
        body = parseJson(raw)
      except CatchableError:
        body = %*{"raw": raw}
    (resp.code.is2xx, int(resp.code), body, "")
  except CatchableError as e:
    (false, 0, newJNull(), e.msg)

proc getCurrentUser*(c: DiscordRestClient): DiscordRestResult =
  c.request(HttpGet, "/users/@me")

proc getGuildChannels*(c: DiscordRestClient, guildId: string): DiscordRestResult =
  c.request(HttpGet, "/guilds/" & guildId.encodeUrl() & "/channels")

proc getChannel*(c: DiscordRestClient, channelId: string): DiscordRestResult =
  c.request(HttpGet, "/channels/" & channelId.encodeUrl())

proc createMessage*(c: DiscordRestClient, channelId: string, content: JsonNode): DiscordRestResult =
  c.request(HttpPost, "/channels/" & channelId.encodeUrl() & "/messages", content)

proc editMessage*(c: DiscordRestClient, channelId, messageId: string, content: JsonNode): DiscordRestResult =
  c.request(HttpPatch, "/channels/" & channelId.encodeUrl() & "/messages/" & messageId.encodeUrl(), content)

proc deleteMessage*(c: DiscordRestClient, channelId, messageId: string): DiscordRestResult =
  c.request(HttpDelete, "/channels/" & channelId.encodeUrl() & "/messages/" & messageId.encodeUrl())

proc addReaction*(c: DiscordRestClient, channelId, messageId, emoji: string): DiscordRestResult =
  c.request(HttpPut, "/channels/" & channelId.encodeUrl() & "/messages/" & messageId.encodeUrl() & "/reactions/" & emoji.encodeUrl() & "/@me")

proc removeReaction*(c: DiscordRestClient, channelId, messageId, emoji: string): DiscordRestResult =
  c.request(HttpDelete, "/channels/" & channelId.encodeUrl() & "/messages/" & messageId.encodeUrl() & "/reactions/" & emoji.encodeUrl() & "/@me")
