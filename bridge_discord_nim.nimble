version       = "0.1.0"
author        = "Beenim"
description   = "Nim v2 rewrite of mautrix-discord bridge"
license       = "AGPL-3.0"
srcDir        = "src"
bin           = @["mautrix_discord"]

requires "nim >= 2.0.0"

task dev, "Build and run debug binary":
  exec "nim c -r -d:ssl -o:mautrix-discord src/mautrix_discord.nim"

task build, "Build release binary with drop-in name":
  exec "nim c -d:release -d:ssl -o:mautrix-discord src/mautrix_discord.nim"

task lint, "Run Nim semantic checks":
  exec "nim check src/mautrix_discord.nim"
  exec "nim check tests/all_tests.nim"
  exec "./tools/check_parity_functions.sh"

task test, "Run all tests":
  exec "./tools/check_parity_functions.sh"
  exec "nim c -r -d:ssl --out:/tmp/bridge_discord_nim_tests tests/all_tests.nim"
