# dbi-mt Benchmark Results

Side-by-side measurements comparing a stock Perl 5 + Mojolicious + DBI + DBD::SQLite stack against the experimental multi-threaded stack (`perl5-mt` + `mojolicious-mt` + `dbi-mt` + `dbd-sqlite-mt` + `dbd-odbc-mt`) on Apple M2 Max (12 logical cores, macOS 27.2.1 (arm64)).

These numbers are offered as working measurements, not guarantees. Both stacks depend heavily on decades of upstream work by the Perl 5, Mojolicious, DBI, DBD::SQLite, DBD::ODBC, and SQLite communities. Please run `./run_bench.sh` on your own hardware and treat any figure here with healthy skepticism until you see it reproduce.

## Test Environment & Methodology

- **Hardware / OS**: Apple M2 Max (12 logical cores), macOS 27.2.1 (arm64)
- **Stock Stack**:
  - Perl: `/opt/homebrew/bin/perl` (`v5.44.0`)
  - Mojolicious: `9.55` (clean upstream `.upstream-base/lib`, `prefork` server)
  - DBI: `1.657` (clean upstream `dd2c386`, compiled into `.stock-lib`)
  - DBD::SQLite: `1.78 (SQLite 3.54.1)` (clean upstream `4ee4da7`, compiled into `.stock-lib`)
- **MT Stack**:
  - Perl: `../perl5-mt-pgo/perl` (`v5.40.2`, `perl5-mt`)
  - Mojolicious: `mojolicious-mt` (`mt` worker server + Tier-1 XS)
  - DBI: `dbi-mt` (`1.657` + `DBI::MT::Pool` + Tier-1 `PERL_XS_THREADSAFE` + SIMD)
  - DBD::SQLite: `dbd-sqlite-mt` (`1.78 (SQLite 3.54.1)`, Tier-1 `PERL_XS_THREADSAFE=1`)
  - DBD::ODBC: `dbd-odbc-mt` (`1.62_1`, Tier-1 `PERL_XS_THREADSAFE=1`) + `/opt/homebrew/opt/sqliteodbc/lib/libsqlite3odbc.dylib`
- **Database**: Freshly seeded 10,000-row WAL-mode SQLite database per run (`PRAGMA journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=15000`, `temp_store=MEMORY`, `cache_size=-16000`), with fixed-width trailing-space padded `CHAR(32)`/`CHAR(24)`/`CHAR(64)` columns to exercise `ChopBlanks => 1`.
- **HTTP Load Generator**: `wrk -t4 -c64 -d5s --latency` (1s warmup, median of 3 passes, exact p50/p95/p99 from `wrk` HDR histogram via Lua `done()`, 0 non-2xx and 0 socket errors enforced).
- **RSS Measurement**: Total process-tree RSS (`ps -o pid=,ppid=,rss= -ax`) sampled during active load (median MiB).
- **Reproduce**: `./run_bench.sh`

Note that this is a whole-stack comparison rather than a single-variable isolation: the stock baseline runs Perl `v5.44.0`, while `perl5-mt` is forked from `v5.40.2` (built with PGO/native flags when `../perl5-mt-pgo/perl` is present).

## 1. End-to-End HTTP + SQLite API Benchmark

Identical Mojolicious app (`bench/app.pl`), identical SQL queries, and a fresh 10,000-row WAL-mode SQLite database for each run. Stock runs `prefork` with a per-worker persistent `$dbh`; MT runs `mt` with `DBI::MT::Pool` and Tier-1 `PERL_XS_THREADSAFE`.

### 4-Worker Comparison (`prefork -w 4` vs `mt -w 4`)

| Endpoint | Stock (req/s) | MT (req/s) | Speedup | Stock p50 / p95 / p99 | MT p50 / p95 / p99 | Stock RSS (total / per-w) | MT RSS (total / per-w) | RSS Savings |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| GET /db/single | 18,240 | 23,905 | **1.31x** | 3.00 / 8.22 / 8.94 ms | 2.60 / 3.23 / 5.33 ms | 136.3 MiB (34.1) | 120.4 MiB (30.1) | **11.7%** |
| GET /db/queries?n=20 | 8,133 | 10,765 | **1.32x** | 7.18 / 15.16 / 16.16 ms | 5.88 / 6.66 / 11.31 ms | 139.5 MiB (34.9) | 120.8 MiB (30.2) | **13.4%** |
| GET /db/range | 5,716 | 14,540 | **2.54x** | 12.06 / 19.76 / 22.23 ms | 4.25 / 5.00 / 8.58 ms | 142.6 MiB (35.6) | 121.2 MiB (30.3) | **15.0%** |
| POST /db/update | 8,756 | 9,779 | **1.12x** | 6.53 / 18.13 / 36.68 ms | 5.77 / 28.38 / 73.03 ms | 144.6 MiB (36.1) | 121.2 MiB (30.3) | **16.1%** |

### 8-Worker Comparison (`prefork -w 8` vs `mt -w 8`)

| Endpoint | Stock (req/s) | MT (req/s) | Speedup | Stock p50 / p95 / p99 | MT p50 / p95 / p99 | Stock RSS (total / per-w) | MT RSS (total / per-w) | RSS Savings |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| GET /db/single | 29,812 | 38,548 | **1.29x** | 2.06 / 5.17 / 6.54 ms | 1.49 / 2.95 / 3.89 ms | 228.3 MiB (28.5) | 136.4 MiB (17.1) | **40.2%** |
| GET /db/queries?n=20 | 12,783 | 17,094 | **1.34x** | 2.48 / 15.48 / 18.85 ms | 3.45 / 6.53 / 7.41 ms | 233.5 MiB (29.2) | 137.0 MiB (17.1) | **41.3%** |
| GET /db/range | 9,844 | 23,671 | **2.40x** | 4.42 / 24.16 / 27.91 ms | 2.44 / 4.77 / 6.20 ms | 238.1 MiB (29.8) | 138.0 MiB (17.2) | **42.1%** |
| POST /db/update | 11,131 | 11,037 | **0.99x** | 5.46 / 35.66 / 73.24 ms | 4.13 / 124.94 / 406.62 ms | 239.9 MiB (30.0) | 138.1 MiB (17.3) | **42.4%** |

## 2. Direct DBI & Driver Concurrency Benchmarks

### 2a. 8-Worker SQLite Throughput (Stock `fork` vs `perl5-mt` `MT::Worker`)

Direct DBI + DBD::SQLite (no HTTP layer), 8 concurrent workers against a 10,000-row WAL-mode SQLite DB (median of 3 x 3s passes).
- **Concurrent Reads**: 10 random point lookups + 1 fifty-row `ChopBlanks => 1` range scan per loop.
- **Mixed Reads & Writes**: 90% random point lookups + 10% transactional `BEGIN IMMEDIATE` point updates (`busy_timeout=15000`).

| Workload (8 workers) | Stock `fork` (ops/s) | MT `MT::Worker` (ops/s) | Speedup | Stock RSS | MT RSS | RSS Savings |
|---|---:|---:|---:|---:|---:|---:|
| Concurrent Reads (point + 50-row ChopBlanks) | 343,734 | 708,518 | **2.06x** | 87.1 MiB | 70.8 MiB | **18.7%** |
| Mixed 90% Reads / 10% Transactional Writes | 256,551 | 240,780 | **0.94x** | 84.6 MiB | 56.7 MiB | **33.0%** |

### 2b. DBI SIMD Microbenchmarks (`ChopBlanks`, `preparse`, `neatsvpv`)

Median of 3 x 1s passes comparing Stock Perl + Stock DBI, `perl5-mt` + `dbi-mt` with `PERL_FORCE_SCALAR=1` (scalar reference twin), and `perl5-mt` + `dbi-mt` with SIMD enabled (default).

| Operation | Stock DBI (ops/s) | `dbi-mt` Scalar (`PERL_FORCE_SCALAR=1`) | `dbi-mt` SIMD (ops/s) | SIMD vs Stock | SIMD vs Scalar |
|---|---:|---:|---:|---:|---:|
| ChopBlanks => 1 (SQLite :memory:, 50 rows x 3 CHAR(512)) | 19,477 | 20,610 | 53,340 | **2.74x** | **2.59x** |
| ChopBlanks => 1 (DBD::SQLite WAL, 50-row range scan) | 39,612 | 54,392 | 54,938 | **1.39x** | **1.01x** |
| DBI::preparse (short SQL, 4 named placeholders) | 1,252,696 | 2,056,550 | 2,220,622 | **1.77x** | **1.08x** |
| DBI::preparse (long SQL, 7 placeholders + literals/comments) | 524,912 | 989,109 | 1,134,968 | **2.16x** | **1.15x** |
| DBI::neat / neatsvpv (64B clean ASCII) | 5,022,246 | 4,423,127 | 4,509,292 | **0.90x** | **1.02x** |
| DBI::neat / neatsvpv (512B clean ASCII) | 2,175,121 | 1,676,139 | 3,457,488 | **1.59x** | **2.06x** |
| DBI::neat / neatsvpv (128B mixed quotes/tabs) | 4,085,779 | 3,675,605 | 3,920,700 | **0.96x** | **1.07x** |

### 2c. Live SQLite-over-ODBC (`dbd-odbc-mt` + `sqliteodbc` + `DBI::MT::Pool`)

Live ODBC concurrency benchmark using `dbd-odbc-mt` (`1.62_1`, Tier-1 `PERL_XS_THREADSAFE=1`) + `sqliteodbc` (`/opt/homebrew/opt/sqliteodbc/lib/libsqlite3odbc.dylib`) + `DBI::MT::Pool` across `MT::Worker` threads (median of 3 x 3s passes).

| `MT::Worker` Threads | Concurrent Reads (ops/s) | Mixed 90/10 R/W (ops/s) | Tier-1 XS | Read RSS | Mixed RSS |
|---:|---:|---:|:---:|---:|---:|
| 1 | 193,603 | 164,961 | Yes | 50.5 MiB | 50.5 MiB |
| 4 | 189,500 | 156,590 | Yes | 58.9 MiB | 53.2 MiB |
| 8 | 116,456 | 157,894 | Yes | 69.5 MiB | 55.0 MiB |

## Notes and Trade-offs

A few results deserve plain explanation so the tables are not misread:

- **Mixed 90/10 read/write contention (Section 2a)**: With `SQLITE_OPEN_NOMUTEX` and an adaptive sub-millisecond WAL busy handler, `MT::Worker` sits close to stock `fork` (240,780 vs 256,551 ops/s, **0.94x**) while using 33.0% less RSS (56.7 vs 84.6 MiB), though separate OS processes still edge ahead slightly under heavy concurrent WAL write contention.
- **WAL single-writer serialization on `POST /db/update` (Section 1)**: SQLite WAL only permits one active writer at a time, so throughput is essentially flat across both stacks (**1.12x** at 4 workers, **0.99x** at 8 workers). The adaptive busy handler substantially reduces 8-worker MT tail latency compared to SQLite's coarse default backoff, but MT p95/p99 (124.94 / 406.62 ms) still trails stock `prefork` (35.66 / 73.24 ms) when 8 threads contend on the single writer lock. Write-heavy SQLite workloads remain more predictable under `prefork` at high worker counts.
- **`ChopBlanks => 1` on SQLite (Section 2b)**: Wiring `dbi_rtrim_spaces_len` into `dbd-sqlite-mt` yields a clear win on wide trailing-space-padded `CHAR(512)` columns (**2.74x** vs stock, **2.59x** vs scalar). On shorter WAL columns (50-row range scan), query execution and SV allocation still dominate, so SIMD vs scalar is essentially neutral (**1.01x**), with the **1.39x** gain over stock coming mostly from `SQLITE_OPEN_NOMUTEX` and runtime differences.
- **`DBI::neat` / `neatsvpv` (Section 2b)**: Gating SIMD scanning on strings >= 128 bytes eliminates the earlier regression against the scalar twin: 128B mixed strings are now **1.07x** vs scalar (**0.96x** vs stock), 64B clean ASCII stays at scalar parity (**1.02x** vs scalar, **0.90x** vs stock), and 512B clean ASCII benefits from SIMD (**1.59x** vs stock, **2.06x** vs scalar). On short inputs, stock Perl `v5.44.0` remains slightly faster.
- **ODBC thread scaling (Section 2c)**: `dbd-odbc-mt` runs under Tier-1 `PERL_XS_THREADSAFE=1` with `DBI::MT::Pool`, but read throughput tapers from 1 thread (193,603 ops/s) to 8 threads (116,456 ops/s) as threads contend on `sqliteodbc` / `unixODBC` internal mutexes and the connection pool cap.

If you run `./run_bench.sh` on other hardware, operating systems, or database engines, feedback and counterexamples are welcome.
