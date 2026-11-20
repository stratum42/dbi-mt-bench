#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Spec;
use File::Temp qw(tempfile tempdir);
use Getopt::Long qw(GetOptions);
use IO::Socket::INET;
use JSON::PP qw(decode_json);
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

sub _find_bin {
  my (@cands) = @_;
  for my $cand (@cands) {
    if ($cand =~ m{/}) {
      return $cand if -x $cand;
    }
    else {
      for my $dir (split /:/, ($ENV{PATH} // '')) {
        my $p = File::Spec->catfile($dir, $cand);
        return $p if -x $p;
      }
    }
  }
  return undef;
}

my $REPO_DIR          = abs_path(File::Spec->catdir($Bin, '..'));
my $PARENT_DIR        = abs_path(File::Spec->catdir($REPO_DIR, '..'));
my $STOCK_LIB         = $ENV{STOCK_LIB}         // File::Spec->catdir($REPO_DIR, '.stock-lib', 'lib', 'perl5');
my $MOJO_MT_DIR       = $ENV{MOJO_MT_DIR}       // File::Spec->catdir($PARENT_DIR, 'mojolicious-mt');
my $MOJO_UPSTREAM_LIB = $ENV{MOJO_UPSTREAM_LIB} // File::Spec->catdir($MOJO_MT_DIR, '.upstream-base', 'lib');
my $DBI_MT_DIR        = $ENV{DBI_MT_DIR}        // File::Spec->catdir($PARENT_DIR, 'dbi-mt');
my $DBD_SQLITE_MT_DIR = $ENV{DBD_SQLITE_MT_DIR} // File::Spec->catdir($PARENT_DIR, 'dbd-sqlite-mt');
my $DBD_ODBC_MT_DIR   = $ENV{DBD_ODBC_MT_DIR}   // File::Spec->catdir($PARENT_DIR, 'dbd-odbc-mt');
my $PERL5_MT_DIR      = $ENV{PERL5_MT_DIR}      // do {
  my $pgo = File::Spec->catdir($PARENT_DIR, 'perl5-mt-pgo');
  -x File::Spec->catfile($pgo, 'perl') ? $pgo : File::Spec->catdir($PARENT_DIR, 'perl5-mt');
};

my $STOCK_PERL  = $ENV{STOCK_PERL}   // (-x '/opt/homebrew/bin/perl' ? '/opt/homebrew/bin/perl' : (_find_bin('perl') // 'perl'));
my $MT_PERL     = $ENV{PERL5_MT}     // File::Spec->catfile($PERL5_MT_DIR, 'perl');
my $MT_PERL_LIB = $ENV{PERL5_MT_LIB} // File::Spec->catdir($PERL5_MT_DIR, 'lib');
my $WRK_BIN     = $ENV{WRK_BIN}      // _find_bin('/opt/homebrew/bin/wrk', 'wrk') // 'wrk';

my $SEED_SCRIPT = File::Spec->catfile($Bin, 'seed_db.pl');
my $APP_SCRIPT  = File::Spec->catfile($Bin, 'app.pl');
my $CONC_SCRIPT = File::Spec->catfile($Bin, 'dbi_concurrency.pl');
my $SIMD_SCRIPT = File::Spec->catfile($Bin, 'dbi_simd_micro.pl');
my $ODBC_SCRIPT = File::Spec->catfile($Bin, 'odbc_bench.pl');
my $LUA_GET     = File::Spec->catfile($Bin, 'wrk_latency.lua');
my $LUA_POST    = File::Spec->catfile($Bin, 'wrk_post_update.lua');

my $smoke       = 0;
my $out_file    = File::Spec->catfile($REPO_DIR, 'BENCHMARK_RESULTS.md');
my $duration    = 5;
my $passes      = 3;
my $warmup      = 1;
my $threads     = 4;
my $connections = 64;
my $conc_dur    = 3.0;
my $micro_dur   = 1.0;

GetOptions(
  'smoke'         => \$smoke,
  'out=s'         => \$out_file,
  'duration=i'    => \$duration,
  'passes=i'      => \$passes,
  'warmup=i'      => \$warmup,
  'threads=i'     => \$threads,
  'connections=i' => \$connections,
) or die "Usage: $0 [--smoke] [--out FILE] [--duration 5] [--passes 3] [--warmup 1] [--threads 4] [--connections 64]\n";

if ($smoke) {
  $duration    = 2;
  $passes      = 1;
  $warmup      = 1;
  $threads     = 2;
  $connections = 16;
  $conc_dur    = 1.5;
  $micro_dur   = 0.5;
}

my $ACTIVE_SERVER_PID;
sub _cleanup_all {
  _stop_server($ACTIVE_SERVER_PID) if defined $ACTIVE_SERVER_PID;
}
END { local $?; _cleanup_all(); }
$SIG{PIPE} = 'IGNORE';
$SIG{INT}  = sub { _cleanup_all(); exit 130; };
$SIG{TERM} = sub { _cleanup_all(); exit 143; };

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

sub _slurp {
  my ($path) = @_;
  open my $fh, '<', $path or return '';
  local $/;
  my $data = <$fh>;
  close $fh;
  return $data // '';
}

sub _median {
  my @s = sort { $a <=> $b } @_;
  return 0 unless @s;
  return $s[int(@s / 2)];
}

sub _fmt_int {
  my ($n) = @_;
  my $s = sprintf('%.0f', $n // 0);
  1 while $s =~ s/^(-?\d+)(\d{3})/$1,$2/;
  return $s;
}

sub _fmt_ratio {
  my ($num, $den) = @_;
  return 'n/a' unless defined $num && defined $den && $den > 0;
  return sprintf('**%.2fx**', $num / $den);
}

sub _cmd_line {
  my (@cmd) = @_;
  open my $fh, '-|', @cmd or return '';
  my $line = <$fh>;
  close $fh;
  chomp($line //= '');
  return $line;
}

sub _find_free_port {
  my $sock = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'tcp',
    Listen    => 1,
    ReuseAddr => 1,
  ) or die "Cannot allocate ephemeral port: $!\n";
  my $port = $sock->sockport;
  close $sock;
  return $port;
}

sub _sample_tree_rss {
  my ($root_pid) = @_;
  open my $ps, '-|', 'ps', '-o', 'pid=,ppid=,rss=', '-ax' or return (0, 0);
  my (%children, %rss);
  while (my $line = <$ps>) {
    if ($line =~ /^\s*(\d+)\s+(\d+)\s+(\d+)/) {
      my ($p, $pp, $r) = ($1, $2, $3);
      $rss{$p} = $r;
      push @{$children{$pp}}, $p;
    }
  }
  close $ps;
  return (0, 0) unless exists $rss{$root_pid};

  my @queue = ($root_pid);
  my %seen  = ($root_pid => 1);
  my ($total_kib, $count) = (0, 0);
  while (my $p = shift @queue) {
    $total_kib += ($rss{$p} // 0);
    $count++;
    for my $c (@{$children{$p} // []}) {
      next if $seen{$c}++;
      push @queue, $c;
    }
  }
  return ($total_kib / 1024.0, $count);
}

sub _stock_inc_flags {
  return ("-I$STOCK_LIB", "-I$MOJO_UPSTREAM_LIB");
}

sub _mt_inc_flags {
  my @inc = (
    $MT_PERL_LIB,
    File::Spec->catdir($DBI_MT_DIR, 'blib', 'lib'),
    File::Spec->catdir($DBI_MT_DIR, 'blib', 'arch'),
    File::Spec->catdir($DBD_SQLITE_MT_DIR, 'blib', 'lib'),
    File::Spec->catdir($DBD_SQLITE_MT_DIR, 'blib', 'arch'),
    File::Spec->catdir($DBD_ODBC_MT_DIR, 'blib', 'lib'),
    File::Spec->catdir($DBD_ODBC_MT_DIR, 'blib', 'arch'),
  );
  for my $xs_dir (qw(xs xs-keydb)) {
    my $xs_lib  = File::Spec->catdir($MOJO_MT_DIR, $xs_dir, 'blib', 'lib');
    my $xs_arch = File::Spec->catdir($MOJO_MT_DIR, $xs_dir, 'blib', 'arch');
    push @inc, $xs_lib, $xs_arch if -d $xs_lib && -d $xs_arch;
  }
  push @inc, File::Spec->catdir($MOJO_MT_DIR, 'lib');
  return map { "-I$_" } @inc;
}

sub _seed_fresh_db {
  my ($db_path) = @_;
  my $rc = system($STOCK_PERL, "-I$STOCK_LIB", $SEED_SCRIPT, $db_path, 10_000);
  die "Failed to seed DB $db_path (rc=$rc)\n" if $rc != 0;
}

# ---------------------------------------------------------------------------
# HTTP Server lifecycle & wrk execution
# ---------------------------------------------------------------------------

sub _http_request {
  my ($port, $method, $path, $body) = @_;
  my $sock = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
    Timeout  => 2.0,
  ) or return (0, '');

  my $req = "$method $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nConnection: close\r\n";
  if (defined $body) {
    $req .= "Content-Type: application/json\r\nContent-Length: " . length($body) . "\r\n\r\n$body";
  }
  else {
    $req .= "\r\n";
  }
  print $sock $req;
  local $/;
  my $resp = <$sock> // '';
  close $sock;

  my ($hdr, $b) = split /\r\n\r\n/, $resp, 2;
  my $status = 0;
  if (defined $hdr && $hdr =~ m{^HTTP/1\.[01]\s+(\d+)}) {
    $status = int($1);
  }
  return ($status, $b // '');
}

sub _start_server {
  my ($stack, $workers, $db_path) = @_;
  my $port   = _find_free_port();
  my $listen = "http://127.0.0.1:$port";

  my @cmd;
  if ($stack eq 'stock') {
    @cmd = (
      $STOCK_PERL, _stock_inc_flags(), $APP_SCRIPT,
      'prefork', '-m', 'production', '-l', $listen,
      '-w', $workers, '-s', '0', '-a', '1000000', '-r', '100000', '-c', '1000',
    );
  }
  elsif ($stack eq 'mt') {
    @cmd = (
      $MT_PERL, _mt_inc_flags(), $APP_SCRIPT,
      'mt', '-w', $workers, '-l', $listen, '-r', '100000', '-c', '1000', '-s',
    );
  }
  else {
    die "Unknown stack: $stack\n";
  }

  my ($log_fh, $log_path) = tempfile('dbi_bench_srv_XXXX', TMPDIR => 1, UNLINK => 0);
  close $log_fh;

  my $t0  = clock_gettime(CLOCK_MONOTONIC);
  my $pid = fork();
  die "fork failed: $!\n" unless defined $pid;

  if ($pid == 0) {
    setpgrp(0, 0);
    $ENV{MOJO_MODE}             = 'production';
    $ENV{MOJO_LOG_LEVEL}        = 'error';
    $ENV{DBI_BENCH_DB}          = $db_path;
    $ENV{DBI_BENCH_ROWS}        = 10_000;
    $ENV{DBI_BENCH_FORCE_STOCK} = 1 if $stack eq 'stock';
    delete $ENV{PERL5LIB};
    open STDOUT, '>', $log_path or exit 126;
    open STDERR, '>&', \*STDOUT  or exit 126;
    exec(@cmd) or exit 127;
  }

  $ACTIVE_SERVER_PID = $pid;

  my $deadline = $t0 + 20.0;
  my $ready    = 0;
  while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    my $dead = waitpid($pid, WNOHANG);
    if ($dead > 0) {
      $ACTIVE_SERVER_PID = undef;
      my $log = _slurp($log_path);
      unlink $log_path;
      die "Server ($stack -w $workers) exited prematurely:\n$log\n";
    }
    my ($st, $body) = _http_request($port, 'GET', '/health');
    if ($st == 200) {
      $ready = 1;
      last;
    }
    sleep 0.01;
  }
  if (!$ready) {
    _stop_server($pid);
    my $log = _slurp($log_path);
    unlink $log_path;
    die "Server ($stack -w $workers) timed out waiting for /health:\n$log\n";
  }

  # Wait for prefork children to settle
  if ($stack eq 'stock' && $workers > 1) {
    my $target = $workers + 1;
    my $sd = clock_gettime(CLOCK_MONOTONIC) + 5.0;
    while (clock_gettime(CLOCK_MONOTONIC) < $sd) {
      my ($rss, $cnt) = _sample_tree_rss($pid);
      last if $cnt >= $target;
      sleep 0.05;
    }
  }

  return { pid => $pid, port => $port, log_path => $log_path, stack => $stack, workers => $workers };
}

sub _stop_server {
  my ($pid) = @_;
  return unless defined $pid;
  $ACTIVE_SERVER_PID = undef if defined $ACTIVE_SERVER_PID && $ACTIVE_SERVER_PID == $pid;

  kill 'TERM', -$pid;
  kill 'TERM', $pid;
  my $deadline = clock_gettime(CLOCK_MONOTONIC) + 5.0;
  while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    my $res = waitpid($pid, WNOHANG);
    return if $res > 0 || $res == -1;
    sleep 0.05;
  }
  kill 'KILL', -$pid;
  kill 'KILL', $pid;
  waitpid($pid, 0);
}

sub _verify_parity {
  my ($srv) = @_;
  my $p = $srv->{port};

  my ($st, $b) = _http_request($p, 'GET', '/health');
  die "[$srv->{stack}] /health failed ($st)\n" unless $st == 200;
  my $h = decode_json($b);
  die "[$srv->{stack}] /health mode mismatch: got $h->{mode}\n" unless $h->{mode} eq $srv->{stack};

  ($st, $b) = _http_request($p, 'GET', '/db/single');
  die "[$srv->{stack}] /db/single failed ($st)\n" unless $st == 200;
  my $row = decode_json($b);
  die "[$srv->{stack}] /db/single missing id\n" unless ref $row eq 'HASH' && defined $row->{id};

  ($st, $b) = _http_request($p, 'GET', '/db/queries?n=20');
  die "[$srv->{stack}] /db/queries?n=20 failed ($st)\n" unless $st == 200;
  my $qrows = decode_json($b);
  die "[$srv->{stack}] /db/queries?n=20 count != 20\n" unless ref $qrows eq 'ARRAY' && @$qrows == 20;

  ($st, $b) = _http_request($p, 'GET', '/db/range');
  die "[$srv->{stack}] /db/range failed ($st)\n" unless $st == 200;
  my $rrows = decode_json($b);
  die "[$srv->{stack}] /db/range count != 50\n" unless ref $rrows eq 'ARRAY' && @$rrows == 50;
  die "[$srv->{stack}] /db/range ChopBlanks did not strip trailing spaces from code: '$rrows->[0]{code}'\n"
    if $rrows->[0]{code} =~ /\s$/;

  ($st, $b) = _http_request($p, 'POST', '/db/update', '{"delta":1}');
  die "[$srv->{stack}] POST /db/update failed ($st)\n" unless $st == 200;
  my $upd = decode_json($b);
  die "[$srv->{stack}] POST /db/update invalid response\n" unless ref $upd eq 'HASH' && $upd->{updated};

  print STDERR "[parity] $srv->{stack} -w $srv->{workers} OK (DBI $h->{dbi}, DBD::SQLite $h->{dbd_sqlite}, SQLite $h->{sqlite})\n";
}

sub _run_wrk_once {
  my ($srv, $ep, $dur) = @_;
  my $url = "http://127.0.0.1:$srv->{port}$ep->{path}";
  my @cmd = ($WRK_BIN, "-t$threads", "-c$connections", "-d${dur}s", '--latency', '-s', $ep->{lua}, $url);

  my ($out_fh, $out_path) = tempfile('wrk_out_XXXX', TMPDIR => 1, UNLINK => 0);
  close $out_fh;

  my $wpid = fork();
  die "fork wrk failed: $!\n" unless defined $wpid;
  if ($wpid == 0) {
    open STDOUT, '>', $out_path or exit 126;
    open STDERR, '>&', \*STDOUT  or exit 126;
    exec(@cmd) or exit 127;
  }

  my @rss_samples;
  while (1) {
    my $done = waitpid($wpid, WNOHANG);
    last if $done > 0 || $done == -1;
    my ($rss, $cnt) = _sample_tree_rss($srv->{pid});
    push @rss_samples, $rss if $rss > 0;
    sleep 0.2;
  }
  my $status = $?;
  my $out    = _slurp($out_path);
  unlink $out_path;
  die "wrk failed (status=$status):\n$out\n" if $status != 0;

  my %res = (rps => 0, p50_ms => 0, p95_ms => 0, p99_ms => 0, avg_ms => 0, non_2xx => 0, sock_err => 0);
  $res{rps} = $1 + 0 if $out =~ /Requests\/sec:\s+([\d.]+)/;
  if ($out =~ /LATENCY_US\s+p50=([\d.]+)\s+p95=([\d.]+)\s+p99=([\d.]+)\s+avg=([\d.]+)/) {
    $res{p50_ms} = $1 / 1000.0;
    $res{p95_ms} = $2 / 1000.0;
    $res{p99_ms} = $3 / 1000.0;
    $res{avg_ms} = $4 / 1000.0;
  }
  $res{non_2xx} = int($1) if $out =~ /Non-2xx or 3xx responses:\s+(\d+)/;
  if ($out =~ /Socket errors:\s+connect\s+(\d+),\s+read\s+(\d+),\s+write\s+(\d+),\s+timeout\s+(\d+)/) {
    $res{sock_err} = $1 + $2 + $3 + $4;
  }
  $res{rss_mib} = _median(@rss_samples);
  return \%res;
}

sub _bench_endpoint {
  my ($srv, $ep) = @_;
  # Warmup
  _run_wrk_once($srv, $ep, $warmup);

  my @runs;
  for my $pass (1 .. $passes) {
    my $r = _run_wrk_once($srv, $ep, $duration);
    if ($r->{non_2xx} > 0 || $r->{sock_err} > 0) {
      my $srv_log = _slurp($srv->{log_path});
      die "Errors during $srv->{stack} -w $srv->{workers} $ep->{label} pass $pass: non_2xx=$r->{non_2xx} sock_err=$r->{sock_err}\nServer log:\n$srv_log\n";
    }
    push @runs, $r;
  }
  @runs = sort { $a->{rps} <=> $b->{rps} } @runs;
  my $med = $runs[int(@runs / 2)];
  printf STDERR "[http] %-5s w=%d %-22s => %8.1f req/s | p50=%.2fms p95=%.2fms p99=%.2fms | RSS=%.1f MiB\n",
    $srv->{stack}, $srv->{workers}, $ep->{label}, $med->{rps}, $med->{p50_ms}, $med->{p95_ms}, $med->{p99_ms}, $med->{rss_mib};
  return $med;
}

# ---------------------------------------------------------------------------
# Subprocess runner with external RSS sampling (for concurrency & ODBC)
# ---------------------------------------------------------------------------

sub _run_json_cmd_with_rss {
  my ($env_overrides, @cmd) = @_;
  my ($out_fh, $out_path) = tempfile('dbi_cmd_out_XXXX', TMPDIR => 1, UNLINK => 0);
  close $out_fh;

  my $pid = fork();
  die "fork failed: $!\n" unless defined $pid;
  if ($pid == 0) {
    delete $ENV{PERL5LIB};
    for my $k (keys %{$env_overrides // {}}) {
      if (defined $env_overrides->{$k}) {
        $ENV{$k} = $env_overrides->{$k};
      }
      else {
        delete $ENV{$k};
      }
    }
    open STDOUT, '>', $out_path or exit 126;
    open STDERR, '>&', \*STDOUT  or exit 126;
    exec(@cmd) or exit 127;
  }

  my @rss_samples;
  while (1) {
    my $done = waitpid($pid, WNOHANG);
    last if $done > 0 || $done == -1;
    my ($rss, $cnt) = _sample_tree_rss($pid);
    push @rss_samples, $rss if $rss > 0;
    sleep 0.1;
  }
  my $status = $?;
  my $out    = _slurp($out_path);
  unlink $out_path;
  die "Command failed (status=$status): @cmd\n$out\n" if $status != 0;

  my ($json_line) = reverse grep { /^\s*\{/ } split /\n/, $out;
  die "No JSON output from @cmd:\n$out\n" unless defined $json_line;
  my $data = decode_json($json_line);
  $data->{rss_mib} = _median(@rss_samples);
  return $data;
}

# ---------------------------------------------------------------------------
# Main Suite
# ---------------------------------------------------------------------------

my $tmpdir = tempdir('dbi_mt_bench_XXXX', TMPDIR => 1, CLEANUP => 1);

my @ENDPOINTS = (
  { id => 'single',  label => 'GET /db/single',       path => '/db/single',       lua => $LUA_GET  },
  { id => 'queries', label => 'GET /db/queries?n=20', path => '/db/queries?n=20', lua => $LUA_GET  },
  { id => 'range',   label => 'GET /db/range',        path => '/db/range',        lua => $LUA_GET  },
  { id => 'update',  label => 'POST /db/update',      path => '/db/update',       lua => $LUA_POST },
);

my @WORKER_COUNTS = $smoke ? (4) : (4, 8);
my %HTTP_RESULTS;

for my $w (@WORKER_COUNTS) {
  for my $stack (qw(stock mt)) {
    my $db_path = File::Spec->catfile($tmpdir, "http_${stack}_w${w}.db");
    _seed_fresh_db($db_path);
    my $srv = _start_server($stack, $w, $db_path);
    eval {
      _verify_parity($srv);
      for my $ep (@ENDPOINTS) {
        $HTTP_RESULTS{$w}{$stack}{$ep->{id}} = _bench_endpoint($srv, $ep);
      }
    };
    my $err = $@;
    _stop_server($srv->{pid});
    unlink $srv->{log_path};
    die $err if $err;
  }
}

# Part 2a: Direct 8-worker SQLite Concurrency (Stock fork vs perl5-mt MT::Worker)
my %CONC_RESULTS;
for my $wl (qw(read mixed)) {
  for my $stack (qw(stock mt)) {
    my @runs;
    for my $pass (1 .. $passes) {
      my $db_path = File::Spec->catfile($tmpdir, "conc_${stack}_${wl}_p${pass}.db");
      _seed_fresh_db($db_path);
      my @cmd = $stack eq 'stock'
        ? ($STOCK_PERL, "-I$STOCK_LIB", $CONC_SCRIPT, '--mode=fork', "--workload=$wl", '--workers=8', "--duration=$conc_dur", "--db=$db_path")
        : ($MT_PERL, _mt_inc_flags(),   $CONC_SCRIPT, '--mode=mt',   "--workload=$wl", '--workers=8', "--duration=$conc_dur", "--db=$db_path");
      push @runs, _run_json_cmd_with_rss({}, @cmd);
    }
    @runs = sort { $a->{ops_per_sec} <=> $b->{ops_per_sec} } @runs;
    my $med = $runs[int(@runs / 2)];
    $CONC_RESULTS{$wl}{$stack} = $med;
    printf STDERR "[conc] %-5s 8w %-5s => %8.1f ops/s | RSS=%.1f MiB\n",
      $stack, $wl, $med->{ops_per_sec}, $med->{rss_mib};
  }
}

# Part 2b: DBI SIMD Microbenchmarks (Stock vs perl5-mt scalar vs perl5-mt NEON)
my $simd_db = File::Spec->catfile($tmpdir, 'simd_micro.db');
_seed_fresh_db($simd_db);

my $SIMD_STOCK = _run_json_cmd_with_rss(
  { PERL_FORCE_SCALAR => undef },
  $STOCK_PERL, "-I$STOCK_LIB", $SIMD_SCRIPT, "--duration=$micro_dur", "--passes=$passes", "--db=$simd_db"
);
my $SIMD_SCALAR = _run_json_cmd_with_rss(
  { PERL_FORCE_SCALAR => 1 },
  $MT_PERL, _mt_inc_flags(), $SIMD_SCRIPT, "--duration=$micro_dur", "--passes=$passes", "--db=$simd_db"
);
my $SIMD_NEON = _run_json_cmd_with_rss(
  { PERL_FORCE_SCALAR => undef },
  $MT_PERL, _mt_inc_flags(), $SIMD_SCRIPT, "--duration=$micro_dur", "--passes=$passes", "--db=$simd_db"
);
print STDERR "[simd] completed Stock / Scalar / NEON passes\n";

# Part 2c: Live SQLite-over-ODBC (dbd-odbc-mt + sqliteodbc + DBI::MT::Pool)
my @ODBC_WORKERS = $smoke ? (8) : (1, 4, 8);
my %ODBC_RESULTS;
for my $w (@ODBC_WORKERS) {
  for my $wl (qw(read mixed)) {
    my @runs;
    for my $pass (1 .. $passes) {
      my $db_path = File::Spec->catfile($tmpdir, "odbc_w${w}_${wl}_p${pass}.db");
      _seed_fresh_db($db_path);
      my @cmd = ($MT_PERL, _mt_inc_flags(), $ODBC_SCRIPT, "--workers=$w", "--workload=$wl", "--duration=$conc_dur", "--db=$db_path");
      push @runs, _run_json_cmd_with_rss({}, @cmd);
    }
    @runs = sort { $a->{ops_per_sec} <=> $b->{ops_per_sec} } @runs;
    my $med = $runs[int(@runs / 2)];
    $ODBC_RESULTS{$w}{$wl} = $med;
    printf STDERR "[odbc] %dw %-5s => %8.1f ops/s | Tier1=%d | RSS=%.1f MiB\n",
      $w, $wl, $med->{ops_per_sec}, $med->{tier1}, $med->{rss_mib};
  }
}

# ---------------------------------------------------------------------------
# Gather environment metadata & generate BENCHMARK_RESULTS.md
# ---------------------------------------------------------------------------

sub _display_path {
  my ($path) = @_;
  return 'n/a' unless defined $path && length $path;
  if (defined $REPO_DIR && index($path, "$REPO_DIR/") == 0) {
    return './' . substr($path, length($REPO_DIR) + 1);
  }
  if (defined $PARENT_DIR && index($path, "$PARENT_DIR/") == 0) {
    return '../' . substr($path, length($PARENT_DIR) + 1);
  }
  if (defined $ENV{HOME} && length $ENV{HOME} && index($path, "$ENV{HOME}/") == 0) {
    return '~/' . substr($path, length($ENV{HOME}) + 1);
  }
  return $path;
}

sub _stock_git_ref {
  my ($dir) = @_;
  my $origin = _cmd_line('git', '-C', $dir, 'rev-parse', '--short', 'origin/HEAD');
  return $origin if length $origin;
  return _cmd_line('git', '-C', $dir, 'rev-parse', '--short', 'HEAD') || 'unknown';
}

my $os_name = _cmd_line('uname', '-s') || $^O;
my $arch    = _cmd_line('uname', '-m') || 'unknown';
my $cpu_brand = _cmd_line('sysctl', '-n', 'machdep.cpu.brand_string');
if (!length $cpu_brand && -r '/proc/cpuinfo') {
  my $cpuinfo = _slurp('/proc/cpuinfo');
  $cpu_brand = $1 if $cpuinfo =~ /^model name\s*:\s*(.+)$/m;
}
$cpu_brand ||= $arch;

my $ncpu = _cmd_line('sysctl', '-n', 'hw.ncpu') || _cmd_line('nproc') || 'unknown';
my $os_desc;
if ($os_name eq 'Darwin') {
  my $os_ver = _cmd_line('sw_vers', '-productVersion') || '';
  $os_desc = length $os_ver ? "macOS $os_ver ($arch)" : "macOS ($arch)";
}
else {
  my $os_rel = _cmd_line('uname', '-r') || '';
  $os_desc = length $os_rel ? "$os_name $os_rel ($arch)" : "$os_name ($arch)";
}

my $stock_ver   = _cmd_line($STOCK_PERL, '-e', 'print $^V');
my $mt_ver      = _cmd_line($MT_PERL, '-e', 'print $^V');
my $dbi_ver     = _cmd_line($STOCK_PERL, "-I$STOCK_LIB", '-MDBI', '-e', 'print $DBI::VERSION');
my $sqlite_ver  = _cmd_line($STOCK_PERL, "-I$STOCK_LIB", '-MDBD::SQLite', '-e', 'print "$DBD::SQLite::VERSION (SQLite $DBD::SQLite::sqlite_version)"');
my $mojo_ver    = _cmd_line($STOCK_PERL, "-I$MOJO_UPSTREAM_LIB", '-MMojolicious', '-e', 'print $Mojolicious::VERSION');
my $odbc_ver    = $ODBC_RESULTS{$ODBC_WORKERS[0]}{read}{odbc_ver} // 'n/a';
my $odbc_drv    = _display_path($ODBC_RESULTS{$ODBC_WORKERS[0]}{read}{driver} // 'n/a');
my $dbi_head    = _stock_git_ref($DBI_MT_DIR);
my $sqlite_head = _stock_git_ref($DBD_SQLITE_MT_DIR);
my $stock_perl_disp = _display_path($STOCK_PERL);
my $mt_perl_disp    = _display_path($MT_PERL);

my @md;
push @md, "# dbi-mt Benchmark Results";
push @md, "";
push @md, "Side-by-side measurements comparing a stock Perl 5 + Mojolicious + DBI + DBD::SQLite stack against the experimental multi-threaded stack (`perl5-mt` + `mojolicious-mt` + `dbi-mt` + `dbd-sqlite-mt` + `dbd-odbc-mt`) on $cpu_brand ($ncpu logical cores, $os_desc).";
push @md, "";
push @md, "These numbers are offered as working measurements, not guarantees. Both stacks depend heavily on decades of upstream work by the Perl 5, Mojolicious, DBI, DBD::SQLite, DBD::ODBC, and SQLite communities. Please run `./run_bench.sh` on your own hardware and treat any figure here with healthy skepticism until you see it reproduce.";
push @md, "";
push @md, "## Test Environment & Methodology";
push @md, "";
push @md, "- **Hardware / OS**: $cpu_brand ($ncpu logical cores), $os_desc";
push @md, "- **Stock Stack**:";
push @md, "  - Perl: `$stock_perl_disp` (`$stock_ver`)";
push @md, "  - Mojolicious: `$mojo_ver` (clean upstream `.upstream-base/lib`, `prefork` server)";
push @md, "  - DBI: `$dbi_ver` (clean upstream `$dbi_head`, compiled into `.stock-lib`)";
push @md, "  - DBD::SQLite: `$sqlite_ver` (clean upstream `$sqlite_head`, compiled into `.stock-lib`)";
push @md, "- **MT Stack**:";
push @md, "  - Perl: `$mt_perl_disp` (`$mt_ver`, `perl5-mt`)";
push @md, "  - Mojolicious: `mojolicious-mt` (`mt` worker server + Tier-1 XS)";
push @md, "  - DBI: `dbi-mt` (`$dbi_ver` + `DBI::MT::Pool` + Tier-1 `PERL_XS_THREADSAFE` + SIMD)";
push @md, "  - DBD::SQLite: `dbd-sqlite-mt` (`$sqlite_ver`, Tier-1 `PERL_XS_THREADSAFE=1`)";
push @md, "  - DBD::ODBC: `dbd-odbc-mt` (`$odbc_ver`, Tier-1 `PERL_XS_THREADSAFE=1`) + `$odbc_drv`";
push @md, "- **Database**: Freshly seeded 10,000-row WAL-mode SQLite database per run (`PRAGMA journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=15000`, `temp_store=MEMORY`, `cache_size=-16000`), with fixed-width trailing-space padded `CHAR(32)`/`CHAR(24)`/`CHAR(64)` columns to exercise `ChopBlanks => 1`.";
push @md, "- **HTTP Load Generator**: `wrk -t$threads -c$connections -d${duration}s --latency` (${warmup}s warmup, median of $passes passes, exact p50/p95/p99 from `wrk` HDR histogram via Lua `done()`, 0 non-2xx and 0 socket errors enforced).";
push @md, "- **RSS Measurement**: Total process-tree RSS (`ps -o pid=,ppid=,rss= -ax`) sampled during active load (median MiB).";
push @md, "- **Reproduce**: `./run_bench.sh`";
push @md, "";
push @md, "Note that this is a whole-stack comparison rather than a single-variable isolation: the stock baseline runs Perl `$stock_ver`, while `perl5-mt` is forked from `$mt_ver` (built with PGO/native flags when `../perl5-mt-pgo/perl` is present).";
push @md, "";

push @md, "## 1. End-to-End HTTP + SQLite API Benchmark";
push @md, "";
push @md, "Identical Mojolicious app (`bench/app.pl`), identical SQL queries, and a fresh 10,000-row WAL-mode SQLite database for each run. Stock runs `prefork` with a per-worker persistent `\$dbh`; MT runs `mt` with `DBI::MT::Pool` and Tier-1 `PERL_XS_THREADSAFE`.";
push @md, "";

for my $w (@WORKER_COUNTS) {
  push @md, "### ${w}-Worker Comparison (`prefork -w $w` vs `mt -w $w`)";
  push @md, "";
  push @md, "| Endpoint | Stock (req/s) | MT (req/s) | Speedup | Stock p50 / p95 / p99 | MT p50 / p95 / p99 | Stock RSS (total / per-w) | MT RSS (total / per-w) | RSS Savings |";
  push @md, "|---|---:|---:|---:|---:|---:|---:|---:|---:|";
  for my $ep (@ENDPOINTS) {
    my $s = $HTTP_RESULTS{$w}{stock}{$ep->{id}};
    my $m = $HTTP_RESULTS{$w}{mt}{$ep->{id}};
    my $rss_sav = ($s->{rss_mib} > 0) ? sprintf('**%.1f%%**', (1.0 - $m->{rss_mib} / $s->{rss_mib}) * 100.0) : 'n/a';
    push @md, sprintf(
      "| %s | %s | %s | %s | %.2f / %.2f / %.2f ms | %.2f / %.2f / %.2f ms | %.1f MiB (%.1f) | %.1f MiB (%.1f) | %s |",
      $ep->{label},
      _fmt_int($s->{rps}),
      _fmt_int($m->{rps}),
      _fmt_ratio($m->{rps}, $s->{rps}),
      $s->{p50_ms}, $s->{p95_ms}, $s->{p99_ms},
      $m->{p50_ms}, $m->{p95_ms}, $m->{p99_ms},
      $s->{rss_mib}, $s->{rss_mib} / $w,
      $m->{rss_mib}, $m->{rss_mib} / $w,
      $rss_sav,
    );
  }
  push @md, "";
}

push @md, "## 2. Direct DBI & Driver Concurrency Benchmarks";
push @md, "";
push @md, "### 2a. 8-Worker SQLite Throughput (Stock `fork` vs `perl5-mt` `MT::Worker`)";
push @md, "";
push @md, "Direct DBI + DBD::SQLite (no HTTP layer), 8 concurrent workers against a 10,000-row WAL-mode SQLite DB (median of $passes x ${conc_dur}s passes).";
push @md, "- **Concurrent Reads**: 10 random point lookups + 1 fifty-row `ChopBlanks => 1` range scan per loop.";
push @md, "- **Mixed Reads & Writes**: 90% random point lookups + 10% transactional `BEGIN IMMEDIATE` point updates (`busy_timeout=15000`).";
push @md, "";
push @md, "| Workload (8 workers) | Stock `fork` (ops/s) | MT `MT::Worker` (ops/s) | Speedup | Stock RSS | MT RSS | RSS Savings |";
push @md, "|---|---:|---:|---:|---:|---:|---:|";
for my $wl_info (
  ['read',  'Concurrent Reads (point + 50-row ChopBlanks)'],
  ['mixed', 'Mixed 90% Reads / 10% Transactional Writes'],
) {
  my ($wl, $label) = @$wl_info;
  my $s = $CONC_RESULTS{$wl}{stock};
  my $m = $CONC_RESULTS{$wl}{mt};
  my $rss_sav = ($s->{rss_mib} > 0) ? sprintf('**%.1f%%**', (1.0 - $m->{rss_mib} / $s->{rss_mib}) * 100.0) : 'n/a';
  push @md, sprintf(
    "| %s | %s | %s | %s | %.1f MiB | %.1f MiB | %s |",
    $label,
    _fmt_int($s->{ops_per_sec}),
    _fmt_int($m->{ops_per_sec}),
    _fmt_ratio($m->{ops_per_sec}, $s->{ops_per_sec}),
    $s->{rss_mib},
    $m->{rss_mib},
    $rss_sav,
  );
}
push @md, "";

push @md, "### 2b. DBI SIMD Microbenchmarks (`ChopBlanks`, `preparse`, `neatsvpv`)";
push @md, "";
push @md, "Median of $passes x ${micro_dur}s passes comparing Stock Perl + Stock DBI, `perl5-mt` + `dbi-mt` with `PERL_FORCE_SCALAR=1` (scalar reference twin), and `perl5-mt` + `dbi-mt` with SIMD enabled (default).";
push @md, "";
push @md, "| Operation | Stock DBI (ops/s) | `dbi-mt` Scalar (`PERL_FORCE_SCALAR=1`) | `dbi-mt` SIMD (ops/s) | SIMD vs Stock | SIMD vs Scalar |";
push @md, "|---|---:|---:|---:|---:|---:|";

for my $item (
  ['chopblanks_char_512',   'ChopBlanks => 1 (SQLite :memory:, 50 rows x 3 CHAR(512))'],
  ['chopblanks_sqlite_50',  'ChopBlanks => 1 (DBD::SQLite WAL, 50-row range scan)'],
  ['preparse_short',        'DBI::preparse (short SQL, 4 named placeholders)'],
  ['preparse_long',         'DBI::preparse (long SQL, 7 placeholders + literals/comments)'],
  ['neat_ascii_64',         'DBI::neat / neatsvpv (64B clean ASCII)'],
  ['neat_ascii_512',        'DBI::neat / neatsvpv (512B clean ASCII)'],
  ['neat_mixed_128',        'DBI::neat / neatsvpv (128B mixed quotes/tabs)'],
) {
  my ($k, $label) = @$item;
  my $st = $SIMD_STOCK->{$k};
  my $sc = $SIMD_SCALAR->{$k};
  my $ne = $SIMD_NEON->{$k};
  next unless defined $st && defined $sc && defined $ne;
  push @md, sprintf(
    "| %s | %s | %s | %s | %s | %s |",
    $label,
    _fmt_int($st),
    _fmt_int($sc),
    _fmt_int($ne),
    _fmt_ratio($ne, $st),
    _fmt_ratio($ne, $sc),
  );
}
push @md, "";

push @md, "### 2c. Live SQLite-over-ODBC (`dbd-odbc-mt` + `sqliteodbc` + `DBI::MT::Pool`)";
push @md, "";
push @md, "Live ODBC concurrency benchmark using `dbd-odbc-mt` (`$odbc_ver`, Tier-1 `PERL_XS_THREADSAFE=1`) + `sqliteodbc` (`$odbc_drv`) + `DBI::MT::Pool` across `MT::Worker` threads (median of $passes x ${conc_dur}s passes).";
push @md, "";
push @md, "| `MT::Worker` Threads | Concurrent Reads (ops/s) | Mixed 90/10 R/W (ops/s) | Tier-1 XS | Read RSS | Mixed RSS |";
push @md, "|---:|---:|---:|:---:|---:|---:|";
for my $w (@ODBC_WORKERS) {
  my $r = $ODBC_RESULTS{$w}{read};
  my $m = $ODBC_RESULTS{$w}{mixed};
  push @md, sprintf(
    "| %d | %s | %s | %s | %.1f MiB | %.1f MiB |",
    $w,
    _fmt_int($r->{ops_per_sec}),
    _fmt_int($m->{ops_per_sec}),
    ($r->{tier1} ? 'Yes' : 'No'),
    $r->{rss_mib},
    $m->{rss_mib},
  );
}
push @md, "";

push @md, "## Notes and Trade-offs";
push @md, "";
push @md, "A few results deserve plain explanation so the tables are not misread:";
push @md, "";

if (exists $CONC_RESULTS{mixed}{stock} && exists $CONC_RESULTS{mixed}{mt}) {
  my $s = $CONC_RESULTS{mixed}{stock};
  my $m = $CONC_RESULTS{mixed}{mt};
  my $rss_sav = ($s->{rss_mib} > 0) ? sprintf('%.1f%%', (1.0 - $m->{rss_mib} / $s->{rss_mib}) * 100.0) : 'n/a';
  push @md, sprintf(
    "- **Mixed 90/10 read/write contention (Section 2a)**: With `SQLITE_OPEN_NOMUTEX` and an adaptive sub-millisecond WAL busy handler, `MT::Worker` sits close to stock `fork` (%s vs %s ops/s, %s) while using %s less RSS (%.1f vs %.1f MiB), though separate OS processes still edge ahead slightly under heavy concurrent WAL write contention.",
    _fmt_int($m->{ops_per_sec}), _fmt_int($s->{ops_per_sec}), _fmt_ratio($m->{ops_per_sec}, $s->{ops_per_sec}),
    $rss_sav, $m->{rss_mib}, $s->{rss_mib},
  );
}

if (exists $HTTP_RESULTS{8}{stock}{update} && exists $HTTP_RESULTS{8}{mt}{update}) {
  my $s8 = $HTTP_RESULTS{8}{stock}{update};
  my $m8 = $HTTP_RESULTS{8}{mt}{update};
  my $s4 = $HTTP_RESULTS{4}{stock}{update};
  my $m4 = $HTTP_RESULTS{4}{mt}{update};
  push @md, sprintf(
    "- **WAL single-writer serialization on `POST /db/update` (Section 1)**: SQLite WAL only permits one active writer at a time, so throughput is essentially flat across both stacks (%s at 4 workers, %s at 8 workers). The adaptive busy handler substantially reduces 8-worker MT tail latency compared to SQLite's coarse default backoff, but MT p95/p99 (%.2f / %.2f ms) still trails stock `prefork` (%.2f / %.2f ms) when 8 threads contend on the single writer lock. Write-heavy SQLite workloads remain more predictable under `prefork` at high worker counts.",
    _fmt_ratio($m4->{rps}, $s4->{rps}), _fmt_ratio($m8->{rps}, $s8->{rps}),
    $m8->{p95_ms}, $m8->{p99_ms}, $s8->{p95_ms}, $s8->{p99_ms},
  );
}

if (defined $SIMD_NEON->{chopblanks_char_512} && defined $SIMD_SCALAR->{chopblanks_char_512} && defined $SIMD_STOCK->{chopblanks_char_512}) {
  push @md, sprintf(
    "- **`ChopBlanks => 1` on SQLite (Section 2b)**: Wiring `dbi_rtrim_spaces_len` into `dbd-sqlite-mt` yields a clear win on wide trailing-space-padded `CHAR(512)` columns (%s vs stock, %s vs scalar). On shorter WAL columns (50-row range scan), query execution and SV allocation still dominate, so SIMD vs scalar is essentially neutral (%s), with the %s gain over stock coming mostly from `SQLITE_OPEN_NOMUTEX` and runtime differences.",
    _fmt_ratio($SIMD_NEON->{chopblanks_char_512}, $SIMD_STOCK->{chopblanks_char_512}),
    _fmt_ratio($SIMD_NEON->{chopblanks_char_512}, $SIMD_SCALAR->{chopblanks_char_512}),
    _fmt_ratio($SIMD_NEON->{chopblanks_sqlite_50}, $SIMD_SCALAR->{chopblanks_sqlite_50}),
    _fmt_ratio($SIMD_NEON->{chopblanks_sqlite_50}, $SIMD_STOCK->{chopblanks_sqlite_50}),
  );
}

if (defined $SIMD_NEON->{neat_ascii_512} && defined $SIMD_NEON->{neat_mixed_128} && defined $SIMD_NEON->{neat_ascii_64}) {
  push @md, sprintf(
    "- **`DBI::neat` / `neatsvpv` (Section 2b)**: Gating SIMD scanning on strings >= 128 bytes eliminates the earlier regression against the scalar twin: 128B mixed strings are now %s vs scalar (%s vs stock), 64B clean ASCII stays at scalar parity (%s vs scalar, %s vs stock), and 512B clean ASCII benefits from SIMD (%s vs stock, %s vs scalar). On short inputs, stock Perl `$stock_ver` remains slightly faster.",
    _fmt_ratio($SIMD_NEON->{neat_mixed_128}, $SIMD_SCALAR->{neat_mixed_128}),
    _fmt_ratio($SIMD_NEON->{neat_mixed_128}, $SIMD_STOCK->{neat_mixed_128}),
    _fmt_ratio($SIMD_NEON->{neat_ascii_64}, $SIMD_SCALAR->{neat_ascii_64}),
    _fmt_ratio($SIMD_NEON->{neat_ascii_64}, $SIMD_STOCK->{neat_ascii_64}),
    _fmt_ratio($SIMD_NEON->{neat_ascii_512}, $SIMD_STOCK->{neat_ascii_512}),
    _fmt_ratio($SIMD_NEON->{neat_ascii_512}, $SIMD_SCALAR->{neat_ascii_512}),
  );
}

if (exists $ODBC_RESULTS{1}{read} && exists $ODBC_RESULTS{8}{read}) {
  push @md, sprintf(
    "- **ODBC thread scaling (Section 2c)**: `dbd-odbc-mt` runs under Tier-1 `PERL_XS_THREADSAFE=1` with `DBI::MT::Pool`, but read throughput tapers from 1 thread (%s ops/s) to 8 threads (%s ops/s) as threads contend on `sqliteodbc` / `unixODBC` internal mutexes and the connection pool cap.",
    _fmt_int($ODBC_RESULTS{1}{read}{ops_per_sec}),
    _fmt_int($ODBC_RESULTS{8}{read}{ops_per_sec}),
  );
}

push @md, "";
push @md, "If you run `./run_bench.sh` on other hardware, operating systems, or database engines, feedback and counterexamples are welcome.";
push @md, "";

open my $out, '>', $out_file or die "Cannot write $out_file: $!\n";
print $out join("\n", @md);
close $out;

print STDERR "[done] Wrote $out_file\n";
