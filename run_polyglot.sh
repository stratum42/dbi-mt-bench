#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure isolated stock DBI + stock DBD::SQLite are built into .stock-lib/
"$SCRIPT_DIR/setup_stock_lib.sh"

# Build the Go benchmark server if missing or stale
GO_DIR="$SCRIPT_DIR/polyglot/go"
GO_BIN="${GO_BIN:-$(command -v go || true)}"
if [ -z "$GO_BIN" ] || [ ! -x "$GO_BIN" ]; then
  echo "ERROR: go binary not found in PATH (set GO_BIN)" >&2
  exit 1
fi

if [ ! -x "$GO_DIR/server" ] || [ "$GO_DIR/main.go" -nt "$GO_DIR/server" ] || [ "$GO_DIR/go.mod" -nt "$GO_DIR/server" ]; then
  echo "[polyglot] Building Go server (CGO_ENABLED=1, -ldflags=\"-s -w\")..." >&2
  (cd "$GO_DIR" && CGO_ENABLED=1 "$GO_BIN" build -ldflags="-s -w" -o server .)
fi

STOCK_PERL="${STOCK_PERL:-/opt/homebrew/bin/perl}"
if [ ! -x "$STOCK_PERL" ]; then
  STOCK_PERL="$(command -v perl)"
fi

exec "$STOCK_PERL" "$SCRIPT_DIR/bench/run_polyglot.pl" "$@"
