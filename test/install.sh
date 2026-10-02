#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/slotdeploy-install-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { printf 'FAIL installer: %s\n' "$*" >&2; exit 1; }
mkdir -p "$T/source/bin" "$T/bin space"
cp "$REPO"/bin/* "$T/source/bin/"
sh "$REPO/install.sh" --source "$T/source" --bin-dir "$T/bin space" >"$T/out"
[ "$("$T/bin space/slotdeploy" version)" = "slotdeploy $(<"$REPO/VERSION")" ] || fail "installed version"
"$T/bin space/slotdeploy" init --help >/dev/null
printf '#!/usr/bin/env bash\nprintf "updated\\n"\n' >"$T/source/bin/slotdeploy"
sh "$REPO/install.sh" update --source "$T/source" --bin-dir "$T/bin space" >/dev/null
[ "$("$T/bin space/slotdeploy")" = updated ] || fail "update did not replace executable"
rm "$T/source/bin/slotdeploy-init"
if sh "$REPO/install.sh" update --source "$T/source" --bin-dir "$T/bin space" >"$T/out" 2>&1; then
  fail "incomplete source accepted"
fi
[ "$("$T/bin space/slotdeploy")" = updated ] || fail "failed update modified install"
printf 'keep\n' >"$T/bin space/unrelated"
sh "$REPO/install.sh" uninstall --bin-dir "$T/bin space" >/dev/null
[ -f "$T/bin space/unrelated" ] || fail "unrelated file deleted"
for name in slotdeploy slotdeploy-push slotdeploy-init; do
  [ ! -e "$T/bin space/$name" ] || fail "$name remains"
done
[ "$(find "$T/bin space" -type f | wc -l | tr -d ' ')" = 1 ] || fail "staging file remains"
printf 'ok   installer install/update/uninstall, spaces, failed update preservation\n'
