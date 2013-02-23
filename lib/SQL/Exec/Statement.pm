package SQL::Exec::Statement;
use strict;
use warnings;
use feature 'switch';
use Carp;
use Scalar::Util 'blessed', 'reftype', 'openhandle';
use List::MoreUtils 'any';
use SQL::SplitStatement;

use parent 'SQL::Exec';

# Note: This file contains both a POD documentation which describes the public
# API of this package and a technical documentation (on the internal methods and
# how to subclasse this package) in standard Perl comments.

=encoding utf-8

=head1 NAME

SQL::Exec::Statement - Prepared statements support for SQL::Exec

=cut

our @CARP_NOT = ('DBIx::Connector');

			
# This variable stores the default instance of this class. It is set up in a
# BEGIN block.
my $default_handle;

# Return a reference of a new copy of the empty_handle hash, used by the
# constructors of the class.
sub get_empty {
	my $new_empty = SQL::Exec->get_empty();
	delete $new_empty->{auto_handle};
	return $new_empty;
}

# ->new($parent, {options})
# appeler seulement depuis Exec::prepare
sub new {
	my ($class) = shift @_;
	my $parent = &SQL::Exec::check_options;

	my $c = get_empty();
	$c->{parent} = $parent;
	bless $c, $class;
	$c->set_options(%{$parent->{options}});
	$c->{db_con} = $parent->{db_con};
	$c->{is_connected} = $parent->{is_connected};
	# on ne copie pas les restore options exprès, ce qui est en vigueur quand
	# on crée l'objet le reste.
	# TODO: faire un cas de test pour ça.

	$c->check_conn() or return;
	
	my $req = $c->get_one_query(shift @_);

	my $proc = sub {

			if (!$c->low_level_prepare($req)) {
				die "EINT\n";
			}

		};

	if ($c->{options}{auto_transaction}) {
		eval { $c->{db_con}->txn($proc) };
	} else {
		eval { $proc->() };
	}
	if ($@ =~ m/^EINT$/) {
		return;
	} elsif ($@) {
		die $@;
	} else {
		return $c;
	}
}

sub execute {
	my $c = &SQL::Exec::check_options or return;

	$c->check_conn() or return;

	my ($param, $d1);
	if (not @_ or not ref $_[0]) {
		$param = [ \@_ ];
		$d1 = 1;
	} elsif (reftype($_[0]) eq 'ARRAY' and (not @{$_[0]} or not ref $_[0][0])) {
		$param = [ @_ ];
	} elsif (reftype($_[0]) eq 'ARRAY' and reftype($_[0][0]) eq 'ARRAY') {
		$param = $_[0];
	} else {
		$c->error('Invalid argument geometry');
	}

	my $proc = sub {
			my $a = 0;
			
			if ($c->{last_req}->{NUM_OF_PARAMS} == 1 and $d1) {
				$param = [ map { [ $_ ] } @{$param->[0]} ];
			}

			for my $p (@{$param}) {
			# TODO: lever l'erreur strict seulement dans le mode stop_on_error
			# et s'il reste des requête à exécuter.
				if (not $c->low_level_bind(@{$p})) {
					$c->low_level_finish();
					$c->strict_error("The query has not been executed for all value due to an error") and die "EINT\n";
					die "ESTOP:$a\n" if $c->{options}{stop_on_error};
					next;
				}
				my $v = $c->low_level_execute();
				$c->low_level_finish();
				if (not defined $v) {
					$c->strict_error("The query has not been executed for all value due to an error") and die "EINT\n";
					die "ESTOP:$a\n" if $c->{options}{stop_on_error};
					next;
				}
				$a += $v;
			}
			return $a;
		};

	my $v;
	if ($c->{options}{auto_transaction}) {
		$v = eval { $c->{db_con}->txn($proc) };
	} else {
		$v = eval { $proc->() };
	}
	$c->low_level_finish() unless $c->{req_over}; # ???
	if ($@ =~ m/^EINT$/) {
		return;
	} elsif ($@ =~ m/^ESTOP:(\d+)$/) {
		return $c->{options}{auto_transaction} ? 0 : $1;
	} elsif ($@) {
		die $@;
	} else {
		return $v;
	}
}

sub __query_one_value {
	my ($c) = @_;

	$c->check_conn() or return;

	if (not defined $c->low_level_execute())
	{ 
		$c->low_level_finish();
		return;
	}

	my $row = $c->low_level_fetchrow_arrayref();

	my $tmr = $c->test_next_row() if defined $c->{options}{strict};
	$c->low_level_finish();

	if (!$row) {
		return $c->error("Not enough data");
	} elsif ($#$row < 0) {
		return $c->error("Not enough column");
	}

	if (defined  $c->{options}{strict}) {
		$c->strict_error("To much columns") and return if $#$row > 0;
		$c->strict_error("To much rows") and return if $tmr;
	}
	
	return $row->[0];
}

sub query_one_value {
	my $c = &SQL::Exec::check_options or return;
	return $c->__query_one_value(@_);
}

# array ou array-ref selon le contexte (sûr, pas écraser au prochain appel).
sub query_one_line {
	my $c = &SQL::Exec::check_options or return;

	$c->check_conn() or return;

	if (not defined $c->low_level_execute()) {
		$c->low_level_finish();
		return;
	}
	my $row = $c->low_level_fetchrow_arrayref();
	if (!$row) {
		$c->low_level_finish();
		return $c->error("Not enough data");
	}

	my $tmr = $c->test_next_row() if defined $c->{options}{strict};

	$c->low_level_finish();

	$c->strict_error("To much rows") and return if $tmr;

	return wantarray ? @{$row} : [ @{$row} ];
}


# ! Si une erreur ignorée se produit dans fetchraw alors on renvoie un tableau tronqué
# Et non pas undef ou autre, donc il n'y a pas de moyen de savoir que l'appel a échoué.
# En mode stricte cependant, cette situation lève une erreur elle même (et donc on a un message
# propre si on ignore cette erreur).
# return un tableau ou un array-ref (pour économiser une recopie).
# renvoie toujours un tableau 2D même s'il n'y a qu'une colonne (pour assurer la cohérence du type),
# il faut utiliser query_one_column pour avoir une colonne.
sub query_all_lines {
	my $c = &SQL::Exec::check_options or return;

	$c->check_conn() or return;

	if (not defined $c->low_level_execute()) {
		$c->low_level_finish();
		return;
	}
	
	my @rows;	
	while (my $row = $c->low_level_fetchrow_arrayref()) {
		push @rows, [ @{$row} ]; # Pour recopier la ligne sans quoi elle est écrasée au prochain appel.
	}

	$c->low_level_finish();

	if (defined $c->{options}{strict} && $c->{last_req}->err) {
		$c->strict_error("The data have been truncated due to an error") and return;
	}

	return wantarray() ? @rows : \@rows;
}

sub query_one_column {
	my $c = &SQL::Exec::check_options or return;

	$c->check_conn() or return;

	if ($c->{last_req}->{NUM_OF_FIELDS} < 1) {
		$c->low_level_finish();
		return $c->error("Not enough column");
	}

	if (defined $c->{options}{strict} && $c->{last_req}->{NUM_OF_FIELDS} > 1) {
		if ($c->strict_error("To much columns")) {
			$c->low_level_finish();
			return;
		}
	}

	if (not defined $c->low_level_execute()) {
		$c->low_level_finish();
		return;
	}
	
	my @data;

	while (my $row = $c->low_level_fetchrow_arrayref()) {
		push @data, $row->[0];
	}

	$c->low_level_finish();

	if (defined $c->{options}{strict} && $c->{last_req}->err) {
		$c->strict_error("The data have been truncated due to an error") and return;
	}
	
	return wantarray() ? @data : \@data;
}


sub query_to_file {
	my $c = &SQL::Exec::check_options or return;
	my ($fh, $sep, $nl) = @_;

	my ($fout, $to_close);
	if (not defined $fh) {
		$fout = \*STDOUT;
	} elsif (openhandle($fh)) {
		$fout = $fh;
	} elsif (!ref($fh)) {
		$fh =~ m{^\s*(>{1,2})?\s*(.*)$};
		if (!open $fout, ($1 // '>'), $2) { # //
			return $c->error("Cannot open file '$fh': $!");
		}
		$to_close = 1;
	} else {
		return $c->error("Don't know what to do with fh argument '$fh'");
	}
	
	$c->check_conn() or return;

	if (not defined $c->low_level_execute()) {
		$c->low_level_finish();
		return;
	}

	my $count = 0;
	{
		local $, = $sep // ';';
		local $\ = $nl // "\n";
		while (my $row = $c->low_level_fetchrow_arrayref()) {
			if (not (print $fout @{$row})) {
				close $fout if $to_close;
				$c->low_level_finish();
				$c->error("Cannot write to file: $!");
				return $count;
			}
			$count++;
		}
		close $fout if $to_close;
	}

	$c->low_level_finish();

	if (defined $c->{options}{strict} && $c->{last_req}->err) {
		$c->strict_error("The data have been truncated due to an error") and return;
	}
	
	return $count;
}





1;



