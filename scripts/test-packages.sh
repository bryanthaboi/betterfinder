#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${TEST_JOBS:-4}"
SCRATCH="${SPM_SCRATCH_ROOT:-}"

if [ "${1:-}" = "--one" ]; then
  p="$2"
  logs="$3"
  args=(--package-path "$ROOT/Packages/$p")
  [ -n "$SCRATCH" ] && args+=(--scratch-path "$SCRATCH/$p")
  start=$SECONDS
  if swift test "${args[@]}" > "$logs/$p.log" 2>&1; then
    echo "ok   $p $((SECONDS - start))s"
  else
    touch "$logs/$p.failed"
    echo "FAIL $p $((SECONDS - start))s"
  fi
  exit 0
fi

LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT

if [ "$#" -gt 0 ]; then
  packages=("$@")
else
  packages=(Browser ModValidation ModHost ModScriptTS)
  for d in "$ROOT"/Packages/*/; do
    p="$(basename "$d")"
    case " ${packages[*]} " in *" $p "*) ;; *) packages+=("$p") ;; esac
  done
fi

start=$SECONDS
printf '%s\n' "${packages[@]}" | xargs -P "$JOBS" -I{} "$0" --one {} "$LOGS"

failed=()
for p in "${packages[@]}"; do
  [ -f "$LOGS/$p.failed" ] && { failed+=("$p"); continue; }
  echo "::group::$p"
  cat "$LOGS/$p.log"
  echo "::endgroup::"
done

echo "tests finished in $((SECONDS - start))s"
if [ "${#failed[@]}" -gt 0 ]; then
  for p in "${failed[@]}"; do
    echo "::error::$p tests failed"
    cat "$LOGS/$p.log"
  done
  exit 1
fi
