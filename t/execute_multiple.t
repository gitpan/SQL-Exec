use strict;
use warnings;
use SQL::Exec::SQLite ':all';
use Test::Subs;

test {
	connect(':memory:');
	execute('create table t (a);create table u (a unique); create table v (a unique)');
	not errstr;
};

test {
	execute_multiple('insert into t values (?)', [1], [2], [3])
};

test {
	query_one_column('select a from t') ~~ [1, 2, 3]
};

test {
	execute_multiple('insert into t values (?)', 1, 2, 3)
};

test {
	execute_multiple('insert into t values (?)', [[1], [2], [3]])
};

fail {
	execute_multiple('insert into u values (?)', 1, 2, 2)
};

test {
	query_one_column('select a from u') ~~ [ ]
};

fail {
	execute_multiple('insert into u values (?)', 1, 2, 2, { auto_transaction => 0 })
};

test {
	query_one_column('select a from u') ~~ [1, 2]
};



