#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PYTHON=$(command -v python || command -v python3)
"$PYTHON" "$HERE/notifications.py"
