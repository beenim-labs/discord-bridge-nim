# bridge-discord-nim

Nim v2 rewrite foundation for `mautrix-discord` with drop-in CLI contract.

## Implemented in this baseline

- `mautrix-discord` CLI contract:
  - `-g -c <config> -r <registration>` registration generation
  - `-c <config> -r <registration>` runtime startup
- Config compatibility parser for core `mautrix-discord.yaml` keys.
- Appservice registration writer/reader.
- Native appservice HTTP server with:
  - transaction dedupe + auth
  - transaction parsing (`events` + ephemeral)
  - user/room query endpoints
  - health counters
- Provisioning API shell (`/v1/ping`, `/v1/logout`, `/v1/disconnect`, `/v1/reconnect`, `/v1/guilds`).
- Direct media ID compatibility (`ParseMediaID` / signed string with HMAC-SHA256 truncation).
- Database migration runner with imported SQL upgrades from local Go baseline.
- SQLite-backed database query/store layer for user, portal, guild, puppet, thread, message, reaction, role, file, and user_portal tables.
- Discord gateway state-machine primitives for hello/ready/resume, heartbeat scheduling, timeout detection, and reconnect backoff payload generation.
- Remote auth (QR login) packet parsing/state handling, nonce-proof generation, and user payload decoding primitives.
- Parity tooling to inventory Go functions and seed parity matrix docs.

## Build

```sh
cd bridge-discord-nim
nim c -d:ssl -o:mautrix-discord src/mautrix_discord.nim
```

## Test

```sh
cd bridge-discord-nim
nim c -r -d:ssl tests/all_tests.nim
```
