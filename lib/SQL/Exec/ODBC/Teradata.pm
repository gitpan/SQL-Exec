package DBIx::PureSQL::ODBC::Teradata;
use strict;
use warnings;
use Exporter 'import';
use DBI;
use DBIx::PureSQL::ODBC '/.*/', '!connect';

our @ISA = ('DBIx::PureSQL::ODBC');

our @EXPORT_OK = ('connect', @DBIx::PureSQL::ODBC::EXPORT_OK);


# dsn est le DSN au sens ODBC.
# par exemple 'DSN=dcn' (nom enregistré)
# sinon:  'DBCNAME=hostname' ou 'Host=1.2.3.4;Port=1000;'
sub build_connect_args {
	my ($c, $server, $user, $pwd, @opt) = @_;

	if ($server ~~ $c->list_available_DB()) {
		return ("dbi:ODBC:DSN=${server}", $user, $password, @opt);
	} else {
		return ("dbi:ODBC:DRIVER=Teradata;DBCNAME=${server}", $user, $pwd, @opt);	
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

sub table_exists {
	my $c = &check_options;
	$c->check_conn() or return;
	my ($base, $table) = @_;

	$base = $c->__replace($base);
	if (not defined $table) {
		if ($base =~ m/^(.*)\.([^.]*)$/) {
			$base = $1;
			$table = $2;
		} else {
			$c->error('You must supply a base and a table name');
		}
	} else {
		$table = $c->__replace($table);
	}

	return $c->__count_lines("select * from DBC.Tables where DatabaseName = '$base' and TableName = '$table'") == 1;
}


1;

