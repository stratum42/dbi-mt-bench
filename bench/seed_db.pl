#!/usr/bin/env perl
use strict;
use warnings;
use DBI;

my $db_path = $ARGV[0] or die "Usage: $0 <db_path> [row_count]\n";
my $rows    = $ARGV[1] // 10_000;

unlink $db_path, "$db_path-wal", "$db_path-shm", "$db_path-journal";

my $dbh = DBI->connect(
  "dbi:SQLite:dbname=$db_path", '', '',
  {
    RaiseError          => 1,
    PrintError          => 0,
    AutoCommit          => 1,
    sqlite_busy_timeout => 15_000,
  }
) or die "Cannot connect to $db_path: $DBI::errstr\n";

$dbh->do('PRAGMA journal_mode = WAL');
$dbh->do('PRAGMA synchronous = NORMAL');
$dbh->do('PRAGMA temp_store = MEMORY');

$dbh->do(<<'SQL');
CREATE TABLE items (
  id         INTEGER PRIMARY KEY,
  code       CHAR(32) NOT NULL,
  name       TEXT NOT NULL,
  category   CHAR(24) NOT NULL,
  price      REAL NOT NULL,
  counter    INTEGER NOT NULL DEFAULT 0,
  notes      CHAR(64) NOT NULL,
  updated_at INTEGER NOT NULL
)
SQL

$dbh->do('CREATE INDEX idx_items_category ON items(category)');

my @cats = ('electronics', 'books', 'home-garden', 'sports', 'automotive', 'toys', 'music', 'office');

$dbh->begin_work;
my $ins = $dbh->prepare(
  'INSERT INTO items (id, code, name, category, price, counter, notes, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
);

my $now = time();
for my $i (1 .. $rows) {
  my $code  = sprintf('%-32s', sprintf('SKU-%06d', $i));
  my $name  = "Benchmark Item #$i";
  my $cat   = sprintf('%-24s', $cats[$i % scalar(@cats)]);
  my $price = sprintf('%.2f', 9.99 + (($i * 37) % 50000) / 100.0);
  my $notes = sprintf('%-64s', "Record $i payload with trailing CHAR padding");
  $ins->execute($i, $code, $name, $cat, $price + 0, 0, $notes, $now);
}
$ins->finish;
$dbh->commit;

$dbh->do('ANALYZE');
$dbh->do('PRAGMA wal_checkpoint(TRUNCATE)');
$dbh->disconnect;

print "Seeded $rows rows into $db_path (WAL mode)\n";
