# dbi-mt Benchmark Results

Side-by-side measurements comparing a stock Perl 5 + Mojolicious + DBI + DBD::SQLite stack against the experimental multi-threaded stack (`perl5-mt` + `mojolicious-mt` + `dbi-mt` + `dbd-sqlite-mt` + `dbd-odbc-mt`) on an Apple M2 Max (12 logical cores, macOS 27.2.1, arm64).

These numbers are offered as working measurements, not guarantees. Both stacks rely on decades of upstream work by the Perl 5, Mojolicious, DBI, DBD::SQLite, DBD::ODBC, and SQLite communities. Where stock Perl and `prefork` are faster or equal, those rows are shown right alongside the wins and discussed in the notes below. Please run `./run_bench.sh` on your own machine and treat any figure here with healthy skepticism until you see it reproduce.

## Test Environment & Methodology

- **Hardware / OS**: Apple M2 Max (12 logical cores), macOS 27.2.1 (arm64)
- **Stock Stack**:
  - Perl: `/opt/homebrew/bin/perl` (`v5.44.0`, Homebrew arm64)
  - Mojolicious: `9.55` (clean upstream `.upstream-base/lib`, `prefork` server)
  - DBI: `1.657` (clean upstream `dd2c386`, compiled into `.stock-lib`)
  - DBD::SQLite: `1.78 (SQLite 3.54.1)` (clean upstream `4ee4da7`, compiled into `.stock-lib`)
- **MT Stack**:
  - Perl: `../perl5-mt-pgo/perl` (`v5.40.2`, `perl5-mt` PGO+native)
  - Mojolicious: `mojolicious-mt` (`mt` worker server + Tier-1 XS/NEON)
  - DBI: `dbi-mt` (`1.657` + `DBI::MT::Pool` + Tier-1 `PERL_XS_THREADSAFE` + NEON SIMD)
  - DBD::SQLite: `dbd-sqlite-mt` (`1.78 (SQLite 3.54.1)`, Tier-1 `PERL_XS_THREADSAFE=1`)
  - DBD::ODBC: `dbd-odbc-mt` (`1.62_1`, Tier-1 `PERL_XS_THREADSAFE=1`) + `/opt/homebrew/opt/sqliteodbc/lib/libsqlite3odbc.dylib`
- **Database**: Freshly seeded 10,000-row WAL-mode SQLite database per run (`PRAGMA journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=15000`, `temp_store=MEMORY`, `cache_size=-16000`), with fixed-width trailing-space padded `CHAR(32)`/`CHAR(24)`/`CHAR(64)` columns to exercise `ChopBlanks => 1`.
- **HTTP Load Generator**: `wrk -t4 -c64 -d5s --latency` (1s warmup, median of 3 passes, exact p50/p95/p99 from `wrk` HDR histogram via Lua `done()`, 0 non-2xx and 0 socket errors enforced).
- **RSS Measurement**: Total process-tree RSS (`ps -o pid=,ppid=,rss= -ax`) sampled during active load (median MiB).
- **Reproduce**: `./run_bench.sh`

Note that this is a whole-stack comparison rather than a single-variable isolation: the stock baseline runs Perl `v5.44.0` from Homebrew, while `perl5-mt` is forked from `v5.40.2` and built with PGO and `-march=native`.

## 1. End-to-End HTTP + SQLite API Benchmark

Identical Mojolicious app (`bench/app.pl`), identical SQL queries, and a fresh 10,000-row WAL-mode SQLite database for each run. Stock runs `prefork` with a per-worker persistent `$dbh`; MT runs `mt` with `DBI::MT::Pool` and Tier-1 `PERL_XS_THREADSAFE`.

### 4-Worker Comparison (`prefork -w 4` vs `mt -w 4`)

| Endpoint | Stock (req/s) | MT (req/s) | Speedup | Stock p50 / p95 / p99 | MT p50 / p95 / p99 | Stock RSS (total / per-w) | MT RSS (total / per-w) | RSS Savings |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| GET /db/single | 15,519 | 20,157 | **1.30x** | 3.31 / 7.28 / 7.75 ms | 3.12 / 3.60 / 5.96 ms | 137.4 MiB (34.4) | 120.8 MiB (30.2) | **12.1%** |
| GET /db/queries?n=20 | 6,765 | 9,681 | **1.43x** | 12.26 / 22.45 / 23.54 ms | 6.51 / 7.12 / 12.62 ms | 142.1 MiB (35.5) | 121.2 MiB (30.3) | **14.8%** |
| GET /db/range | 4,756 | 11,798 | **2.48x** | 12.61 / 26.29 / 27.05 ms | 5.30 / 5.95 / 10.45 ms | 145.5 MiB (36.4) | 121.6 MiB (30.4) | **16.4%** |
| POST /db/update | 8,319 | 9,269 | **1.11x** | 5.07 / 26.48 / 42.63 ms | 5.86 / 24.29 / 52.69 ms | 146.2 MiB (36.6) | 121.6 MiB (30.4) | **16.8%** |

### 8-Worker Comparison (`prefork -w 8` vs `mt -w 8`)

| Endpoint | Stock (req/s) | MT (req/s) | Speedup | Stock p50 / p95 / p99 | MT p50 / p95 / p99 | Stock RSS (total / per-w) | MT RSS (total / per-w) | RSS Savings |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| GET /db/single | 26,244 | 34,700 | **1.32x** | 1.95 / 6.43 / 8.18 ms | 1.66 / 3.24 / 4.26 ms | 227.1 MiB (28.4) | 136.9 MiB (17.1) | **39.7%** |
| GET /db/queries?n=20 | 11,219 | 15,544 | **1.39x** | 5.57 / 13.34 / 16.18 ms | 3.83 / 7.12 / 8.35 ms | 234.4 MiB (29.3) | 137.8 MiB (17.2) | **41.2%** |
| GET /db/range | 7,924 | 20,580 | **2.60x** | 8.09 / 19.34 / 24.81 ms | 2.84 / 5.45 / 7.02 ms | 239.7 MiB (30.0) | 138.7 MiB (17.3) | **42.2%** |
| POST /db/update | 10,073 | 10,301 | **1.02x** | 6.25 / 35.16 / 73.45 ms | 4.26 / 292.45 / 671.41 ms | 240.7 MiB (30.1) | 138.8 MiB (17.3) | **42.3%** |

## 2. Direct DBI & Driver Concurrency Benchmarks

### 2a. 8-Worker SQLite Throughput (Stock `fork` vs `perl5-mt` `MT::Worker`)

Direct DBI + DBD::SQLite (no HTTP layer), 8 concurrent workers against a 10,000-row WAL-mode SQLite DB (median of 3 x 3s passes).
- **Concurrent Reads**: 10 random point lookups + 1 fifty-row `ChopBlanks => 1` range scan per loop.
- **Mixed Reads & Writes**: 90% random point lookups + 10% transactional `BEGIN IMMEDIATE` point updates (`busy_timeout=15000`).

| Workload (8 workers) | Stock `fork` (ops/s) | MT `MT::Worker` (ops/s) | Speedup | Stock RSS | MT RSS | RSS Savings |
|---|---:|---:|---:|---:|---:|---:|
| Concurrent Reads (point + 50-row ChopBlanks) | 315,728 | 589,214 | **1.87x** | 87.7 MiB | 70.3 MiB | **19.8%** |
| Mixed 90% Reads / 10% Transactional Writes | 230,222 | 197,518 | **0.86x** | 83.1 MiB | 56.3 MiB | **32.2%** |

### 2b. DBI SIMD Microbenchmarks (`ChopBlanks`, `preparse`, `neatsvpv`)

Median of 3 x 1s passes comparing Stock Perl + Stock DBI, `perl5-mt` + `dbi-mt` with `PERL_FORCE_SCALAR=1` (scalar reference twin), and `perl5-mt` + `dbi-mt` with NEON SIMD (default).

| Operation | Stock DBI (ops/s) | `dbi-mt` Scalar (`PERL_FORCE_SCALAR=1`) | `dbi-mt` NEON (ops/s) | NEON vs Stock | NEON vs Scalar |
|---|---:|---:|---:|---:|---:|
| ChopBlanks => 1 (SQLite :memory:, 50 rows x 3 CHAR(512)) | 15,859 | 15,825 | 15,791 | **1.00x** | **1.00x** |
| ChopBlanks => 1 (DBD::SQLite WAL, 50-row range scan) | 32,260 | 32,243 | 32,286 | **1.00x** | **1.00x** |
| DBI::preparse (short SQL, 4 named placeholders) | 1,014,905 | 1,721,924 | 1,709,581 | **1.68x** | **0.99x** |
| DBI::preparse (long SQL, 7 placeholders + literals/comments) | 429,893 | 813,312 | 891,177 | **2.07x** | **1.10x** |
| DBI::neat / neatsvpv (64B clean ASCII) | 4,061,444 | 3,337,635 | 3,945,284 | **0.97x** | **1.18x** |
| DBI::neat / neatsvpv (512B clean ASCII) | 1,761,652 | 1,361,103 | 2,828,885 | **1.61x** | **2.08x** |
| DBI::neat / neatsvpv (128B mixed quotes/tabs) | 3,371,010 | 2,944,810 | 2,869,994 | **0.85x** | **0.97x** |

### 2c. Live SQLite-over-ODBC (`dbd-odbc-mt` + `sqliteodbc` + `DBI::MT::Pool`)

Live ODBC concurrency benchmark using `dbd-odbc-mt` (`1.62_1`, Tier-1 `PERL_XS_THREADSAFE=1`) + Homebrew `sqliteodbc` (`/opt/homebrew/opt/sqliteodbc/lib/libsqlite3odbc.dylib`) + `DBI::MT::Pool` across `MT::Worker` threads (median of 3 x 3s passes).

| `MT::Worker` Threads | Concurrent Reads (ops/s) | Mixed 90/10 R/W (ops/s) | Tier-1 XS | Read RSS | Mixed RSS |
|---:|---:|---:|:---:|---:|---:|
| 1 | 164,412 | 137,722 | Yes | 50.7 MiB | 50.8 MiB |
| 4 | 195,908 | 140,838 | Yes | 58.9 MiB | 53.2 MiB |
| 8 | 107,093 | 141,736 | Yes | 69.9 MiB | 55.1 MiB |

## Notes and Trade-offs

A few results deserve plain explanation so the tables are not misread:

- **Mixed 90/10 read/write contention (Section 2a)**: Stock `fork` beats `MT::Worker` here (230,222 vs 197,518 ops/s, **0.86x**). Under heavy SQLite WAL write contention, separate OS processes avoid shared in-process lock and allocator traffic, though `MT::Worker` uses 32.2% less RSS (56.3 vs 83.1 MiB).
- **WAL single-writer serialization on `POST /db/update` (Section 1)**: SQLite WAL only permits one active writer at a time, so throughput is effectively flat across both stacks (**1.11x** at 4 workers, **1.02x** at 8 workers). At 8 workers, the MT stack also shows much higher tail latency (p95 292.45 ms / p99 671.41 ms vs stock's 35.16 / 73.45 ms) when 8 threads contend on the single writer lock and retry under `busy_timeout`. If your workload is write-heavy against SQLite, `prefork` currently behaves more predictably at high worker counts.
- **`ChopBlanks => 1` on SQLite (Section 2b)**: Completely neutral (**1.00x** vs stock and **1.00x** vs scalar). SQLite's query execution and Perl SV allocation dominate row fetching, so SIMD trailing-space trimming makes no measurable difference here.
- **`DBI::neat` / `neatsvpv` (Section 2b)**: The SIMD scan helps on longer clean ASCII strings (512B is **1.61x** vs stock and **2.08x** vs scalar), but short 64B strings (**0.97x** vs stock) and 128B strings containing quotes or tabs (**0.85x** vs stock, **0.97x** vs scalar) exit early enough that the stock Perl 5.44.0 path stays slightly ahead.
- **ODBC 8-thread reads (Section 2c)**: Throughput rises from 1 to 4 threads (164,412 to 195,908 ops/s) and then falls at 8 threads (107,093 ops/s) as threads contend on `sqliteodbc` / `unixODBC` internals and the 2-connection pool cap.

If you run `./run_bench.sh` on other hardware, operating systems, or database engines, feedback and counterexamples are welcome.
