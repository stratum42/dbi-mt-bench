#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure isolated stock DBI + stock DBD::SQLite are built into .stock-lib/
"$SCRIPT_DIR/setup_stock_lib.sh"

STOCK_PERL="${STOCK_PERL:-/opt/homebrew/bin/perl}"
if [ ! -x "$STOCK_PERL" ]; then
  STOCK_PERL="$(command -v perl)"
fi

exec "$STOCK_PERL" "$SCRIPT_DIR/bench/run_all.pl" "$@"
