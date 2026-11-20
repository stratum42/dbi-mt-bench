# Polyglot HTTP + SQLite Benchmark Results

Side-by-side measurements comparing **Stock Perl**, the experimental **MT Perl** stack (`perl5-mt` + `mojolicious-mt` + `dbi-mt` + `dbd-sqlite-mt`), **Node.js**, and **Go** across four identical HTTP + SQLite JSON endpoints on Apple M2 Max (12 logical cores, macOS 27.2.1 (arm64)).

These numbers are offered as working measurements, not guarantees. Every stack here stands on decades of upstream engineering by the Perl 5, Mojolicious, DBI, DBD::SQLite, Node.js, V8, Go, and SQLite communities. Each runtime is given an idiomatic, well-configured implementation, and the tables below report wherever Go, Node.js, Stock Perl, or MT Perl comes out ahead. Please run `./run_polyglot.sh` on your own hardware and treat any figure here with healthy skepticism until you see it reproduce.

## Test Environment & Methodology

- **Hardware / OS**: Apple M2 Max (12 logical cores), macOS 27.2.1 (arm64)
- **Stock Perl**: `/opt/homebrew/bin/perl` (`v5.44.0`) + upstream Mojolicious `9.55` (`prefork`) + upstream DBI `1.657` (`dd2c386`) + upstream DBD::SQLite `1.78 (SQLite 3.54.1)` (`4ee4da7`), per-worker persistent `$dbh` with `prepare_cached` (`bench/app.pl`).
- **MT Perl**: `../perl5-mt-pgo/perl` (`v5.40.2`, `perl5-mt`) + `mojolicious-mt` (`mt` worker server + Tier-1 XS) + `dbi-mt` (`1.657` + `DBI::MT::Pool` + Tier-1 `PERL_XS_THREADSAFE` + SIMD) + `dbd-sqlite-mt` (`1.78 (SQLite 3.54.1)`, Tier-1 `PERL_XS_THREADSAFE=1`) (`bench/app.pl`).
- **Node.js**: `/opt/homebrew/bin/node` (`v26.13.1`) with `node:cluster` (`--workers N`), `node:http` with keep-alive, and built-in `node:sqlite` (`DatabaseSync`, SQLite `3.54.1`) with per-worker prepared statements (`polyglot/node/server.mjs`).
- **Go**: `/opt/homebrew/bin/go` (`go1.27.4`), compiled with `CGO_ENABLED=1` and `-ldflags="-s -w"`, `net/http` + `database/sql` + `github.com/mattn/go-sqlite3` (native C SQLite `3.49.1`), `runtime.GOMAXPROCS(N)`, `SetMaxOpenConns(N)` / `SetMaxIdleConns(N)`, and prepared statements (`polyglot/go/main.go`).
- **Database**: Freshly seeded 10,000-row WAL-mode SQLite database per stack and worker count (`PRAGMA journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=15000`, `temp_store=MEMORY`, `cache_size=-16000`), with fixed-width trailing-space padded `CHAR(32)`/`CHAR(24)`/`CHAR(64)` columns.
- **Parity Checks**: Before timing begins, the harness verifies HTTP 200 JSON responses, identical schema keys, ascending `id` ordering, trailing-space trimming (`ChopBlanks => 1` parity) on `GET /db/range`, and transactional `BEGIN IMMEDIATE` updates on `POST /db/update` across all four stacks.
- **HTTP Load Generator**: `wrk -t4 -c64 -d5s --latency` (1s warmup, median of 3 passes, exact p50/p95/p99 from `wrk` HDR histogram via Lua `done()`, 0 non-2xx and 0 socket errors enforced).
- **RSS Measurement**: Total process-tree RSS (`ps -o pid=,ppid=,rss= -ax`) sampled during active load (median MiB).
- **Reproduce**: `./run_polyglot.sh`

## 4-Worker Comparison

### Throughput (req/s)

| Endpoint | Stock Perl | MT Perl | Node.js | Go | MT vs Stock | MT vs Node | MT vs Go | Fastest |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| GET /db/single | 14,250 | 20,320 | 159,006 | 104,966 | **1.43x** | 0.13x | 0.19x | **Node.js** |
| GET /db/queries?n=20 | 6,788 | 9,664 | 23,040 | 12,253 | **1.42x** | 0.42x | 0.79x | **Node.js** |
| GET /db/range | 4,746 | 12,324 | 32,138 | 23,002 | **2.60x** | 0.38x | 0.54x | **Node.js** |
| POST /db/update | 8,347 | 9,284 | 30,643 | 28,707 | **1.11x** | 0.30x | 0.32x | **Node.js** |

### Latency (p50 / p95 / p99 ms) & Process-Tree RSS (total / per-worker MiB)

| Endpoint | Stack | p50 / p95 / p99 (ms) | Total RSS | Per-Worker RSS |
|---|---|---:|---:|---:|
| GET /db/single | Stock Perl | 4.52 / 9.67 / 11.82 ms | 137.7 MiB | 34.4 MiB |
| GET /db/single | MT Perl | 3.07 / 3.65 / 5.90 ms | 119.9 MiB | 30.0 MiB |
| GET /db/single | Node.js | 0.36 / 0.55 / 0.79 ms | 404.7 MiB | 101.2 MiB |
| GET /db/single | Go | 0.53 / 1.59 / 2.31 ms | 30.4 MiB | 7.6 MiB |
| GET /db/queries?n=20 | Stock Perl | 6.87 / 27.91 / 28.53 ms | 142.0 MiB | 35.5 MiB |
| GET /db/queries?n=20 | MT Perl | 6.52 / 7.26 / 12.53 ms | 120.4 MiB | 30.1 MiB |
| GET /db/queries?n=20 | Node.js | 2.76 / 4.36 / 6.14 ms | 441.2 MiB | 110.3 MiB |
| GET /db/queries?n=20 | Go | 5.11 / 7.18 / 8.23 ms | 30.5 MiB | 7.6 MiB |
| GET /db/range | Stock Perl | 16.35 / 18.91 / 28.69 ms | 145.7 MiB | 36.4 MiB |
| GET /db/range | MT Perl | 5.07 / 5.68 / 10.04 ms | 120.9 MiB | 30.2 MiB |
| GET /db/range | Node.js | 1.84 / 3.45 / 4.05 ms | 508.7 MiB | 127.2 MiB |
| GET /db/range | Go | 2.48 / 6.53 / 9.38 ms | 30.7 MiB | 7.7 MiB |
| POST /db/update | Stock Perl | 7.22 / 18.10 / 27.48 ms | 147.0 MiB | 36.7 MiB |
| POST /db/update | MT Perl | 5.94 / 21.07 / 51.23 ms | 120.9 MiB | 30.2 MiB |
| POST /db/update | Node.js | 0.77 / 111.05 / 253.16 ms | 624.5 MiB | 156.1 MiB |
| POST /db/update | Go | 1.97 / 9.06 / 179.32 ms | 30.9 MiB | 7.7 MiB |

## 8-Worker Comparison

### Throughput (req/s)

| Endpoint | Stock Perl | MT Perl | Node.js | Go | MT vs Stock | MT vs Node | MT vs Go | Fastest |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| GET /db/single | 25,211 | 33,144 | 146,756 | 116,963 | **1.31x** | 0.23x | 0.28x | **Node.js** |
| GET /db/queries?n=20 | 10,872 | 15,114 | 15,168 | 10,575 | **1.39x** | 1.00x | 1.43x | **Node.js** |
| GET /db/range | 8,728 | 20,093 | 51,019 | 17,663 | **2.30x** | 0.39x | 1.14x | **Node.js** |
| POST /db/update | 9,949 | 10,646 | 29,853 | 27,731 | **1.07x** | 0.36x | 0.38x | **Node.js** |

### Latency (p50 / p95 / p99 ms) & Process-Tree RSS (total / per-worker MiB)

| Endpoint | Stack | p50 / p95 / p99 (ms) | Total RSS | Per-Worker RSS |
|---|---|---:|---:|---:|
| GET /db/single | Stock Perl | 1.97 / 7.40 / 9.42 ms | 231.6 MiB | 29.0 MiB |
| GET /db/single | MT Perl | 1.76 / 3.41 / 4.56 ms | 136.3 MiB | 17.0 MiB |
| GET /db/single | Node.js | 0.38 / 0.54 / 0.73 ms | 743.3 MiB | 92.9 MiB |
| GET /db/single | Go | 0.42 / 1.35 / 1.92 ms | 41.5 MiB | 5.2 MiB |
| GET /db/queries?n=20 | Stock Perl | 4.52 / 19.90 / 24.12 ms | 236.5 MiB | 29.6 MiB |
| GET /db/queries?n=20 | MT Perl | 3.94 / 7.35 / 8.45 ms | 137.2 MiB | 17.2 MiB |
| GET /db/queries?n=20 | Node.js | 3.99 / 7.84 / 9.19 ms | 752.7 MiB | 94.1 MiB |
| GET /db/queries?n=20 | Go | 5.94 / 8.06 / 9.22 ms | 41.6 MiB | 5.2 MiB |
| GET /db/range | Stock Perl | 7.97 / 17.21 / 19.81 ms | 241.9 MiB | 30.2 MiB |
| GET /db/range | MT Perl | 2.89 / 5.59 / 7.22 ms | 138.4 MiB | 17.3 MiB |
| GET /db/range | Node.js | 1.08 / 2.42 / 3.33 ms | 834.8 MiB | 104.4 MiB |
| GET /db/range | Go | 3.16 / 9.42 / 13.72 ms | 42.1 MiB | 5.3 MiB |
| POST /db/update | Stock Perl | 5.79 / 34.89 / 70.59 ms | 243.4 MiB | 30.4 MiB |
| POST /db/update | MT Perl | 4.40 / 126.88 / 452.96 ms | 138.5 MiB | 17.3 MiB |
| POST /db/update | Node.js | 0.52 / 200.43 / 464.08 ms | 1182.5 MiB | 147.8 MiB |
| POST /db/update | Go | 1.99 / 35.65 / 423.61 ms | 42.7 MiB | 5.3 MiB |

## Notes and Trade-offs

A few patterns stand out clearly in the numbers above:

- **Single-row and multi-query reads (`GET /db/single`, `GET /db/queries?n=20` at 8 workers)**: On `GET /db/single`, Go reaches 116,963 req/s, Node.js 146,756 req/s, MT Perl 33,144 req/s, and Stock Perl 25,211 req/s. On 20-query fan-out (`GET /db/queries?n=20`), Go reaches 10,575 req/s, Node.js 15,168 req/s, MT Perl 15,114 req/s, and Stock Perl 10,872 req/s. Compiled native code (Go) and V8 + C++ `node:sqlite` (Node.js) still have lower per-request HTTP + JSON overhead than an interpreted Perl stack, though MT Perl narrows the gap significantly compared to stock `prefork` (1.31x on `/db/single`, 1.39x on `/db/queries?n=20`).
- **50-row range scan with trailing-space trimming (`GET /db/range` at 8 workers)**: Go achieves 17,663 req/s, Node.js 51,019 req/s, MT Perl 20,093 req/s, and Stock Perl 8,728 req/s. MT Perl posts a 2.30x gain over Stock Perl here thanks to Tier-1 `PERL_XS_THREADSAFE` execution, `SQLITE_OPEN_NOMUTEX`, and `dbi-mt` SIMD-assisted `ChopBlanks` trimming.
- **WAL single-writer serialization (`POST /db/update` at 8 workers)**: SQLite WAL permits only one active writer at a time, so write-lock contention and per-transaction turnaround dominate both throughput and tail latency (Stock Perl 9,949 req/s, MT Perl 10,646 req/s, Node.js 29,853 req/s, Go 27,731 req/s). Look closely at tail latency as well: p99 is 70.59 ms for Stock Perl, 452.96 ms for MT Perl, 464.08 ms for Node.js, and 423.61 ms for Go.
- **Memory footprint (process-tree RSS at 8 workers on `GET /db/single`)**: Go's single compiled static-style binary uses the least memory (41.5 MiB total), followed by MT Perl's single multi-threaded process (136.3 MiB total), Stock Perl `prefork` (231.6 MiB total), and multi-process `node:cluster` (743.3 MiB total across 8 worker processes + primary). Multi-process architectures pay a per-worker runtime footprint that single-process Go and `perl5-mt` avoid.
- **Scope caveat**: These micro-endpoints exercise raw HTTP parsing, prepared-statement SQLite queries, and small JSON serialization. Real applications spend much more time in templates, validation, authentication, business logic, and networked database I/O, where relative rankings can shift substantially.

If you spot a fairness issue in any of the four implementations, or if you run `./run_polyglot.sh` on Linux, x86_64, POWER, or another OS and see different behavior, feedback and counterexamples are welcome.
