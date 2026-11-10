#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${TEST_JOBS:-4}"
SCRATCH="${SPM_SCRATCH_ROOT:-}"

if [ "${1:-}" = "--one" ]; then
  phase="$2"
  p="$3"
  logs="$4"
  args=(--package-path "$ROOT/Packages/$p")
  [ -n "$SCRATCH" ] && args+=(--scratch-path "$SCRATCH/$p")
  [ -f "$logs/$p.failed" ] && exit 0
  start=$SECONDS
  if [ "$phase" = "build" ]; then
    if swift build --build-tests "${args[@]}" > "$logs/$p.log" 2>&1; then
      echo "built $p $((SECONDS - start))s"
    else
      touch "$logs/$p.failed"
      echo "FAIL $p build $((SECONDS - start))s"
    fi
    exit 0
  fi
  if swift test --skip-build "${args[@]}" >> "$logs/$p.log" 2>&1; then
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
printf '%s\n' "${packages[@]}" | xargs -P "$JOBS" -I{} "$0" --one build {} "$LOGS"
echo "builds finished in $((SECONDS - start))s"
printf '%s\n' "${packages[@]}" | xargs -P "$JOBS" -I{} "$0" --one test {} "$LOGS"

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
