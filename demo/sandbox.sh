#!/usr/bin/env bash
# Source this file to get a local playground: a bare git remote, a "server"
# directory driven by slotdeploy, and a teammate's clone driven by slotdeploy-push.
#   source demo/sandbox.sh
# Nothing leaves your machine; everything lives under $DEMO.

DEMO=${DEMO:-/tmp/slotdeploy-demo}
SLOTDEPLOY_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
rm -rf "$DEMO"
mkdir -p "$DEMO"
export PATH="$SLOTDEPLOY_HOME/bin:$PATH"
export GIT_AUTHOR_NAME=teammate GIT_AUTHOR_EMAIL=teammate@example.com
export GIT_COMMITTER_NAME=teammate GIT_COMMITTER_EMAIL=teammate@example.com

git init --quiet --bare "$DEMO/remote.git"
git clone --quiet "$DEMO/remote.git" "$DEMO/site" 2>/dev/null
cd "$DEMO/site" || return 1
git checkout --quiet -b main
printf '<h1>Opening hours: 9am-6pm</h1>\n' >index.html
printf 'mkdir -p out\ncp index.html out/index.html\n' >build.sh
git add -A
git commit --quiet -m "first page"
git push --quiet origin main main:preview

cat >"$DEMO/slotdeploy.env" <<EOF
REPO_URL=$DEMO/remote.git
BRANCH=preview
ROOT=$DEMO/server
BUILD_CMD=sh build.sh
HEALTH_URL=file://$DEMO/server/current/out/index.html
HEALTH_RETRIES=1
EOF
export SLOTDEPLOY_CONFIG="$DEMO/slotdeploy.env"
slotdeploy watch >/dev/null

# What a visitor of the preview site sees right now.
site() { printf 'preview site> %s\n' "$(cat "$DEMO/server/current/out/index.html")"; }
# A teammate edits the page.
edit_page() { printf '<h1>%s</h1>\n' "$*" >index.html; }
# A teammate accidentally breaks the build.
break_build() { printf 'echo "SyntaxError: Unexpected token <" >&2\nexit 1\n' >build.sh; }
export PS1='$ '
