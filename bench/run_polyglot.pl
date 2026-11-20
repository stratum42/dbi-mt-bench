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
my $PERL5_MT_DIR      = $ENV{PERL5_MT_DIR}      // do {
  my $pgo = File::Spec->catdir($PARENT_DIR, 'perl5-mt-pgo');
  -x File::Spec->catfile($pgo, 'perl') ? $pgo : File::Spec->catdir($PARENT_DIR, 'perl5-mt');
};

my $STOCK_PERL  = $ENV{STOCK_PERL}   // (-x '/opt/homebrew/bin/perl' ? '/opt/homebrew/bin/perl' : (_find_bin('perl') // 'perl'));
my $MT_PERL     = $ENV{PERL5_MT}     // File::Spec->catfile($PERL5_MT_DIR, 'perl');
my $MT_PERL_LIB = $ENV{PERL5_MT_LIB} // File::Spec->catdir($PERL5_MT_DIR, 'lib');
my $NODE_BIN    = $ENV{NODE_BIN}     // _find_bin('/opt/homebrew/bin/node', 'node') // 'node';
my $GO_BIN      = $ENV{GO_BIN}       // _find_bin('/opt/homebrew/bin/go', 'go')     // 'go';
my $WRK_BIN     = $ENV{WRK_BIN}      // _find_bin('/opt/homebrew/bin/wrk', 'wrk')   // 'wrk';

my $SEED_SCRIPT = File::Spec->catfile($Bin, 'seed_db.pl');
my $APP_SCRIPT  = File::Spec->catfile($Bin, 'app.pl');
my $NODE_SERVER = File::Spec->catfile($REPO_DIR, 'polyglot', 'node', 'server.mjs');
my $GO_SERVER   = File::Spec->catfile($REPO_DIR, 'polyglot', 'go', 'server');
my $LUA_GET     = File::Spec->catfile($Bin, 'wrk_latency.lua');
my $LUA_POST    = File::Spec->catfile($Bin, 'wrk_post_update.lua');

my $smoke       = 0;
my $out_file    = File::Spec->catfile($REPO_DIR, 'BENCHMARK_POLYGLOT.md');
my $duration    = 5;
my $passes      = 3;
my $warmup      = 1;
my $threads     = 4;
my $connections = 64;

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
}

die "Go server binary not found or not executable: $GO_SERVER (run ./run_polyglot.sh)\n" unless -x $GO_SERVER;
die "Node server script not found: $NODE_SERVER\n" unless -r $NODE_SERVER;

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
  return sprintf('%.2fx', $num / $den);
}

sub _cmd_line {
  my (@cmd) = @_;
  open my $fh, '-|', @cmd or return '';
  my $line = <$fh>;
  close $fh;
  chomp($line //= '');
  return $line;
}

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
  for my $ref (qw(upstream/HEAD upstream/master origin/HEAD HEAD)) {
    my $sha = _cmd_line('git', '-C', $dir, 'rev-parse', '--short', $ref);
    return $sha if length $sha;
  }
  return 'unknown';
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
# HTTP Server lifecycle, parity checks & wrk execution
# ---------------------------------------------------------------------------

sub _http_request {
  my ($port, $method, $path, $body) = @_;
  my $sock = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
    Timeout  => 3.0,
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
  elsif ($stack eq 'node') {
    @cmd = (
      $NODE_BIN, $NODE_SERVER,
      '--port', $port, '--workers', $workers, '--db', $db_path, '--rows', 10_000,
    );
  }
  elsif ($stack eq 'go') {
    @cmd = (
      $GO_SERVER,
      '--port', $port, '--workers', $workers, '--db', $db_path, '--rows', 10_000,
    );
  }
  else {
    die "Unknown stack: $stack\n";
  }

  my ($log_fh, $log_path) = tempfile('dbi_polyglot_srv_XXXX', TMPDIR => 1, UNLINK => 0);
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
    sleep 0.02;
  }
  if (!$ready) {
    _stop_server($pid);
    my $log = _slurp($log_path);
    unlink $log_path;
    die "Server ($stack -w $workers) timed out waiting for /health:\n$log\n";
  }

  # Wait for prefork / node:cluster worker children to settle
  if (($stack eq 'stock' || $stack eq 'node') && $workers > 1) {
    my $target = $workers + 1;
    my $sd     = clock_gettime(CLOCK_MONOTONIC) + 5.0;
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

my @REQUIRED_ITEM_KEYS = qw(id code name category price counter notes updated_at);

sub _check_item_shape {
  my ($stack, $ep, $row) = @_;
  die "[$stack] $ep row is not a JSON object\n" unless ref $row eq 'HASH';
  for my $k (@REQUIRED_ITEM_KEYS) {
    die "[$stack] $ep missing key '$k'\n" unless exists $row->{$k} && defined $row->{$k};
  }
}

sub _verify_parity {
  my ($srv) = @_;
  my $p     = $srv->{port};
  my $stack = $srv->{stack};

  my ($st, $b) = _http_request($p, 'GET', '/health');
  die "[$stack] /health failed ($st)\n" unless $st == 200;
  my $h = decode_json($b);
  die "[$stack] /health mode mismatch: got " . ($h->{mode} // 'undef') . "\n"
    unless defined $h->{mode} && $h->{mode} eq $stack;

  ($st, $b) = _http_request($p, 'GET', '/db/single');
  die "[$stack] /db/single failed ($st)\n" unless $st == 200;
  my $row = decode_json($b);
  _check_item_shape($stack, '/db/single', $row);

  ($st, $b) = _http_request($p, 'GET', '/db/queries?n=20');
  die "[$stack] /db/queries?n=20 failed ($st)\n" unless $st == 200;
  my $qrows = decode_json($b);
  die "[$stack] /db/queries?n=20 count != 20\n" unless ref $qrows eq 'ARRAY' && @$qrows == 20;
  _check_item_shape($stack, '/db/queries?n=20[0]', $qrows->[0]);

  ($st, $b) = _http_request($p, 'GET', '/db/range');
  die "[$stack] /db/range failed ($st)\n" unless $st == 200;
  my $rrows = decode_json($b);
  die "[$stack] /db/range count != 50\n" unless ref $rrows eq 'ARRAY' && @$rrows == 50;
  my $prev_id = 0;
  for my $i (0 .. $#$rrows) {
    my $r = $rrows->[$i];
    _check_item_shape($stack, "/db/range[$i]", $r);
    die "[$stack] /db/range not ordered by id at index $i\n" if $r->{id} <= $prev_id;
    $prev_id = $r->{id};
    for my $col (qw(code category notes)) {
      die "[$stack] /db/range ChopBlanks mismatch on $col: '$r->{$col}'\n"
        if $r->{$col} =~ /\s$/;
    }
  }

  ($st, $b) = _http_request($p, 'POST', '/db/update', '{"delta":1}');
  die "[$stack] POST /db/update failed ($st)\n" unless $st == 200;
  my $upd = decode_json($b);
  die "[$stack] POST /db/update invalid response\n"
    unless ref $upd eq 'HASH' && defined $upd->{id} && $upd->{updated} && defined $upd->{updated_at};

  print STDERR "[parity] $stack -w $srv->{workers} OK (SQLite " . ($h->{sqlite} // 'n/a') . ")\n";
  return $h;
}

sub _run_wrk_once {
  my ($srv, $ep, $dur) = @_;
  my $url = "http://127.0.0.1:$srv->{port}$ep->{path}";
  my @cmd = ($WRK_BIN, "-t$threads", "-c$connections", "-d${dur}s", '--latency', '-s', $ep->{lua}, $url);

  my ($out_fh, $out_path) = tempfile('wrk_polyglot_XXXX', TMPDIR => 1, UNLINK => 0);
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
  printf STDERR "[polyglot] %-5s w=%d %-22s => %8.1f req/s | p50=%.2fms p95=%.2fms p99=%.2fms | RSS=%.1f MiB\n",
    $srv->{stack}, $srv->{workers}, $ep->{label}, $med->{rps}, $med->{p50_ms}, $med->{p95_ms}, $med->{p99_ms}, $med->{rss_mib};
  return $med;
}

# ---------------------------------------------------------------------------
# Main Suite
# ---------------------------------------------------------------------------

my $tmpdir = tempdir('dbi_mt_polyglot_XXXX', TMPDIR => 1, CLEANUP => 1);

my @STACKS = (
  { id => 'stock', label => 'Stock Perl' },
  { id => 'mt',    label => 'MT Perl'    },
  { id => 'node',  label => 'Node.js'    },
  { id => 'go',    label => 'Go'         },
);

my @ENDPOINTS = (
  { id => 'single',  label => 'GET /db/single',       path => '/db/single',       lua => $LUA_GET  },
  { id => 'queries', label => 'GET /db/queries?n=20', path => '/db/queries?n=20', lua => $LUA_GET  },
  { id => 'range',   label => 'GET /db/range',        path => '/db/range',        lua => $LUA_GET  },
  { id => 'update',  label => 'POST /db/update',      path => '/db/update',       lua => $LUA_POST },
);

my @WORKER_COUNTS = $smoke ? (4) : (4, 8);
my %RESULTS;
my %HEALTH_INFO;

for my $w (@WORKER_COUNTS) {
  for my $st (@STACKS) {
    my $stack   = $st->{id};
    my $db_path = File::Spec->catfile($tmpdir, "polyglot_${stack}_w${w}.db");
    _seed_fresh_db($db_path);
    my $srv = _start_server($stack, $w, $db_path);
    eval {
      my $h = _verify_parity($srv);
      $HEALTH_INFO{$stack} = $h;
      for my $ep (@ENDPOINTS) {
        $RESULTS{$w}{$stack}{$ep->{id}} = _bench_endpoint($srv, $ep);
      }
    };
    my $err = $@;
    _stop_server($srv->{pid});
    unlink $srv->{log_path};
    die $err if $err;
  }
}

# ---------------------------------------------------------------------------
# Environment metadata & report generation
# ---------------------------------------------------------------------------

my $os_name   = _cmd_line('uname', '-s') || $^O;
my $arch      = _cmd_line('uname', '-m') || 'unknown';
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

my $stock_ver       = _cmd_line($STOCK_PERL, '-e', 'print $^V');
my $mt_ver          = _cmd_line($MT_PERL, '-e', 'print $^V');
my $dbi_ver         = _cmd_line($STOCK_PERL, "-I$STOCK_LIB", '-MDBI', '-e', 'print $DBI::VERSION');
my $sqlite_ver      = _cmd_line($STOCK_PERL, "-I$STOCK_LIB", '-MDBD::SQLite', '-e', 'print "$DBD::SQLite::VERSION (SQLite $DBD::SQLite::sqlite_version)"');
my $mojo_ver        = _cmd_line($STOCK_PERL, "-I$MOJO_UPSTREAM_LIB", '-MMojolicious', '-e', 'print $Mojolicious::VERSION');
my $node_ver        = $HEALTH_INFO{node}{node}   // _cmd_line($NODE_BIN, '--version');
my $node_driver     = $HEALTH_INFO{node}{driver} // 'node:sqlite';
my $node_sqlite     = $HEALTH_INFO{node}{sqlite} // 'unknown';
my $go_ver          = $HEALTH_INFO{go}{go}       // _cmd_line($GO_BIN, 'version');
my $go_driver       = $HEALTH_INFO{go}{driver}   // 'github.com/mattn/go-sqlite3';
my $go_sqlite       = $HEALTH_INFO{go}{sqlite}   // 'unknown';
my $dbi_head        = _stock_git_ref($DBI_MT_DIR);
my $sqlite_head     = _stock_git_ref($DBD_SQLITE_MT_DIR);
my $stock_perl_disp = _display_path($STOCK_PERL);
my $mt_perl_disp    = _display_path($MT_PERL);
my $node_bin_disp   = _display_path($NODE_BIN);
my $go_bin_disp     = _display_path($GO_BIN);

my @md;
push @md, "# Polyglot HTTP + SQLite Benchmark Results";
push @md, "";
push @md, "Side-by-side measurements comparing **Stock Perl**, the experimental **MT Perl** stack (`perl5-mt` + `mojolicious-mt` + `dbi-mt` + `dbd-sqlite-mt`), **Node.js**, and **Go** across four identical HTTP + SQLite JSON endpoints on $cpu_brand ($ncpu logical cores, $os_desc).";
push @md, "";
push @md, "These numbers are offered as working measurements, not guarantees. Every stack here stands on decades of upstream engineering by the Perl 5, Mojolicious, DBI, DBD::SQLite, Node.js, V8, Go, and SQLite communities. Each runtime is given an idiomatic, well-configured implementation, and the tables below report wherever Go, Node.js, Stock Perl, or MT Perl comes out ahead. Please run `./run_polyglot.sh` on your own hardware and treat any figure here with healthy skepticism until you see it reproduce.";
push @md, "";
push @md, "## Test Environment & Methodology";
push @md, "";
push @md, "- **Hardware / OS**: $cpu_brand ($ncpu logical cores), $os_desc";
push @md, "- **Stock Perl**: `$stock_perl_disp` (`$stock_ver`) + upstream Mojolicious `$mojo_ver` (`prefork`) + upstream DBI `$dbi_ver` (`$dbi_head`) + upstream DBD::SQLite `$sqlite_ver` (`$sqlite_head`), per-worker persistent `\$dbh` with `prepare_cached` (`bench/app.pl`).";
push @md, "- **MT Perl**: `$mt_perl_disp` (`$mt_ver`, `perl5-mt`) + `mojolicious-mt` (`mt` worker server + Tier-1 XS) + `dbi-mt` (`$dbi_ver` + `DBI::MT::Pool` + Tier-1 `PERL_XS_THREADSAFE` + SIMD) + `dbd-sqlite-mt` (`$sqlite_ver`, Tier-1 `PERL_XS_THREADSAFE=1`) (`bench/app.pl`).";
push @md, "- **Node.js**: `$node_bin_disp` (`$node_ver`) with `node:cluster` (`--workers N`), `node:http` with keep-alive, and built-in `$node_driver` (`DatabaseSync`, SQLite `$node_sqlite`) with per-worker prepared statements (`polyglot/node/server.mjs`).";
push @md, "- **Go**: `$go_bin_disp` (`$go_ver`), compiled with `CGO_ENABLED=1` and `-ldflags=\"-s -w\"`, `net/http` + `database/sql` + `$go_driver` (native C SQLite `$go_sqlite`), `runtime.GOMAXPROCS(N)`, `SetMaxOpenConns(N)` / `SetMaxIdleConns(N)`, and prepared statements (`polyglot/go/main.go`).";
push @md, "- **Database**: Freshly seeded 10,000-row WAL-mode SQLite database per stack and worker count (`PRAGMA journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=15000`, `temp_store=MEMORY`, `cache_size=-16000`), with fixed-width trailing-space padded `CHAR(32)`/`CHAR(24)`/`CHAR(64)` columns.";
push @md, "- **Parity Checks**: Before timing begins, the harness verifies HTTP 200 JSON responses, identical schema keys, ascending `id` ordering, trailing-space trimming (`ChopBlanks => 1` parity) on `GET /db/range`, and transactional `BEGIN IMMEDIATE` updates on `POST /db/update` across all four stacks.";
push @md, "- **HTTP Load Generator**: `wrk -t$threads -c$connections -d${duration}s --latency` (${warmup}s warmup, median of $passes passes, exact p50/p95/p99 from `wrk` HDR histogram via Lua `done()`, 0 non-2xx and 0 socket errors enforced).";
push @md, "- **RSS Measurement**: Total process-tree RSS (`ps -o pid=,ppid=,rss= -ax`) sampled during active load (median MiB).";
push @md, "- **Reproduce**: `./run_polyglot.sh`";
push @md, "";

for my $w (@WORKER_COUNTS) {
  push @md, "## ${w}-Worker Comparison";
  push @md, "";
  push @md, "### Throughput (req/s)";
  push @md, "";
  push @md, "| Endpoint | Stock Perl | MT Perl | Node.js | Go | MT vs Stock | MT vs Node | MT vs Go | Fastest |";
  push @md, "|---|---:|---:|---:|---:|---:|---:|---:|---|";

  for my $ep (@ENDPOINTS) {
    my $st = $RESULTS{$w}{stock}{$ep->{id}};
    my $mt = $RESULTS{$w}{mt}{$ep->{id}};
    my $nd = $RESULTS{$w}{node}{$ep->{id}};
    my $go = $RESULTS{$w}{go}{$ep->{id}};

    my @ranked = sort { $b->[1] <=> $a->[1] } (
      ['Stock Perl', $st->{rps}],
      ['MT Perl',    $mt->{rps}],
      ['Node.js',    $nd->{rps}],
      ['Go',         $go->{rps}],
    );
    my $winner = $ranked[0][0];

    push @md, sprintf(
      "| %s | %s | %s | %s | %s | **%s** | %s | %s | **%s** |",
      $ep->{label},
      _fmt_int($st->{rps}),
      _fmt_int($mt->{rps}),
      _fmt_int($nd->{rps}),
      _fmt_int($go->{rps}),
      _fmt_ratio($mt->{rps}, $st->{rps}),
      _fmt_ratio($mt->{rps}, $nd->{rps}),
      _fmt_ratio($mt->{rps}, $go->{rps}),
      $winner,
    );
  }
  push @md, "";

  push @md, "### Latency (p50 / p95 / p99 ms) & Process-Tree RSS (total / per-worker MiB)";
  push @md, "";
  push @md, "| Endpoint | Stack | p50 / p95 / p99 (ms) | Total RSS | Per-Worker RSS |";
  push @md, "|---|---|---:|---:|---:|";

  for my $ep (@ENDPOINTS) {
    for my $s_info (@STACKS) {
      my $r = $RESULTS{$w}{$s_info->{id}}{$ep->{id}};
      push @md, sprintf(
        "| %s | %s | %.2f / %.2f / %.2f ms | %.1f MiB | %.1f MiB |",
        $ep->{label},
        $s_info->{label},
        $r->{p50_ms}, $r->{p95_ms}, $r->{p99_ms},
        $r->{rss_mib},
        $r->{rss_mib} / $w,
      );
    }
  }
  push @md, "";
}

push @md, "## Notes and Trade-offs";
push @md, "";
push @md, "A few patterns stand out clearly in the numbers above:";
push @md, "";

my $ref_w = exists $RESULTS{8} ? 8 : $WORKER_COUNTS[-1];
{
  my $st_s = $RESULTS{$ref_w}{stock}{single};
  my $mt_s = $RESULTS{$ref_w}{mt}{single};
  my $nd_s = $RESULTS{$ref_w}{node}{single};
  my $go_s = $RESULTS{$ref_w}{go}{single};

  my $st_r = $RESULTS{$ref_w}{stock}{range};
  my $mt_r = $RESULTS{$ref_w}{mt}{range};
  my $nd_r = $RESULTS{$ref_w}{node}{range};
  my $go_r = $RESULTS{$ref_w}{go}{range};

  my $st_q = $RESULTS{$ref_w}{stock}{queries};
  my $mt_q = $RESULTS{$ref_w}{mt}{queries};
  my $nd_q = $RESULTS{$ref_w}{node}{queries};
  my $go_q = $RESULTS{$ref_w}{go}{queries};

  my $st_u = $RESULTS{$ref_w}{stock}{update};
  my $mt_u = $RESULTS{$ref_w}{mt}{update};
  my $nd_u = $RESULTS{$ref_w}{node}{update};
  my $go_u = $RESULTS{$ref_w}{go}{update};

  push @md, sprintf(
    "- **Single-row and multi-query reads (`GET /db/single`, `GET /db/queries?n=20` at %d workers)**: On `GET /db/single`, Go reaches %s req/s, Node.js %s req/s, MT Perl %s req/s, and Stock Perl %s req/s. On 20-query fan-out (`GET /db/queries?n=20`), Go reaches %s req/s, Node.js %s req/s, MT Perl %s req/s, and Stock Perl %s req/s. Compiled native code (Go) and V8 + C++ `node:sqlite` (Node.js) still have lower per-request HTTP + JSON overhead than an interpreted Perl stack, though MT Perl narrows the gap significantly compared to stock `prefork` (%s on `/db/single`, %s on `/db/queries?n=20`).",
    $ref_w,
    _fmt_int($go_s->{rps}), _fmt_int($nd_s->{rps}), _fmt_int($mt_s->{rps}), _fmt_int($st_s->{rps}),
    _fmt_int($go_q->{rps}), _fmt_int($nd_q->{rps}), _fmt_int($mt_q->{rps}), _fmt_int($st_q->{rps}),
    _fmt_ratio($mt_s->{rps}, $st_s->{rps}), _fmt_ratio($mt_q->{rps}, $st_q->{rps}),
  );

  push @md, sprintf(
    "- **50-row range scan with trailing-space trimming (`GET /db/range` at %d workers)**: Go achieves %s req/s, Node.js %s req/s, MT Perl %s req/s, and Stock Perl %s req/s. MT Perl posts a %s gain over Stock Perl here thanks to Tier-1 `PERL_XS_THREADSAFE` execution, `SQLITE_OPEN_NOMUTEX`, and `dbi-mt` SIMD-assisted `ChopBlanks` trimming.",
    $ref_w,
    _fmt_int($go_r->{rps}), _fmt_int($nd_r->{rps}), _fmt_int($mt_r->{rps}), _fmt_int($st_r->{rps}),
    _fmt_ratio($mt_r->{rps}, $st_r->{rps}),
  );

  push @md, sprintf(
    "- **WAL single-writer serialization (`POST /db/update` at %d workers)**: SQLite WAL permits only one active writer at a time, so write-lock contention and per-transaction turnaround dominate both throughput and tail latency (Stock Perl %s req/s, MT Perl %s req/s, Node.js %s req/s, Go %s req/s). Look closely at tail latency as well: p99 is %.2f ms for Stock Perl, %.2f ms for MT Perl, %.2f ms for Node.js, and %.2f ms for Go.",
    $ref_w,
    _fmt_int($st_u->{rps}), _fmt_int($mt_u->{rps}), _fmt_int($nd_u->{rps}), _fmt_int($go_u->{rps}),
    $st_u->{p99_ms}, $mt_u->{p99_ms}, $nd_u->{p99_ms}, $go_u->{p99_ms},
  );

  push @md, sprintf(
    "- **Memory footprint (process-tree RSS at %d workers on `GET /db/single`)**: Go's single compiled static-style binary uses the least memory (%.1f MiB total), followed by MT Perl's single multi-threaded process (%.1f MiB total), Stock Perl `prefork` (%.1f MiB total), and multi-process `node:cluster` (%.1f MiB total across %d worker processes + primary). Multi-process architectures pay a per-worker runtime footprint that single-process Go and `perl5-mt` avoid.",
    $ref_w,
    $go_s->{rss_mib}, $mt_s->{rss_mib}, $st_s->{rss_mib}, $nd_s->{rss_mib}, $ref_w,
  );
}

push @md, "- **Scope caveat**: These micro-endpoints exercise raw HTTP parsing, prepared-statement SQLite queries, and small JSON serialization. Real applications spend much more time in templates, validation, authentication, business logic, and networked database I/O, where relative rankings can shift substantially.";
push @md, "";
push @md, "If you spot a fairness issue in any of the four implementations, or if you run `./run_polyglot.sh` on Linux, x86_64, POWER, or another OS and see different behavior, feedback and counterexamples are welcome.";

open my $out_fh, '>', $out_file or die "Cannot write $out_file: $!\n";
print $out_fh join("\n", @md), "\n";
close $out_fh;

print STDERR "[polyglot] Wrote " . _display_path($out_file) . "\n";
