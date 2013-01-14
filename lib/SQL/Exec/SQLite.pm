package SQL::Exec::SQLite;
use strict;
use warnings;
use Exporter 'import';
use SQL::Exec '/.*/', '!connect', '!test_driver';

our @ISA = ('SQL::Exec');

our @EXPORT_OK = ('connect', 'test_driver', @SQL::Exec::EXPORT_OK);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

sub test_driver {
	return SQL::Exec::test_driver('SQLite');
}

sub build_connect_args {
	my ($class, $file, @opt) = @_;

	return ("dbi:SQLite:dbname=$file", undef, undef, @opt);
}

sub get_default_connect_option {
	my $c = shift;
	return (
		$c->SUPER::get_default_connect_option(),
		sqlite_see_if_its_a_number => 1,
		sqlite_use_immediate_transaction => 1,
		Callbacks => { connected => sub { $_[0]->do("PRAGMA foreign_keys = ON"); return } },
	);
}

sub connect {
	my $c = &SQL::Exec::check_options;

	if (not $c->isa(__PACKAGE__)) {
		bless $c, __PACKAGE__;
	}

	return $c->__connect($c->build_connect_args(@_));
}

1;


=encoding utf-8

=head1 NAME

SQL::Exec::SQLite - Specific support for the DBD::SQLite DBI driver in SQL::Exec

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


