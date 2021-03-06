use DBIx::Class::Schema::Loader::Optional::Dependencies
    -skip_all_without => qw(test_backcompat test_rdbms_db2);

use strict;
use warnings;
use lib qw(t/backcompat/0.04006/lib);
use dbixcsl_common_tests;
use Test::More;

my $dsn      = $ENV{DBICTEST_DB2_DSN} || '';
my $user     = $ENV{DBICTEST_DB2_USER} || '';
my $password = $ENV{DBICTEST_DB2_PASS} || '';

dbixcsl_common_tests->new(
    vendor         => 'DB2',
    auto_inc_pk    => 'INTEGER GENERATED BY DEFAULT AS IDENTITY NOT NULL PRIMARY KEY',
    dsn            => $dsn,
    user           => $user,
    password       => $password,
    db_schema      => uc $user,
)->run_tests();
