package SQL::Exec::Oracle;
use strict;
use warnings;
use Exporter 'import';
use SQL::Exec '/.*/', '!connect';

our @ISA = ('SQL::Exec');

our @EXPORT_OK = ('connect', 'test', @SQL::Exec::EXPORT_OK);

sub test_driver {
	return SQL::Exec::test_driver('Oracle');
}

sub build_connect_args {
	my ($class, $server, $instance, $user, $pwd, @opt) = @_;
	
	my $port = 1521;
	if ($server =~ m/^(.*):(.*)$/) {
		$server = $1;
		$port = $2;
	}

	return ("dbi:Oracle:host=${server};sid=${instance};port=${port}", $user, $pwd, @opt);
}


sub get_default_connect_option {
	my $c = shift;
	return $c->SUPER::get_default_connect_option();
}

sub connect {
	my $c = &SQL::Exec::check_options;

	if (not $c->isa(__PACKAGE__)) {
		bless $c, __PACKAGE__;
	}

	return $c->__connect($c->build_connect_args(@_));
}

sub table_exists {
	my $c = &check_options;
	my ($table) = @_;

	$table = $c->__replace($table);

	return $c->__count_lines("select * from user_tables where table_name = '$table'") == 1;
}

=for comment

select 'drop function ' || object_name from user_procedures where object_type = 'FUNCTION'
union all
select 'drop procedure ' || object_name from user_procedures where object_type = 'PROCEDURE'
union all
select 'drop sequence ' || sequence_name from user_sequences
union all
select 'drop view ' || view_name from user_views
union all
select 'drop table ' || table_name || ' cascade constraints' from user_tables
union all
select 'drop package ' || object_name from user_procedures where object_type = 'PACKAGE'

=cut

1;


=encoding utf-8

=head1 NAME

SQL::Exec::Oracel - Specific support for the DBD::SQLite DBI driver in SQL::Exec

=head1 SYNOPSIS

  use SQL::Exec::SQLite;
  
  SQL::Exec::SQLite::connect('/tmp/my.db');

=head1 DESCRIPTION

The C<SQL::Exec::SQLite> package is an extension of the L<C<SQL::Exec>|SQL::Exec>
package. This mean that in an OO context C<SQL::Exec::SQLite> is a sub-classe
of C<SQL::Exec> (so all method of the later can be )and an extension

=head1 CONSTRUCTOR

The C<new> constructor of the 

=head1 FUNCTIONS

This is a list of the public function of this library. Functions not listed here
are for internal use only by this module and should not be used in any external
code unless .

All the functions described below are automatically exported into your package
except if you explicitely request to opposite with C<use Test::Subs ();>.

Finally, these function must all be called from the top-level and not inside of
the code of another test function. That is because the library must know the
number of test before their execution.

=head2 connect

  test { CODE };
  test { CODE } DESCR;

This function register a code-block containing a test. During the execution of
the test, the code will be run and the test will be deemed successful if the
returned value is C<true>.

The optionnal C<DESCR> is a string (or an expression returning a string) which
will be added as a comment to the result of this test. If this string contains
a C<printf> I<conversion> (e.g. C<%s> or C<%d>) it will be replaced by the result
of the code block. If the description is omitted, it will be replaced by the
filename and line number of the test. You can use an empty string C<''> to
deactivate completely the output of a comment to the test.

=head2 test

  todo { CODE };
  todo { CODE } DESCR;

This function is the same as the function C<test>, except that the test will be
registered as I<to-do>. So a failure of this test will be ignored when your test
is run inside a test plan by C<Test::Harness> or C<Tap::Harness>.

=head1 BUGS

Please report any bugs or feature requests to C<bug-dbix-puresql@rt.cpan.org>, or
through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=DBIx-PureSQL>.

=head1 SEE ALSO

L<SQL::Exec>

=head1 AUTHOR

Mathias Kende (mathias@cpan.org)

=head1 VERSION

Version 0.01 (January 2013)


=head1 COPYRIGHT & LICENSE

Copyright 2013 © Mathias Kende.  All rights reserved.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut


