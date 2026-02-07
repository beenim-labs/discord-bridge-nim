#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INV="$ROOT_DIR/docs/go_function_inventory.tsv"
OUT="$ROOT_DIR/docs/parity_matrix.md"
STATUS_FILE="$ROOT_DIR/docs/parity_status.tsv"
FUNCTION_STATUS_FILE="$ROOT_DIR/docs/parity_functions.tsv"

"$ROOT_DIR/tools/generate_function_inventory.sh" >/dev/null
"$ROOT_DIR/tools/update_parity_functions.sh" >/dev/null

total=$(( $(wc -l < "$INV") - 1 ))
by_file_tmp="$(mktemp)"
function_status_tmp="$(mktemp)"
trap 'rm -f "$by_file_tmp" "$function_status_tmp"' EXIT

awk -F'\t' 'NR>1 { c[$1]++ } END { for (f in c) print c[f] "\t" f }' "$INV" | sort -nr > "$by_file_tmp"
awk -F'\t' '
  NR > 1 {
    file = $1
    st = tolower($4)
    total[file]++
    if (st == "pending") {
      pending[file]++
    }
    if (index(st, "implemented") == 1 || index(st, "equivalent-noop") == 1) {
      done[file]++
    }
  }
  END {
    for (f in total) {
      status = "Partial"
      if (done[f] == total[f]) {
        status = "Implemented"
      } else if (pending[f] == total[f]) {
        status = "Pending"
      }
      print f "\t" status
    }
  }
' "$FUNCTION_STATUS_FILE" > "$function_status_tmp"

{
  echo "# Parity Matrix (Generated)"
  echo
  echo '- Baseline: local `discord-bridge` Go snapshot'
  echo "- Total Go functions detected: **$total**"
  echo '- Inventory source: `docs/go_function_inventory.tsv`'
  echo
  echo "## File Coverage"
  echo
  echo "| Go file | Functions | Nim status |"
  echo "| --- | ---: | --- |"
  while IFS=$'\t' read -r count file; do
    status="$(awk -F'\t' -v f="$file" '$1==f {print $2; exit}' "$function_status_tmp")"
    if [[ -z "$status" ]]; then
      status="Pending"
    fi
    if [[ -f "$STATUS_FILE" ]]; then
      found_status="$(awk -F'\t' -v f="$file" 'NF>=2 && $1==f {print $2; exit}' "$STATUS_FILE")"
      if [[ -n "$found_status" ]]; then
        status="$found_status"
      fi
    fi
    printf '| `%s` | %s | %s |\n' "$file" "$count" "$status"
  done < "$by_file_tmp"
  echo
  echo "## Notes"
  echo
  echo "- This matrix is seeded automatically from Go function inventory."
  echo '- Function-level statuses are generated in `docs/parity_functions.tsv`.'
  echo '- Statuses are optionally overridden with `docs/parity_status.tsv`.'
} > "$OUT"

echo "updated $OUT"
