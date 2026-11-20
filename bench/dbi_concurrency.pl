#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use JSON::PP qw(encode_json);
use DBI ();
use DBD::SQLite ();

my $mode     = 'fork';   # fork | mt
my $workload = 'read';   # read | mixed
my $workers  = 8;
my $duration = 3.0;
my $db_path  = '';
my $rows     = 10_000;

GetOptions(
  'mode=s'     => \$mode,
  'workload=s' => \$workload,
  'workers=i'  => \$workers,
  'duration=f' => \$duration,
  'db=s'       => \$db_path,
  'rows=i'     => \$rows,
) or die "Usage: $0 --mode=fork|mt --workload=read|mixed --workers=8 --duration=3 --db=PATH\n";

die "--db PATH is required\n" unless length $db_path && -f $db_path;

our $DSN = "dbi:SQLite:dbname=$db_path";

sub worker_task {
  my ($dsn, $wid, $wl, $dur, $row_count) = @_;
  srand($wid * 2654435761 ^ $$);

  my $dbh = DBI->connect(
    $dsn, '', '',
    {
      RaiseError          => 1,
      PrintError          => 0,
      AutoCommit          => 1,
      sqlite_busy_timeout => 15_000,
    }
  ) or die "worker $wid connect failed: $DBI::errstr\n";

  $dbh->do('PRAGMA busy_timeout = 15000');
  $dbh->do('PRAGMA synchronous = NORMAL');
  $dbh->do('PRAGMA temp_store = MEMORY');
  $dbh->do('PRAGMA cache_size = -16000');

  my $sel_one = $dbh->prepare(
    'SELECT id, code, name, category, price, counter, notes, updated_at FROM items WHERE id = ?'
  );
  my $sel_rng = $dbh->prepare(
    'SELECT id, code, name, category, price, counter, notes, updated_at FROM items WHERE id >= ? AND id < ? ORDER BY id'
  );
  $sel_rng->{ChopBlanks} = 1;
  my $upd_one = $dbh->prepare(
    'UPDATE items SET counter = counter + 1, updated_at = ? WHERE id = ?'
  );

  my $ops       = 0;
  my $max_start = $row_count > 50 ? $row_count - 50 : 1;
  my $deadline  = clock_gettime(CLOCK_MONOTONIC) + $dur;

  if ($wl eq 'read') {
    while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
      for (1 .. 10) {
        my $id = int(rand($row_count)) + 1;
        $sel_one->execute($id);
        my $r = $sel_one->fetchrow_arrayref;
        $sel_one->finish;
        $ops++;
      }
      my $start = int(rand($max_start)) + 1;
      $sel_rng->execute($start, $start + 50);
      my $all = $sel_rng->fetchall_arrayref;
      $sel_rng->finish;
      $ops++;
    }
  }
  elsif ($wl eq 'mixed') {
    my $ts = time();
    while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
      for (1 .. 9) {
        my $id = int(rand($row_count)) + 1;
        $sel_one->execute($id);
        my $r = $sel_one->fetchrow_arrayref;
        $sel_one->finish;
        $ops++;
      }
      my $id = int(rand($row_count)) + 1;
      my $attempts = 0;
      while (1) {
        $attempts++;
        my $ok = eval {
          $dbh->do('BEGIN IMMEDIATE');
          $upd_one->execute($ts, $id);
          $dbh->do('COMMIT');
          1;
        };
        last if $ok;
        my $err = $@;
        eval { $dbh->do('ROLLBACK') };
        if ($err =~ /locked|busy/i && $attempts < 25) {
          select(undef, undef, undef, 0.002 * $attempts);
          next;
        }
        die $err;
      }
      $ops++;
    }
  }
  else {
    die "Unknown workload: $wl\n";
  }

  $sel_one->finish;
  $sel_rng->finish;
  $upd_one->finish;
  $dbh->disconnect;
  return $ops;
}

my $t0 = clock_gettime(CLOCK_MONOTONIC);
my $total_ops = 0;

if ($mode eq 'mt') {
  require MT;
  MT::Image::freeze();

  my @wids = map {
    MT::Worker::spawn('main::worker_task', $DSN, $_, $workload, $duration, $rows)
  } 1 .. $workers;

  for my $wid (@wids) {
    $total_ops += MT::Worker::join($wid);
  }
}
elsif ($mode eq 'fork') {
  my @pipes;
  my @pids;
  for my $w (1 .. $workers) {
    pipe(my $r, my $wr) or die "pipe failed: $!\n";
    my $pid = fork();
    die "fork failed: $!\n" unless defined $pid;
    if ($pid == 0) {
      close $r;
      my $ops = worker_task($DSN, $w, $workload, $duration, $rows);
      print $wr "$ops\n";
      close $wr;
      exit 0;
    }
    close $wr;
    push @pipes, $r;
    push @pids, $pid;
  }

  for my $i (0 .. $#pids) {
    my $fh   = $pipes[$i];
    my $line = <$fh>;
    close $fh;
    waitpid($pids[$i], 0);
    die "worker $i failed (status=$?)\n" if $? != 0;
    chomp($line //= '0');
    $total_ops += int($line);
  }
}
else {
  die "Unknown mode: $mode\n";
}

my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $t0;
my $ops_sec = $elapsed > 0 ? ($total_ops / $elapsed) : 0;

print encode_json({
  mode        => $mode,
  workload    => $workload,
  workers     => $workers,
  duration    => $duration,
  elapsed     => sprintf('%.4f', $elapsed) + 0,
  total_ops   => $total_ops,
  ops_per_sec => sprintf('%.1f', $ops_sec) + 0,
}) . "\n";
