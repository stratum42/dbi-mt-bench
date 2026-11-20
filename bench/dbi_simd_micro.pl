#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use JSON::PP qw(encode_json);
use DBI ();
use DBD::SQLite ();

my $pass_sec = 1.0;
my $passes   = 3;
my $db_path  = '';

GetOptions(
  'duration=f' => \$pass_sec,
  'passes=i'   => \$passes,
  'db=s'       => \$db_path,
) or die "Usage: $0 [--duration 1.0] [--passes 3] [--db PATH]\n";

sub _median {
  my @s = sort { $a <=> $b } @_;
  return $s[int(@s / 2)];
}

sub _bench {
  my ($name, $code) = @_;
  # Warmup
  my $w_end = clock_gettime(CLOCK_MONOTONIC) + 0.15;
  while (clock_gettime(CLOCK_MONOTONIC) < $w_end) {
    $code->();
  }
  my @rates;
  for (1 .. $passes) {
    my $ops = 0;
    my $t0  = clock_gettime(CLOCK_MONOTONIC);
    my $end = $t0 + $pass_sec;
    while (clock_gettime(CLOCK_MONOTONIC) < $end) {
      # Batch 16 iterations per clock check to minimize timer overhead
      $code->(); $code->(); $code->(); $code->();
      $code->(); $code->(); $code->(); $code->();
      $code->(); $code->(); $code->(); $code->();
      $code->(); $code->(); $code->(); $code->();
      $ops += 16;
    }
    my $dt = clock_gettime(CLOCK_MONOTONIC) - $t0;
    push @rates, $ops / $dt;
  }
  return sprintf('%.1f', _median(@rates)) + 0;
}

my $null_dbh = DBI->connect('dbi:NullP:', '', '', { RaiseError => 1, PrintError => 0 });

# 1. ChopBlanks via in-memory SQLite (50 rows x 3 CHAR(512) trailing-space padded columns)
my $mem_dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
  RaiseError => 1, PrintError => 0, AutoCommit => 1,
});
$mem_dbh->do('CREATE TABLE wide_char (id INTEGER PRIMARY KEY, c1 CHAR(512), c2 CHAR(512), c3 CHAR(512))');
{
  my $ins = $mem_dbh->prepare('INSERT INTO wide_char (id, c1, c2, c3) VALUES (?, ?, ?, ?)');
  for my $i (1 .. 50) {
    $ins->execute(
      $i,
      sprintf('%-512s', "SKU-ITEM-$i"),
      sprintf('%-512s', "CATEGORY-BENCHMARK-$i"),
      sprintf('%-512s', "Fixed-width CHAR(512) trailing-space payload row $i"),
    );
  }
  $ins->finish;
}
my $wide_sth = $mem_dbh->prepare('SELECT c1, c2, c3 FROM wide_char ORDER BY id');
$wide_sth->{ChopBlanks} = 1;

my $chop_char_512 = _bench('chopblanks_char_512', sub {
  $wide_sth->execute;
  my $r = $wide_sth->fetchall_arrayref;
  $wide_sth->finish;
});
$wide_sth->finish;
$mem_dbh->disconnect;

# 2. ChopBlanks via real SQLite 50-row range fetch (if --db provided)
my $chop_sqlite_50;
if (length $db_path && -f $db_path) {
  my $sdbh = DBI->connect("dbi:SQLite:dbname=$db_path", '', '', {
    RaiseError => 1, PrintError => 0, AutoCommit => 1,
  });
  my $sth = $sdbh->prepare(
    'SELECT id, code, category, notes FROM items WHERE id >= 1 AND id <= 50 ORDER BY id'
  );
  $sth->{ChopBlanks} = 1;
  $chop_sqlite_50 = _bench('chopblanks_sqlite_50', sub {
    $sth->execute;
    my $r = $sth->fetchall_arrayref;
    $sth->finish;
  });
  $sth->finish;
  $sdbh->disconnect;
}

# 3. DBI::preparse (realistic multi-placeholder SQL with quoted literals & comments)
my $sql_short = 'SELECT id, code, name, price FROM items WHERE category = :p1 AND price >= :p2 AND price <= :p3 ORDER BY id LIMIT :p4';
my $sql_long  = join(' ',
  'SELECT a.id, a.code, a.name, a.category, a.price, a.counter, a.notes, a.updated_at',
  'FROM items a INNER JOIN items b ON a.category = b.category',
  'WHERE a.id >= :p1 AND a.id <= :p2 AND a.price BETWEEN :p3 AND :p4',
  q{AND a.name NOT LIKE 'skip''s :literal_colon -- not a comment'},
  '/* block comment with ignored placeholder and extra padding text for SIMD scan */',
  'AND a.notes IS NOT NULL AND a.counter >= :p5',
  'ORDER BY a.price DESC, a.id ASC LIMIT :p6 OFFSET :p7'
);

my $preparse_short = _bench('preparse_short', sub {
  my $out = $null_dbh->preparse($sql_short, DBI::DBIpp_ph_qm(), DBI::DBIpp_ph_XX());
});

my $preparse_long = _bench('preparse_long', sub {
  my $out = $null_dbh->preparse($sql_long, DBI::DBIpp_ph_qm(), DBI::DBIpp_ph_XX() | DBI::DBIpp_cm_cs());
});

# 4. DBI::neat (neatsvpv): ASCII 64B, ASCII 512B, and quoted/mixed 128B
my $str_ascii_64  = 'BenchmarkItem-SKU-000123-electronics-us-east-1-production-v2.001';
my $str_ascii_512 = ($str_ascii_64 x 8);
my $str_mixed_128 = qq{User "Alice" & 'Bob' <tag> line1\tval=42; path=/var/db/items/00123; note="quoted'text" } . ('x' x 44);

my $neat_ascii_64 = _bench('neat_ascii_64', sub {
  my $s = DBI::neat($str_ascii_64, 1024);
});

my $neat_ascii_512 = _bench('neat_ascii_512', sub {
  my $s = DBI::neat($str_ascii_512, 1024);
});

my $neat_mixed_128 = _bench('neat_mixed_128', sub {
  my $s = DBI::neat($str_mixed_128, 1024);
});

$null_dbh->disconnect;

my %results = (
  chopblanks_char_512   => $chop_char_512,
  (defined $chop_sqlite_50 ? (chopblanks_sqlite_50 => $chop_sqlite_50) : ()),
  preparse_short        => $preparse_short,
  preparse_long         => $preparse_long,
  neat_ascii_64         => $neat_ascii_64,
  neat_ascii_512        => $neat_ascii_512,
  neat_mixed_128        => $neat_mixed_128,
  force_scalar          => ($ENV{PERL_FORCE_SCALAR} ? 1 : 0),
  dbi_version           => "$DBI::VERSION",
);

print encode_json(\%results) . "\n";
