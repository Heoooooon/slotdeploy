#!/usr/bin/env bash
# End-to-end tests: a real bare git remote, a fake app whose build succeeds or
# fails on purpose, the server (slotdeploy) and the client (slotdeploy-push).
# Usage: bash test/run.sh [name-filter]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
FILTER=${1:-}

# ---------------------------------------------------------------- harness

fail() { printf '    assertion failed: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "${3:-values differ}: expected [$2], got [$1]"; }
assert_ne() { [ "$1" != "$2" ] || fail "${3:-values equal}: both [$1]"; }
assert_grep() { grep -q -- "$2" "$1" || fail "'$2' not found in $1"; }

setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/slotdeploy-test.XXXXXX")
  export HOME="$T/home" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  git config --global user.name tester
  git config --global user.email tester@example.com
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false
  export PATH="$BIN:$PATH"

  REMOTE="$T/remote.git"
  git init --quiet --bare "$REMOTE"
  git clone --quiet "$REMOTE" "$T/dev" 2>/dev/null
  write_app "$T/dev" ok "v1"
  git -C "$T/dev" add -A
  git -C "$T/dev" commit --quiet -m "v1"
  git -C "$T/dev" push --quiet origin HEAD:main HEAD:preview
  MAIN0=$(main_sha)

  SRV="$T/srv"
  CONF="$T/slotdeploy.env"
  cat >"$CONF" <<EOF
# test server
REPO_URL=$REMOTE
BRANCH=preview
ROOT=$SRV
BUILD_CMD=sh build.sh
RESTART_CMD="echo restart >> \$SLOTDEPLOY_ROOT/restarts"
HEALTH_URL=file://$SRV/current/out/index.html
HEALTH_RETRIES=2
HEALTH_INTERVAL=0
EOF
  git clone --quiet "$REMOTE" "$T/client" 2>/dev/null
}

teardown() { rm -rf "$T"; }

# write_app DIR ok|fail|nohealth TEXT
write_app() {
  printf '%s\n' "$3" >"$1/app.txt"
  case $2 in
    ok) printf 'mkdir -p out\ncp app.txt out/index.html\n' >"$1/build.sh" ;;
    fail) printf 'echo "Type error: something broke" >&2\nexit 1\n' >"$1/build.sh" ;;
    nohealth) printf 'mkdir -p out\necho built\n' >"$1/build.sh" ;;
  esac
}

# publish ok|fail|nohealth TEXT -> pushes a new commit to preview from the dev clone
publish() {
  write_app "$T/dev" "$1" "$2"
  git -C "$T/dev" add -A
  git -C "$T/dev" commit --quiet -m "$2"
  git -C "$T/dev" push --quiet --force origin HEAD:preview
}

sd() { slotdeploy -c "$CONF" "$@"; }
served() { cat "$SRV/current/out/index.html" 2>/dev/null || echo "<nothing>"; }
live() { readlink "$SRV/current" || true; }
restarts() { wc -l <"$SRV/restarts" 2>/dev/null | tr -d ' ' || echo 0; }
main_sha() { git --git-dir="$REMOTE" rev-parse refs/heads/main; }
preview_sha() { git --git-dir="$REMOTE" rev-parse refs/heads/preview; }
in_client() { (cd "$T/client" && "$@"); }

# ---------------------------------------------------------------- server

test_first_deploy_switches_to_healthy_slot() {
  sd watch >"$T/out"
  assert_grep "$T/out" "OK   preview"
  assert_eq "$(live)" "slots/a" "first deploy slot"
  assert_eq "$(served)" "v1"
  assert_eq "$(restarts)" "1"
  assert_grep "$SRV/slotdeploy.log" "OK   preview $(preview_sha | cut -c1-7)"
}

test_next_commit_uses_other_slot() {
  sd watch >/dev/null
  publish ok "v2"
  sd watch >/dev/null
  assert_eq "$(live)" "slots/b"
  assert_eq "$(served)" "v2"
}

test_build_failure_keeps_previous() {
  sd watch >/dev/null
  publish fail "broken"
  if sd watch >"$T/out" 2>&1; then fail "watch should exit non-zero on a failed build"; fi
  assert_grep "$T/out" "FAIL preview .* build failed, kept"
  assert_grep "$T/out" "Type error: something broke"
  assert_eq "$(live)" "slots/a" "live slot after failed build"
  assert_eq "$(served)" "v1" "served content after failed build"
  assert_eq "$(restarts)" "1" "no restart for a failed build"
  assert_grep "$SRV/logs/last-failed.log" "Type error"
}

test_failed_commit_is_not_retried_but_next_commit_deploys() {
  sd watch >/dev/null
  publish fail "broken"
  sd watch >/dev/null 2>&1 || true
  lines=$(wc -l <"$SRV/slotdeploy.log")
  sd watch >/dev/null
  assert_eq "$(wc -l <"$SRV/slotdeploy.log")" "$lines" "same failed commit retried"
  publish ok "v3 fixed"
  sd watch >/dev/null
  assert_eq "$(served)" "v3 fixed"
  sd status >"$T/status"
  if grep -q '^failed:' "$T/status"; then fail "status still reports a failure"; fi
}

test_health_failure_switches_back() {
  sd watch >/dev/null
  publish nohealth "no page"
  if sd watch >"$T/out" 2>&1; then fail "watch should fail when health check fails"; fi
  assert_grep "$T/out" "health failed, kept"
  assert_eq "$(live)" "slots/a" "link restored after failed health check"
  assert_eq "$(served)" "v1"
  assert_eq "$(restarts)" "3" "restart new, then restart previous again"
}

test_check_cmd_failure_never_switches() {
  echo 'CHECK_CMD=test -f out/index.html' >>"$CONF"
  sd watch >/dev/null
  publish nohealth "no page"
  sd watch >"$T/out" 2>&1 || true
  assert_grep "$T/out" "check failed"
  assert_eq "$(restarts)" "1" "service touched although pre-switch check failed"
  assert_eq "$(served)" "v1"
}

test_first_deploy_failure_leaves_nothing_live() {
  publish fail "broken"
  sd watch >"$T/out" 2>&1 || true
  assert_grep "$T/out" "nothing was live"
  [ ! -e "$SRV/current" ] || fail "current link should not exist"
}

test_watch_is_quiet_when_up_to_date() {
  sd watch >/dev/null
  sd watch >"$T/out"
  assert_eq "$(cat "$T/out")" "" "output when nothing changed"
  assert_eq "$(restarts)" "1"
}

test_live_lock_skips_and_stale_lock_recovers() {
  mkdir -p "$SRV/.lock"
  holder=$$
  echo "$holder" >"$SRV/.lock/pid"
  sd watch >/dev/null 2>"$T/err"
  assert_grep "$T/err" "another deploy is running"
  [ ! -e "$SRV/current" ] || fail "deployed while locked"
  # A reaped child has a stale pid without timing-dependent sleeps.
  bash -c ':' &
  holder=$!
  wait "$holder"
  echo "$holder" >"$SRV/.lock/pid"
  sd watch >/dev/null
  assert_eq "$(served)" "v1" "deploy after stale lock"
  [ ! -e "$SRV/.lock" ] || fail "lock left behind"
}

test_refuses_real_directory_as_current() {
  mkdir -p "$SRV/current"
  if sd watch >/dev/null 2>"$T/err"; then fail "should refuse a real directory"; fi
  assert_grep "$T/err" "not a symlink"
}

test_config_rejects_unknown_key() {
  echo 'BULID_CMD=oops' >>"$CONF"
  if sd watch >/dev/null 2>"$T/err"; then fail "unknown key accepted"; fi
  assert_grep "$T/err" "unknown key 'BULID_CMD'"
}

test_config_values_are_not_executed_on_load() {
  # shellcheck disable=SC2016
  printf 'INSTALL_CMD=$(touch %s/pwned)\n' "$T" >>"$CONF"
  sd status >/dev/null
  [ ! -e "$T/pwned" ] || fail "config value was executed while loading"
}

# ---------------------------------------------------------------- client

test_start_branches_from_preview_and_refuses_dirty_tree() {
  publish ok "v2 on preview"
  in_client slotdeploy-push start >"$T/out"
  assert_eq "$(git -C "$T/client" rev-parse HEAD)" "$(preview_sha)" "start base"
  case $(git -C "$T/client" symbolic-ref --short HEAD) in work/*) ;; *) fail "not on a work/ branch" ;; esac
  echo edit >>"$T/client/app.txt"
  if in_client slotdeploy-push start >/dev/null 2>"$T/err"; then fail "start allowed with unsaved changes"; fi
  assert_grep "$T/err" "unsaved changes"
  assert_grep "$T/client/app.txt" "edit"
}

test_push_updates_preview_backs_up_branch_and_keeps_main() {
  in_client slotdeploy-push start >/dev/null
  write_app "$T/client" ok "client v2"
  in_client slotdeploy-push push "client v2" >"$T/out"
  branch=$(git -C "$T/client" symbolic-ref --short HEAD)
  head=$(git -C "$T/client" rev-parse HEAD)
  assert_eq "$(preview_sha)" "$head" "preview"
  assert_eq "$(git --git-dir="$REMOTE" rev-parse "refs/heads/$branch")" "$head" "backup branch"
  assert_eq "$(main_sha)" "$MAIN0" "remote main"
  assert_eq "$(git -C "$T/client" status --porcelain)" "" "everything committed"
}

test_push_from_main_moves_work_to_new_branch() {
  local_main=$(git -C "$T/client" rev-parse main)
  write_app "$T/client" ok "edited on main"
  in_client slotdeploy-push push "edited on main" >"$T/out"
  assert_grep "$T/out" "new branch: work/"
  assert_eq "$(git -C "$T/client" rev-parse main)" "$local_main" "local main"
  assert_eq "$(main_sha)" "$MAIN0" "remote main"
  assert_eq "$(git --git-dir="$REMOTE" show preview:app.txt)" "edited on main"
}

test_rollback_prev_and_commit_leave_files_alone() {
  first=$(preview_sha)
  in_client slotdeploy-push start >/dev/null
  write_app "$T/client" ok "a"
  in_client slotdeploy-push push "a" >/dev/null
  a=$(preview_sha)
  write_app "$T/client" ok "b"
  in_client slotdeploy-push push "b" >/dev/null
  echo "unsaved" >"$T/client/notes.txt"
  in_client slotdeploy-push rollback 이전 >"$T/out"
  assert_eq "$(preview_sha)" "$a" "rollback prev"
  assert_grep "$T/client/notes.txt" "unsaved"
  assert_eq "$(cat "$T/client/app.txt")" "b" "working tree changed by rollback"
  assert_eq "$(git -C "$T/client" stash list)" "" "stash used"
  in_client slotdeploy-push rollback "${first:0:7}" >/dev/null
  assert_eq "$(preview_sha)" "$first" "rollback to commit"
  assert_eq "$(main_sha)" "$MAIN0" "remote main"
}

test_rollback_yesterday_uses_history() {
  old=$(preview_sha)
  in_client slotdeploy-push start >/dev/null
  write_app "$T/client" ok "today"
  in_client slotdeploy-push push "today" >/dev/null
  hist="$T/client/.git/slotdeploy-history"
  # Pretend the first preview entry was recorded two days ago.
  awk -v o="$old" -v t="$(($(date +%s) - 172800))" '$2 == o { $1 = t } { print }' "$hist" >"$hist.new"
  mv "$hist.new" "$hist"
  in_client slotdeploy-push rollback yesterday >/dev/null
  assert_eq "$(preview_sha)" "$old" "rollback yesterday"
}

test_rollback_unknown_commit_changes_nothing() {
  before=$(preview_sha)
  if in_client slotdeploy-push rollback deadbeef >/dev/null 2>"$T/err"; then fail "unknown commit accepted"; fi
  assert_grep "$T/err" "unknown commit"
  assert_eq "$(preview_sha)" "$before"
}

test_refuses_protected_preview_branch() {
  if (cd "$T/client" && SLOTDEPLOY_BRANCH=main slotdeploy-push push "x") >/dev/null 2>"$T/err"; then
    fail "pushed to a protected branch"
  fi
  assert_grep "$T/err" "protected"
  assert_eq "$(main_sha)" "$MAIN0"
}

# ---------------------------------------------------------------- together

test_end_to_end_broken_push_then_rollback() {
  sd watch >/dev/null
  in_client slotdeploy-push start >/dev/null
  write_app "$T/client" ok "new banner"
  in_client slotdeploy-push push "new banner" >/dev/null
  sd watch >/dev/null
  assert_eq "$(served)" "new banner"
  good=$(preview_sha)

  write_app "$T/client" fail "typo"
  in_client slotdeploy-push push "typo" >/dev/null
  sd watch >/dev/null 2>&1 || true
  assert_eq "$(served)" "new banner" "site after broken push"

  in_client slotdeploy-push rollback prev >/dev/null
  assert_eq "$(preview_sha)" "$good"
  sd watch >"$T/out"
  assert_eq "$(cat "$T/out")" "" "rollback to live commit needs no rebuild"
  assert_eq "$(served)" "new banner"
  assert_eq "$(main_sha)" "$MAIN0" "remote main"
}

# ---------------------------------------------------------------- runner

pass=0
failed=0
failures=""
for t in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
  case $t in *"$FILTER"*) ;; *) continue ;; esac
  set +e
  (
    set -e
    setup
    trap teardown EXIT
    "$t"
  ) >"${TMPDIR:-/tmp}/slotdeploy-test-out.$$" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$t"
  else
    failed=$((failed + 1))
    failures="$failures $t"
    printf 'FAIL %s\n' "$t"
    sed 's/^/    /' "${TMPDIR:-/tmp}/slotdeploy-test-out.$$"
  fi
done
rm -f "${TMPDIR:-/tmp}/slotdeploy-test-out.$$"
printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ] || { printf 'failed:%s\n' "$failures"; exit 1; }

# Feature suites also run when no legacy name filter was supplied.
if [ -z "$FILTER" ]; then
  bash "$HERE/install.sh"
  bash "$HERE/init.sh"
  bash "$HERE/notifications.sh"
fi
