# dbi-mt-bench

A small, reproducible benchmark harness for measuring a stock Perl 5 web and database stack against the experimental multi-threaded stack (`perl5-mt`, `mojolicious-mt`, `dbi-mt`, `dbd-sqlite-mt`, and `dbd-odbc-mt`).

Everything measured here stands on decades of careful engineering by the Perl 5, Mojolicious, DBI, DBD::SQLite, DBD::ODBC, and SQLite communities. The purpose of this repository is not to declare a winner, but to put runnable code and honest numbers on the table, including the cases where stock Perl and `prefork` are just as fast or faster.

## What Is Compared

- **Stock stack**: Stock Perl 5 (`STOCK_PERL`) + clean upstream Mojolicious (`prefork`) + clean upstream DBI (built into `.stock-lib/`) + clean upstream DBD::SQLite (built into `.stock-lib/`).
- **MT stack**: `perl5-mt` (`../perl5-mt-pgo` if present, else `../perl5-mt`) + `mojolicious-mt` (`mt` worker server) + `dbi-mt` (`DBI::MT::Pool`, Tier-1 `PERL_XS_THREADSAFE`, dual-gated SIMD helpers) + `dbd-sqlite-mt` (Tier-1 `PERL_XS_THREADSAFE=1`) + `dbd-odbc-mt` (Tier-1 `PERL_XS_THREADSAFE=1` with `sqliteodbc`).

## Reference Reports

See [BENCHMARK_RESULTS.md](BENCHMARK_RESULTS.md) for a sample Perl-to-Perl run on an Apple M2 Max (12 logical cores, macOS arm64). That report covers:

1. End-to-end HTTP + SQLite API endpoints (4 and 8 workers, throughput, p50/p95/p99 latency, and process-tree RSS).
2. Direct 8-worker SQLite concurrency (`fork` vs `MT::Worker`) for read-only and mixed 90/10 read/write workloads.
3. Isolated DBI SIMD microbenchmarks (`ChopBlanks`, `DBI::preparse`, `DBI::neat` / `neatsvpv`) comparing stock DBI, `dbi-mt` with `PERL_FORCE_SCALAR=1`, and `dbi-mt` with SIMD enabled.
4. Live SQLite-over-ODBC concurrency (`dbd-odbc-mt` + `sqliteodbc` + `DBI::MT::Pool`).

See [BENCHMARK_POLYGLOT.md](BENCHMARK_POLYGLOT.md) for the 4-way polyglot HTTP + SQLite comparison (**Stock Perl**, **MT Perl**, **Node.js**, and **Go**) across the same four endpoints at 4 and 8 workers.

## Prerequisites

- Sibling checkouts in the parent directory (`../`), or explicit overrides via environment variables:
  - `perl5-mt-pgo` (or `perl5-mt`)
  - `mojolicious-mt` (with `.upstream-base/lib` and built `xs/blib`)
  - `dbi-mt` (with built `blib/`)
  - `dbd-sqlite-mt` (with built `blib/`)
  - `dbd-odbc-mt` (with built `blib/`)
- Stock Perl (`STOCK_PERL`, defaulting to `/opt/homebrew/bin/perl` or `perl` in `PATH`)
- `wrk` HTTP load generator (`WRK_BIN`, defaulting to `/opt/homebrew/bin/wrk` or `wrk` in `PATH`)
- `sqliteodbc` shared library (`libsqlite3odbc.dylib` on macOS or `libsqlite3odbc.so` on Linux) for the ODBC track

## Quick Start

```sh
# Run the full suite (builds .stock-lib/ if needed, writes BENCHMARK_RESULTS.md)
./run_bench.sh

# Shorter smoke run (writes to a separate report path)
./run_bench.sh --smoke --out /tmp/dbi_mt_smoke.md

# Run the 4-way polyglot HTTP + SQLite benchmark (writes BENCHMARK_POLYGLOT.md)
./run_polyglot.sh

# Shorter polyglot smoke run
./run_polyglot.sh --smoke --out /tmp/dbi_polyglot_smoke.md

# Rebuild isolated upstream stock DBI + DBD::SQLite into .stock-lib/
./setup_stock_lib.sh --force
```

## Environment Variables

All repository and binary paths default to sibling checkouts (`../*`) resolved relative to this directory, and can be overridden:

| Variable | Default | Description |
|---|---|---|
| `STOCK_PERL` | `/opt/homebrew/bin/perl` (or `perl` in `PATH`) | Stock Perl interpreter for baseline runs and `.stock-lib/` builds. |
| `STOCK_LIB` | `./.stock-lib/lib/perl5` | Isolated stock DBI + stock DBD::SQLite library directory. |
| `DBI_STOCK_REF` | `upstream/HEAD` (fallback `origin/HEAD`, `HEAD`) | Git ref in `dbi-mt` archived for the clean upstream stock DBI build. |
| `DBD_SQLITE_STOCK_REF` | `upstream/HEAD` (fallback `origin/HEAD`, `HEAD`) | Git ref in `dbd-sqlite-mt` archived for the clean upstream stock DBD::SQLite build. |
| `PERL5_MT_DIR` | `../perl5-mt-pgo` (if present), else `../perl5-mt` | `perl5-mt` build directory containing `perl` and `lib/`. |
| `PERL5_MT` / `PERL5_MT_LIB` | `$PERL5_MT_DIR/perl` / `$PERL5_MT_DIR/lib` | Explicit overrides for the `perl5-mt` binary and library path. |
| `MOJO_MT_DIR` | `../mojolicious-mt` | Path to `mojolicious-mt`. |
| `MOJO_UPSTREAM_LIB` | `$MOJO_MT_DIR/.upstream-base/lib` | Clean upstream Mojolicious `lib/` for stock runs. |
| `DBI_MT_DIR` | `../dbi-mt` | Path to `dbi-mt` (with `blib/` built). |
| `DBD_SQLITE_MT_DIR` | `../dbd-sqlite-mt` | Path to `dbd-sqlite-mt` (with `blib/` built). |
| `DBD_ODBC_MT_DIR` | `../dbd-odbc-mt` | Path to `dbd-odbc-mt` (with `blib/` built). |
| `DBI_ODBC_SQLITE_DRIVER` | Auto-detected `libsqlite3odbc.{dylib,so}` | Override path to the SQLite ODBC driver shared library. |
| `WRK_BIN` | `/opt/homebrew/bin/wrk` (or `wrk` in `PATH`) | Path to `wrk`. |
| `NODE_BIN` | `/opt/homebrew/bin/node` (or `node` in `PATH`) | Path to Node.js for `./run_polyglot.sh`. |
| `GO_BIN` | `go` in `PATH` | Path to the Go toolchain for building `polyglot/go/server`. |

## Suite Layout

- `setup_stock_lib.sh`: Builds clean upstream DBI and DBD::SQLite via `git archive` into `.stock-lib/` against `STOCK_PERL` without touching the system Perl installation.
- `run_bench.sh`: Top-level entry point for the Perl-to-Perl suite (`BENCHMARK_RESULTS.md`).
- `run_polyglot.sh`: Top-level entry point for the 4-way polyglot HTTP + SQLite benchmark (`BENCHMARK_POLYGLOT.md`); compiles `polyglot/go/server` with CGO enabled (`-ldflags="-s -w"`) if needed.
- `polyglot/node/server.mjs`: Idiomatic Node.js server (`node:cluster`, `node:http`, built-in `node:sqlite` `DatabaseSync`, prepared statements, identical WAL pragmas).
- `polyglot/go/`: Idiomatic Go server (`net/http`, `database/sql`, `github.com/mattn/go-sqlite3`, `GOMAXPROCS(N)`, pooled prepared statements, identical WAL pragmas).
- `bench/seed_db.pl`: Creates and seeds a deterministic 10,000-row WAL-mode SQLite database with fixed-width trailing-space padded `CHAR` columns.
- `bench/app.pl`: Identical Mojolicious API application (`GET /db/single`, `GET /db/queries?n=20`, `GET /db/range`, `POST /db/update`, `GET /health`) supporting both stock (`prefork` + per-PID `$dbh`) and MT (`mt` + `DBI::MT::Pool`).
- `bench/wrk_latency.lua` / `bench/wrk_post_update.lua`: `wrk` Lua scripts reporting HDR-histogram p50/p95/p99 latencies.
- `bench/dbi_concurrency.pl`: Direct 8-worker SQLite read and mixed read/write benchmark (`fork` vs `MT::Worker`).
- `bench/dbi_simd_micro.pl`: Isolated DBI SIMD microbenchmarks (`ChopBlanks`, `DBI::preparse`, `DBI::neat` / `neatsvpv`).
- `bench/odbc_bench.pl`: Live SQLite-over-ODBC benchmark (`dbd-odbc-mt` + `sqliteodbc` + `DBI::MT::Pool`) across `MT::Worker` threads.
- `bench/run_all.pl`: Orchestrator, endpoint parity verifier, external process-tree RSS sampler, and `BENCHMARK_RESULTS.md` generator.
- `bench/run_polyglot.pl`: 4-way polyglot orchestrator, cross-stack JSON/`ChopBlanks` parity verifier, external process-tree RSS sampler, and `BENCHMARK_POLYGLOT.md` generator.

## Reproducing and Critiquing

Benchmarks are easy to get subtly wrong. If you spot a flaw in how the database is seeded, how connections are pooled, how `wrk` is driven, or how RSS is sampled, or if your numbers on Linux, x86_64, POWER, s390x, or another DBD driver tell a different story, please open an issue or share your run.
