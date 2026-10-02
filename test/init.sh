#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/slotdeploy-init-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { printf 'FAIL init: %s\n' "$*" >&2; exit 1; }
sd() { bash "$REPO/bin/slotdeploy" "$@"; }
repo='https://example.invalid/app.git'
sd -c "$T/config space/env" init --yes --repo "$repo" --root "$T/deploy space" \
  --build "printf \"\$SLOTDEPLOY_SLOT\"" --timer systemd --timer-dir "$T/systemd" \
  --every 37 >"$T/out"
sd -c "$T/config space/env" status >"$T/status"
grep -q 'branch:  preview' "$T/status" || fail "config unusable"
grep -Fq 'OnUnitActiveSec=37s' "$T/systemd/slotdeploy-watch.timer" || fail "wrong interval"
grep -Fq "\"$T/config space/env\" watch" "$T/systemd/slotdeploy-watch.service" || fail "config path unquoted"
cp "$T/config space/env" "$T/saved"
if sd -c "$T/config space/env" init --yes --repo "$repo" --root "$T/other" --timer none >"$T/err" 2>&1; then
  fail "overwrote config"
fi
cmp "$T/saved" "$T/config space/env" || fail "config changed"
sd -c "$T/mac & config" init --yes --repo "$repo" --root "$T/site" \
  --timer launchd --timer-dir "$T/launchd" --every 41 >"$T/out"
PYTHON=$(command -v python || command -v python3)
MSYS2_ENV_CONV_EXCL=EXPECTED_CONFIG EXPECTED_CONFIG="$T/mac & config" \
  "$PYTHON" - "$T/launchd/slotdeploy-watch.plist" <<'PY'
import os, plistlib, sys
with open(sys.argv[1], "rb") as f:
    p = plistlib.load(f)
expected = ["-c", os.environ["EXPECTED_CONFIG"], "watch"]
assert p["ProgramArguments"][1:] == expected, (p["ProgramArguments"], expected)
assert p["StartInterval"] == 41
PY
printf '%s\n' "$repo" "$T/interactive" preview '' '' '' none |
  sd -c "$T/interactive.env" init >"$T/out" 2>"$T/prompts"
sd -c "$T/interactive.env" status >/dev/null
for args in '--every 0' '--every 000' '--timer unknown' '--name ../escape' '--root relative'; do
  # Deliberate splitting of fixed, non-user test arguments.
  # shellcheck disable=SC2086
  if sd -c "$T/invalid.env" init --yes --repo "$repo" --root "$T/site" $args >"$T/err" 2>&1; then
    fail "invalid options accepted: $args"
  fi
  [ ! -e "$T/invalid.env" ] || fail "invalid options wrote config"
done
if sd -c "$T/injected.env" init --yes --repo "$repo" --root "$T/site" \
  --build $'true\nROOT=/oops' --timer none >/dev/null 2>&1; then
  fail "newline injection accepted"
fi
printf 'ok   init unattended systemd/launchd, interactive, escaping, overwrite and malformed input\n'
