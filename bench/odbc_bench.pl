#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use JSON::PP qw(encode_json);
use MT ();
use DBI ();
use DBI::MT::Pool ();
use DBD::ODBC ();

my $workers  = 8;
my $duration = 3.0;
my $workload = 'read'; # read | mixed
my $db_path  = '';
my $rows     = 10_000;

GetOptions(
  'workers=i'  => \$workers,
  'duration=f' => \$duration,
  'workload=s' => \$workload,
  'db=s'       => \$db_path,
  'rows=i'     => \$rows,
) or die "Usage: $0 --workers=8 --duration=3 --workload=read|mixed --db=PATH\n";

die "--db PATH is required\n" unless length $db_path && -f $db_path;

sub find_sqlite_odbc_driver {
  my @cands = (
    $ENV{DBI_ODBC_SQLITE_DRIVER} ? ($ENV{DBI_ODBC_SQLITE_DRIVER}) : (),
    '/opt/homebrew/opt/sqliteodbc/lib/libsqlite3odbc.dylib',
    '/opt/homebrew/lib/libsqlite3odbc.dylib',
    '/usr/local/opt/sqliteodbc/lib/libsqlite3odbc.dylib',
    '/usr/local/lib/libsqlite3odbc.dylib',
    '/usr/lib/x86_64-linux-gnu/odbc/libsqlite3odbc.so',
    '/usr/lib/aarch64-linux-gnu/odbc/libsqlite3odbc.so',
    '/usr/lib64/libsqlite3odbc.so',
    '/usr/lib/libsqlite3odbc.so',
  );
  for my $p (@cands) {
    return $p if defined $p && -f $p;
  }
  die "sqliteodbc driver not found (set DBI_ODBC_SQLITE_DRIVER)\n";
}

my $driver = find_sqlite_odbc_driver();
my $tier1  = MT::XS::is_threadsafe(\&DBD::ODBC::db::_login)
          && MT::XS::is_threadsafe(\&DBD::ODBC::st::_prepare) ? 1 : 0;

our $DSN = "dbi:ODBC:DRIVER=$driver;Database=$db_path;Timeout=15000;";
our $POOL = DBI::MT::Pool->new(
  dsn              => $DSN,
  user             => '',
  pass             => '',
  max_connections  => 2,
  ping_on_checkout => 0,
  attr             => {
    RaiseError => 1,
    PrintError => 0,
    AutoCommit => 1,
  },
  on_connect => sub {
    my ($dbh) = @_;
    $dbh->do('PRAGMA busy_timeout = 15000');
    $dbh->do('PRAGMA synchronous = NORMAL');
  },
);

sub odbc_worker {
  my ($wid, $wl, $dur, $row_count) = @_;
  srand($wid * 2654435761 ^ $$);

  my $ops = 0;
  my $deadline = clock_gettime(CLOCK_MONOTONIC) + $dur;
  my $ts = time();

  if ($wl eq 'read') {
    while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
      $POOL->with_dbh(sub {
        my ($dbh) = @_;
        my $sth = $dbh->prepare_cached(
          'SELECT id, code, name, category, price, counter FROM items WHERE id = ?'
        );
        for (1 .. 10) {
          my $id = int(rand($row_count)) + 1;
          $sth->execute($id);
          my $r = $sth->fetchrow_arrayref;
          $sth->finish;
          $ops++;
        }
      });
    }
  }
  elsif ($wl eq 'mixed') {
    while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
      $POOL->with_dbh(sub {
        my ($dbh) = @_;
        my $sel = $dbh->prepare_cached(
          'SELECT id, code, name, category, price, counter FROM items WHERE id = ?'
        );
        my $upd = $dbh->prepare_cached(
          'UPDATE items SET counter = counter + 1, updated_at = ? WHERE id = ?'
        );
        for (1 .. 9) {
          my $id = int(rand($row_count)) + 1;
          $sel->execute($id);
          my $r = $sel->fetchrow_arrayref;
          $sel->finish;
          $ops++;
        }
        my $id = int(rand($row_count)) + 1;
        my $attempts = 0;
        while (1) {
          $attempts++;
          my $ok = eval {
            $upd->execute($ts, $id);
            1;
          };
          last if $ok;
          my $err = $@;
          if ($err =~ /locked|busy/i && $attempts < 25) {
            select(undef, undef, undef, 0.002 * $attempts);
            next;
          }
          die $err;
        }
        $ops++;
      });
    }
  }
  else {
    die "Unknown workload: $wl\n";
  }

  my $st = $POOL->stats;
  $POOL->disconnect_all;
  return "$ops:$st->{created}:$st->{reused}";
}

MT::Image::freeze();

my $t0 = clock_gettime(CLOCK_MONOTONIC);
my @wids = map {
  MT::Worker::spawn('main::odbc_worker', $_, $workload, $duration, $rows)
} 1 .. $workers;

my ($total_ops, $total_created, $total_reused) = (0, 0, 0);
for my $wid (@wids) {
  my $res = MT::Worker::join($wid);
  my ($o, $c, $r) = split /:/, $res;
  $total_ops     += $o;
  $total_created += $c;
  $total_reused  += $r;
}
my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $t0;
my $ops_sec = $elapsed > 0 ? ($total_ops / $elapsed) : 0;

print encode_json({
  driver      => $driver,
  odbc_ver    => "$DBD::ODBC::VERSION",
  tier1       => $tier1,
  workload    => $workload,
  workers     => $workers,
  elapsed     => sprintf('%.4f', $elapsed) + 0,
  total_ops   => $total_ops,
  ops_per_sec => sprintf('%.1f', $ops_sec) + 0,
  pool_created => $total_created,
  pool_reused  => $total_reused,
}) . "\n";
