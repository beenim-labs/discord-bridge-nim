#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GO_DIR="$ROOT_DIR/../discord-bridge"
OUT_TSV="$ROOT_DIR/docs/go_function_inventory.tsv"

if [[ ! -d "$GO_DIR" ]]; then
  echo "discord-bridge directory not found at $GO_DIR" >&2
  exit 1
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

(
  cd "$GO_DIR"
  rg -n "^func(\\s+\\(|\\s+[A-Za-z0-9_]+)" --glob '*.go'
) > "$tmp_file"

echo -e "file\tline\tsignature" > "$OUT_TSV"
awk -F: '{ file=$1; line=$2; $1=""; $2=""; sub(/^::?/, ""); sub(/^:/, ""); sig=$0; gsub(/^ +/, "", sig); print file "\t" line "\t" sig }' "$tmp_file" >> "$OUT_TSV"

total=$(( $(wc -l < "$OUT_TSV") - 1 ))
echo "wrote $OUT_TSV ($total functions)"
