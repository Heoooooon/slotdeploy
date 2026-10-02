#!/bin/sh
# One-line installer, intentionally POSIX sh for curl | sh.
set -eu

die() { printf 'slotdeploy install: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: sh install.sh [install|update|uninstall] [options]
  --bin-dir PATH   Destination (default: $HOME/.local/bin)
  --ref REF        GitHub branch/tag/commit (default: main)
  --source PATH    Install from a local checkout instead of downloading
  --help          Show this help
Example: curl -fsSL https://raw.githubusercontent.com/Heoooooon/slotdeploy/main/install.sh | sh
Updates replace only slotdeploy, slotdeploy-push and slotdeploy-init.
Uninstall leaves configuration, deployment data and timers untouched.
EOF
}

action=install bin_dir="${HOME:?HOME is required}/.local/bin" ref=main source_dir=""
case ${1:-} in install | update | uninstall) action=$1; shift ;; esac
while [ $# -gt 0 ]; do
  case $1 in
    --help | -h) usage; exit 0 ;;
    --bin-dir | --ref | --source)
      [ $# -ge 2 ] || die "$1 needs a value"
      case $1 in --bin-dir) bin_dir=$2 ;; --ref) ref=$2 ;; --source) source_dir=$2 ;; esac
      shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
[ -n "$bin_dir" ] || die "--bin-dir must not be empty"
case $ref in '' | *[!a-zA-Z0-9._/-]*) die "--ref is invalid" ;; esac
if [ "$action" = uninstall ]; then
  for name in slotdeploy slotdeploy-push slotdeploy-init; do
    [ ! -d "$bin_dir/$name" ] || die "refusing to remove a directory"
  done
  for name in slotdeploy slotdeploy-push slotdeploy-init; do rm -f "$bin_dir/$name"; done
  printf 'Removed slotdeploy binaries from %s. Config, timers and deployments were kept.\n' "$bin_dir"
  exit 0
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/slotdeploy-install.XXXXXX")
cleanup() {
  rm -rf "$stage"
  for name in slotdeploy slotdeploy-push slotdeploy-init; do
    rm -f "$bin_dir/.$name.$$"
  done
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
if [ -z "$source_dir" ]; then
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v tar >/dev/null 2>&1 || die "tar is required"
  curl -fsSL --connect-timeout 10 --max-time 120 \
    "https://github.com/Heoooooon/slotdeploy/archive/$ref.tar.gz" \
    -o "$stage/source.tar.gz" || die "download failed; existing binaries were not changed"
  mkdir "$stage/source"
  tar -xzf "$stage/source.tar.gz" -C "$stage/source" --strip-components=1 ||
    die "archive could not be extracted"
  source_dir="$stage/source"
fi
command -v bash >/dev/null 2>&1 || die "bash is required"
for name in slotdeploy slotdeploy-push slotdeploy-init; do
  [ -f "$source_dir/bin/$name" ] || die "source is missing bin/$name"
  bash -n "$source_dir/bin/$name" || die "invalid script: $name"
  cp "$source_dir/bin/$name" "$stage/$name"
  chmod 755 "$stage/$name"
done
mkdir -p "$bin_dir"
for name in slotdeploy slotdeploy-push slotdeploy-init; do
  [ ! -d "$bin_dir/$name" ] || die "destination is a directory"
done
for name in slotdeploy slotdeploy-push slotdeploy-init; do
  # Stage on the destination filesystem for an atomic replacement per binary.
  install -m 755 "$stage/$name" "$bin_dir/.$name.$$"
done
for name in slotdeploy slotdeploy-push slotdeploy-init; do
  mv -f "$bin_dir/.$name.$$" "$bin_dir/$name"
done
printf 'Installed slotdeploy binaries in %s\n' "$bin_dir"
"$bin_dir/slotdeploy" version
case ":$PATH:" in *":$bin_dir:"*) ;; *)
  printf 'Add to PATH: export PATH="%s:%s"\n' "$bin_dir" "\$PATH" ;; esac
