package SQL::Exec::ODBC;
use strict;
use warnings;
use Exporter 'import';
use DBI;
use SQL::Exec '/.*/', '!connect';

our @ISA = ('SQL::Exec');

our @EXPORT_OK = ('connect', 'test', 'list_available_DB', @SQL::Exec::EXPORT_OK);

sub test_driver {
	return SQL::Exec::test_driver('ODBC');
}

sub list_available_DB {
	my $c = &SQL::Exec::check_options;
	if (!$c->test()) {
		$c->error("You must install the DBD::ODBC Perl module");
		return;
	}
	return map {m/dbi:ODBC:(.*)/; $1} DBI->data_sources('ODBC');
}

# dsn est le DSN au sens ODBC.
# par exemple 'DSN=dcn' (nom enregistré)
# sinon:  'DBCNAME=hostname' ou 'Host=1.2.3.4;Port=1000;'
sub build_connect_args {
	my ($c, $driver, $dsn, $user, $pwd, @opt) = @_;

	if ($dsn ~~ $c->list_available_DB()) {
		return ("dbi:ODBC:DSN=$dsn", $user, $password, @opt);
	} else {
		return ("dbi:ODBC:DRIVER=${driver};${dsn}", $user, $pwd, @opt);	
	}
}

# Inutile, mais ça permet de ne pas l'oublier
sub get_default_connect_option = {
	my $c = shift;
	return $c->SUPER::get_default_connect_option();
}

sub connect {
	my $c = &check_options;

	if (not $c->isa(__PACKAGE__)) {
		bless $c, __PACKAGE__;
	}

	return $c->__connect($c->build_connect_args(@_));
}


1;

