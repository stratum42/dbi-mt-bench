#!/usr/bin/env perl
package DBIBenchApp;
use Mojo::Base 'Mojolicious', -signatures;

use DBI ();
use DBD::SQLite ();

our $DB_PATH;
our $DSN;
our $USE_MT_POOL;
our $POOL;
our $STOCK_DBH;
our $STOCK_PID;
our $ROW_COUNT;

BEGIN {
  $DB_PATH     = $ENV{DBI_BENCH_DB}   || die "DBI_BENCH_DB environment variable must be set\n";
  $ROW_COUNT   = int($ENV{DBI_BENCH_ROWS} || 10_000);
  $DSN         = "dbi:SQLite:dbname=$DB_PATH";
  $STOCK_PID   = 0;
  $USE_MT_POOL = 0;

  if (!$ENV{DBI_BENCH_FORCE_STOCK} && eval { require MT; require DBI::MT::Pool; 1 }) {
    $USE_MT_POOL = 1;
  }
}

sub _configure_dbh ($dbh) {
  $dbh->do('PRAGMA busy_timeout = 15000');
  $dbh->do('PRAGMA synchronous = NORMAL');
  $dbh->do('PRAGMA temp_store = MEMORY');
  $dbh->do('PRAGMA cache_size = -16000');
  return $dbh;
}

sub _with_dbh ($cb) {
  if ($USE_MT_POOL) {
    return $POOL->with_dbh($cb);
  }

  # Stock prefork: one persistent DBH per worker PID (never shared across fork)
  if (!$STOCK_DBH || $STOCK_PID != $$ || !$STOCK_DBH->{Active}) {
    $STOCK_PID = $$;
    $STOCK_DBH = DBI->connect(
      $DSN, '', '',
      {
        RaiseError          => 1,
        PrintError          => 0,
        AutoCommit          => 1,
        sqlite_busy_timeout => 15_000,
      }
    ) or die "Stock DBI->connect failed: $DBI::errstr\n";
    _configure_dbh($STOCK_DBH);
  }
  return $cb->($STOCK_DBH);
}

sub startup ($self) {
  $self->log->level($ENV{MOJO_LOG_LEVEL} // 'error');
  $self->secrets(['dbi-mt-bench-secret']);

  if ($USE_MT_POOL) {
    $POOL = DBI::MT::Pool->new(
      dsn              => $DSN,
      max_connections  => 4,
      ping_on_checkout => 0,
      attr             => {
        RaiseError          => 1,
        PrintError          => 0,
        AutoCommit          => 1,
        sqlite_busy_timeout => 15_000,
      },
      on_connect => sub {
        my ($dbh) = @_;
        _configure_dbh($dbh);
      },
    );
  }

  my $r = $self->routes;

  # Readiness / health check
  $r->get('/health' => sub ($c) {
    $c->render(json => {
      status     => 'ok',
      mode       => ($USE_MT_POOL ? 'mt' : 'stock'),
      dbi        => "$DBI::VERSION",
      dbd_sqlite => "$DBD::SQLite::VERSION",
      sqlite     => "$DBD::SQLite::sqlite_version",
    });
  });

  # 1. GET /db/single: single random row lookup -> JSON
  $r->get('/db/single' => sub ($c) {
    my $id  = int(rand($ROW_COUNT)) + 1;
    my $row = _with_dbh(sub ($dbh) {
      my $sth = $dbh->prepare_cached(
        'SELECT id, code, name, category, price, counter, notes, updated_at FROM items WHERE id = ?'
      );
      $sth->execute($id);
      my $r = $sth->fetchrow_hashref;
      $sth->finish;
      return $r;
    });
    return $c->render(status => 404, json => {error => 'not found'}) unless $row;
    $c->render(json => $row);
  });

  # 2. GET /db/queries?n=20: N random row lookups -> JSON array
  $r->get('/db/queries' => sub ($c) {
    my $n = int($c->param('n') // 20);
    $n = 1   if $n < 1;
    $n = 500 if $n > 500;

    my $rows = _with_dbh(sub ($dbh) {
      my $sth = $dbh->prepare_cached(
        'SELECT id, code, name, category, price, counter, notes, updated_at FROM items WHERE id = ?'
      );
      my @out;
      $#out = $n - 1;
      for my $i (0 .. $n - 1) {
        my $id = int(rand($ROW_COUNT)) + 1;
        $sth->execute($id);
        $out[$i] = $sth->fetchrow_hashref;
        $sth->finish;
      }
      return \@out;
    });
    $c->render(json => $rows);
  });

  # 3. GET /db/range: 50-row range scan with ChopBlanks => 1 -> JSON array
  $r->get('/db/range' => sub ($c) {
    my $max_start = $ROW_COUNT > 50 ? $ROW_COUNT - 50 : 1;
    my $start     = int(rand($max_start)) + 1;
    my $end       = $start + 50;

    my $rows = _with_dbh(sub ($dbh) {
      my $sth = $dbh->prepare_cached(
        'SELECT id, code, name, category, price, counter, notes, updated_at FROM items WHERE id >= ? AND id < ? ORDER BY id'
      );
      $sth->{ChopBlanks} = 1;
      $sth->execute($start, $end);
      my $all = $sth->fetchall_arrayref({});
      $sth->finish;
      return $all;
    });
    $c->render(json => $rows);
  });

  # 4. POST /db/update: transactional point update with busy_timeout -> JSON
  $r->post('/db/update' => sub ($c) {
    my $id = int(rand($ROW_COUNT)) + 1;
    my $ts = time();

    my $res = _with_dbh(sub ($dbh) {
      my $sth = $dbh->prepare_cached(
        'UPDATE items SET counter = counter + 1, updated_at = ? WHERE id = ?'
      );
      my $attempts = 0;
      while (1) {
        $attempts++;
        my $ok = eval {
          $dbh->do('BEGIN IMMEDIATE');
          $sth->execute($ts, $id);
          $dbh->do('COMMIT');
          1;
        };
        if ($ok) {
          last;
        }
        my $err = $@;
        eval { $dbh->do('ROLLBACK') };
        if ($err =~ /locked|busy/i && $attempts < 20) {
          select(undef, undef, undef, 0.002 * $attempts);
          next;
        }
        die $err;
      }
      return {id => $id, updated => 1, updated_at => $ts};
    });
    $c->render(json => $res);
  });
}

unless (caller) {
  require Mojolicious::Commands;
  Mojolicious::Commands->start_app('DBIBenchApp');
}

1;
