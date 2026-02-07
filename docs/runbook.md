# bridge-discord-nim Runbook

## Build

```sh
cd bridge-discord-nim
nim c -d:ssl -o:mautrix-discord src/mautrix_discord.nim
```

## Run Tests

```sh
cd bridge-discord-nim
nim c -r -d:ssl tests/all_tests.nim
```

## Generate Registration

```sh
./mautrix-discord -g -c tests/fixtures/mautrix-discord.sample.yaml -r mautrix-discord-registration.yaml
```

## Run Bridge

```sh
./mautrix-discord -c tests/fixtures/mautrix-discord.sample.yaml -r mautrix-discord-registration.yaml
```

## Health Check

```sh
curl "http://127.0.0.1:29334/health"
```

## Regenerate Parity Inventory

```sh
./tools/update_parity_matrix.sh
```
