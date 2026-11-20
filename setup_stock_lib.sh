#!/bin/sh
# Build clean upstream stock DBI and DBD::SQLite into .stock-lib/
# against STOCK_PERL without modifying the system Perl installation.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

STOCK_PERL="${STOCK_PERL:-/opt/homebrew/bin/perl}"
if [ ! -x "$STOCK_PERL" ]; then
  STOCK_PERL="$(command -v perl)"
fi

DBI_MT_DIR="${DBI_MT_DIR:-$PARENT_DIR/dbi-mt}"
DBD_SQLITE_MT_DIR="${DBD_SQLITE_MT_DIR:-$PARENT_DIR/dbd-sqlite-mt}"
STOCK_LIB="${STOCK_LIB:-$SCRIPT_DIR/.stock-lib}"

if [ -z "${DBI_STOCK_REF:-}" ]; then
  if git -C "$DBI_MT_DIR" rev-parse --verify -q upstream/HEAD >/dev/null 2>&1; then
    DBI_STOCK_REF="upstream/HEAD"
  elif git -C "$DBI_MT_DIR" rev-parse --verify -q upstream/master >/dev/null 2>&1; then
    DBI_STOCK_REF="upstream/master"
  elif git -C "$DBI_MT_DIR" rev-parse --verify -q origin/HEAD >/dev/null 2>&1; then
    DBI_STOCK_REF="origin/HEAD"
  else
    DBI_STOCK_REF="HEAD"
  fi
fi

if [ -z "${DBD_SQLITE_STOCK_REF:-}" ]; then
  if git -C "$DBD_SQLITE_MT_DIR" rev-parse --verify -q upstream/HEAD >/dev/null 2>&1; then
    DBD_SQLITE_STOCK_REF="upstream/HEAD"
  elif git -C "$DBD_SQLITE_MT_DIR" rev-parse --verify -q upstream/master >/dev/null 2>&1; then
    DBD_SQLITE_STOCK_REF="upstream/master"
  elif git -C "$DBD_SQLITE_MT_DIR" rev-parse --verify -q origin/HEAD >/dev/null 2>&1; then
    DBD_SQLITE_STOCK_REF="origin/HEAD"
  else
    DBD_SQLITE_STOCK_REF="HEAD"
  fi
fi

if [ "${1:-}" != "--force" ] && [ -f "$STOCK_LIB/.built" ]; then
  echo "[setup_stock_lib] .stock-lib already built (pass --force to rebuild)"
  exit 0
fi

echo "[setup_stock_lib] Building clean upstream stock DBI + DBD::SQLite"
echo "  STOCK_PERL:        $STOCK_PERL"
echo "  DBI ($DBI_STOCK_REF):        $DBI_MT_DIR ($(git -C "$DBI_MT_DIR" rev-parse --short "$DBI_STOCK_REF"))"
echo "  DBD::SQLite ($DBD_SQLITE_STOCK_REF): $DBD_SQLITE_MT_DIR ($(git -C "$DBD_SQLITE_MT_DIR" rev-parse --short "$DBD_SQLITE_STOCK_REF"))"
echo "  INSTALL_BASE:      $STOCK_LIB"

rm -rf "$STOCK_LIB"
mkdir -p "$STOCK_LIB"

BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dbi-stock-build.XXXXXX")"
trap 'rm -rf "$BUILD_TMP"' EXIT

NCPU="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"

# 1. Clean upstream DBI from git archive
mkdir -p "$BUILD_TMP/dbi"
git -C "$DBI_MT_DIR" archive "$DBI_STOCK_REF" | tar -x -C "$BUILD_TMP/dbi"
(
  cd "$BUILD_TMP/dbi"
  "$STOCK_PERL" Makefile.PL INSTALL_BASE="$STOCK_LIB" >/dev/null
  make -j"$NCPU" >/dev/null
  make install >/dev/null
)

# 2. Clean upstream DBD::SQLite from git archive
mkdir -p "$BUILD_TMP/dbd-sqlite"
git -C "$DBD_SQLITE_MT_DIR" archive "$DBD_SQLITE_STOCK_REF" | tar -x -C "$BUILD_TMP/dbd-sqlite"
(
  cd "$BUILD_TMP/dbd-sqlite"
  PERL5LIB="$STOCK_LIB/lib/perl5" "$STOCK_PERL" Makefile.PL INSTALL_BASE="$STOCK_LIB" >/dev/null
  PERL5LIB="$STOCK_LIB/lib/perl5" make -j"$NCPU" >/dev/null
  PERL5LIB="$STOCK_LIB/lib/perl5" make install >/dev/null
)

# 3. Verify clean stock build
PERL5LIB="$STOCK_LIB/lib/perl5" "$STOCK_PERL" -MDBI -MDBD::SQLite -e '
  die "DBI not from .stock-lib: $INC{\"DBI.pm\"}" unless $INC{"DBI.pm"} =~ m{\.stock-lib};
  die "DBD::SQLite not from .stock-lib: $INC{\"DBD/SQLite.pm\"}" unless $INC{"DBD/SQLite.pm"} =~ m{\.stock-lib};
  die "Unexpected DBI::MT::Pool in stock lib" if eval { require DBI::MT::Pool; 1 };
  print "Verified stock DBI $DBI::VERSION ($INC{\"DBI.pm\"})\n";
  print "Verified stock DBD::SQLite $DBD::SQLite::VERSION (SQLite $DBD::SQLite::sqlite_version)\n";
'

date -u +"%Y-%m-%dT%H:%M:%SZ" > "$STOCK_LIB/.built"
echo "[setup_stock_lib] Done."
