use strict;
use warnings;
use SQL::Exec::SQLite ':all';
use Test::Subs;

test {
	connect(':memory:');
	execute('create view v as select 10 a union select 20 a');
	1
};

test {
	SQL::Exec::table_exists('v')
};

test {
	not SQL::Exec::table_exists('w')
};


