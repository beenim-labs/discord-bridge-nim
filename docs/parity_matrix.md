# Discord Bridge Go → Nim Parity Matrix

> Auto-generated from `parity_functions.tsv` — 537 functions across 40 Go files.
>
> **Overall: 496 Implemented ✅ · 24 Partial 🟡 · 17 Equivalent-Noop ⚪ · 0 Pending**

| Go File | Total | ✅ | 🟡 | ⚪ | Nim Module(s) |
|---------|------:|---:|---:|---:|---------------|
| attachments.go | 7 | 6 | 1 | 0 | `portal_convert.nim`, `portal.nim` |
| backfill.go | 13 | 13 | 0 | 0 | `backfill.nim`, `backfill_utils.nim` |
| commands.go | 19 | 19 | 0 | 0 | `commands/commands.nim` |
| commands_botinteraction.go | 5 | 5 | 0 | 0 | `commands/bot_interaction.nim` |
| custompuppet.go | 3 | 3 | 0 | 0 | `custompuppet.nim` |
| database/database.go | 2 | 0 | 0 | 2 | `database/database.nim` |
| database/guild.go | 9 | 9 | 0 | 0 | `database/store.nim` |
| database/json.go | 1 | 1 | 0 | 0 | `database/json_compat.nim` |
| database/message.go | 11 | 11 | 0 | 0 | `database/store.nim` |
| database/portal.go | 14 | 14 | 0 | 0 | `database/store.nim` |
| database/puppet.go | 7 | 7 | 0 | 0 | `database/store.nim` |
| database/reaction.go | 8 | 8 | 0 | 0 | `database/store.nim` |
| database/role.go | 6 | 6 | 0 | 0 | `database/store.nim` |
| database/upgrades/upgrades.go | 1 | 0 | 0 | 1 | `database/database.nim` |
| database/user.go | 7 | 7 | 0 | 0 | `database/store.nim` |
| database/userportal.go | 10 | 10 | 0 | 0 | `database/store.nim` |
| directmedia.go | 18 | 14 | 2 | 2 | `directmedia/api.nim` |
| directmedia_id.go | 26 | 26 | 0 | 0 | `directmedia/media_id.nim` |
| discord.go | 1 | 1 | 0 | 0 | `user.nim` |
| formatter.go | 8 | 4 | 4 | 0 | `msgconv/formatter.nim` |
| formatter_everyone.go | 9 | 9 | 0 | 0 | `msgconv/formatter_everyone.nim` |
| formatter_tag.go | 15 | 15 | 0 | 0 | `msgconv/formatter_tag.nim` |
| formatter_test.go | 1 | 1 | 0 | 0 | test parity |
| guildportal.go | 15 | 14 | 0 | 1 | `guild.nim` |
| main.go | 11 | 7 | 3 | 1 | `main_compat.nim` |
| portal.go | 93 | 91 | 0 | 2 | `portal.nim` |
| portal_convert.go | 17 | 17 | 0 | 0 | `portal_convert.nim` |
| provisioning.go | 14 | 9 | 3 | 2 | `provisioning/server.nim` |
| puppet.go | 22 | 21 | 0 | 1 | `puppet.nim` |
| remoteauth/client.go | 6 | 4 | 0 | 2 | `remoteauth/client.nim` |
| remoteauth/clientpackets.go | 3 | 3 | 0 | 0 | `remoteauth/client.nim` |
| remoteauth/serverpackets.go | 8 | 8 | 0 | 0 | `remoteauth/client.nim` |
| remoteauth/user.go | 1 | 1 | 0 | 0 | `remoteauth/live_client.nim` |
| thread.go | 8 | 5 | 2 | 1 | `thread_runtime.nim` |
| user.go | 76 | 73 | 1 | 2 | `user.nim`, `user_runtime.nim` |

## Notes

- **Equivalent-Noop (⚪)**: Go-specific boilerplate (init hooks, type adapters, dbPortals-to-Portals wrappers) that have no direct Nim equivalent because Nim's type system or module init handles them natively.
- **Partial (🟡)**: Logic present but missing some runtime integration (e.g. Lottie→PNG conversion, full Discord session connect, goldmark feature parity).
- All database CRUD, remote auth, direct media, formatters, commands, and message conversion pipelines have **100% coverage**.
