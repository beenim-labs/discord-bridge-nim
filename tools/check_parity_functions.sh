#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INV="$ROOT_DIR/docs/go_function_inventory.tsv"
PARITY="$ROOT_DIR/docs/parity_functions.tsv"

if [[ ! -f "$INV" ]]; then
  echo "missing inventory file: $INV" >&2
  exit 1
fi

if [[ ! -f "$PARITY" ]]; then
  echo "missing parity function file: $PARITY" >&2
  exit 1
fi

tmp_inv="$(mktemp)"
tmp_parity="$(mktemp)"
tmp_missing="$(mktemp)"
tmp_extra="$(mktemp)"
trap 'rm -f "$tmp_inv" "$tmp_parity" "$tmp_missing" "$tmp_extra"' EXIT

awk -F'\t' 'NR>1 { print $1 "\t" $2 "\t" $3 }' "$INV" | sort -u > "$tmp_inv"
awk -F'\t' 'NR>1 { print $1 "\t" $2 "\t" $3 }' "$PARITY" | sort -u > "$tmp_parity"

comm -23 "$tmp_inv" "$tmp_parity" > "$tmp_missing"
comm -13 "$tmp_inv" "$tmp_parity" > "$tmp_extra"

missing_count="$(wc -l < "$tmp_missing" | tr -d ' ')"
extra_count="$(wc -l < "$tmp_extra" | tr -d ' ')"

blank_status_count="$(awk -F'\t' 'NR>1 && $4 == "" { c++ } END { print c+0 }' "$PARITY")"

if [[ "$missing_count" -gt 0 ]]; then
  echo "parity function mapping is missing $missing_count entries" >&2
  head -n 10 "$tmp_missing" >&2
  exit 1
fi

if [[ "$extra_count" -gt 0 ]]; then
  echo "parity function mapping has $extra_count unexpected entries" >&2
  head -n 10 "$tmp_extra" >&2
  exit 1
fi

if [[ "$blank_status_count" -gt 0 ]]; then
  echo "parity function mapping has $blank_status_count rows with empty status" >&2
  exit 1
fi

echo "parity function mapping is complete and consistent"
