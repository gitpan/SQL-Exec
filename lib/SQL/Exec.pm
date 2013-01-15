package SQL::Exec;
our $VERSION = 0.02;
use strict;
use warnings;
use feature 'switch';
use Carp;
use Exporter 'import';
use Scalar::Util 'blessed', 'reftype', 'openhandle';
use List::MoreUtils 'any';
use DBI;
use DBIx::Connector;
use SQL::SplitStatement;

# Note: This file contains both a POD documentation which describes the public
# API of this package and a technical documentation (on the internal methods and
# how to subclasse this package) in standard Perl comments.

=encoding utf-8

=head1 NAME

SQL::Exec - Simple thread and fork safe database access with functionnal and OO interface

=head1 SYNOPSIS

  use SQL::Exec ':all';
  
  connect('dbi:SQLite:dbname=db_file');
  
  execute(SQL);
  
  my $val = query_one_value(SQL);
  
  my @line = query_one_line(SQL);
  
  my @table = query_all_line(SQL);

=head2 Main functionnalities

SQL::Exec is (another) interface to the DBI which strive for simplicity. Its main
functionalities are:

=over 4

=item * DBMS independent. The module offers specific support for some DB server
but can work with any DBD driver;

=item * Extremely simple, a query is always only one function or method call;

=item * Everything is as (in)efficient: you choose the function to call based
only on the data that you want to get back, not on some supposed performance
benefit;

=item * Supports both OO and functional paradigm with the same interface and
functionalities;

=item * Hides away all DBIism, you do not need to set any options, they are
handled by the library with nice defaults;

=item * Safe: SQL::Exec verify that what happens is what you meant;

=item * Not an ORM, nor a query generator: you are controling your SQL;

=item * Easy to extends to offer functionalities specific to one DB server;

=item * Handles transparently network failure, fork, thread, etc;

=item * Safely handle multi statement query and automatic transaction.

=back

All this means that SQL::Exec is extremely beginners friendly, it can be used
with no advanced knowledge of Perl and code using it can be easily read by people
with no knowledge of Perl at all, which is interesting in a mixed environment.

Also, the fact that SQL::Exec does not try to write SQL for the programmer (this
is a feature, not a bug), ease the migration to other tools or languages if a big
part of the application logic is written in SQL.

Thus SQL::Exec is optimal for fast prototyping, for small applications which do
not need a full fledged ORM, for migrating SQL code from/to an other environment,
etc. It is usable (thanks to C<DBIx::Connector>) in a CGI scripts, in a mod_perl
program or in any web framework as the database access layer.

=head1 DESCRIPTION

=cut

#dire un peu ce qu'est DBI et ce que sont les DBD.

=head2 Support of specific DB

The C<SQL::Exec> library is mostly database agnostic. However there is some
support (limited at the moment) for specific database which will extends the
functionnalities of the library for those database.

If there is a sub-classe of C<SQL::Exec> for your prefered RDBMS you should
use it (for both the OO and the functionnal interface of the library) rather than
using directly C<SQL::Exec>. These sub-classes will provide tuned functions
and method for your RDBMS, additionnal functionnalities, will set specific
database parameters correctly and will assist you to connect to your desired
database.

You will find in L</"Sub-classes"> a list of the supported RDBMS and a link to
the documentation of their specific modules.  If your prefered database is not
listed there, you can still use C<SQL::Exec> directly and get most of its benefits.

Do not hesitate to ask for (or propose) a module for your database of choice.

=head2 Exported symbols

Each function of this library (that is everything described below except C<new>
and C<new_no_connect> which are only package method) may be exported on request.

There is also a C<':all'> tag to get everything at once.

=cut



################################################################################
################################################################################
##                                                                            ##
##                            HELPER FUNCTIONS                                ##
##                                                                            ##
################################################################################
################################################################################
# The functions in this section are for internal use only by this package
# or by subclasses. The functions here are NOT method.



# functions are 'push-ed' below in this array.
our @EXPORT_OK = ();
# every thing is put in ':all' at the end of the file.
our %EXPORT_TAGS = ();

# The structure of a SQL::Exec object, this hash is never made an object but
# it is copied by get_empty whenever a new object must be created.
# N.B.: The get_empty function must be adapted if new references are added
# inside this object (like e.g. options and restore_options), to ensure that
# they are properly copied.
my %empty_handle;
BEGIN {
	%empty_handle = (
			options => {
					die_on_error => 1, # utilise croak
					print_error => 1, # utilise carp pour les erreurs
					print_warning => 1, # utilise toujours carp
					print_query => undef, # spécifie un channel à utiliser
					strict => 1,
					replace => undef,
					connect_options => undef,
					auto_transaction => 1,
					auto_split => 1,
					use_connector => 1,
					stop_on_error => 1,
				},

			restore_options => {},

			db_con => undef,
			is_connected => 0,
			last_req_str => "",
			last_req => undef,
			req_over => 1,
			#last_msg => undef,
		);
}

# This variable stores the default instance of this class. It is set up in a
# BEGIN block.
my $default_handle;

# Return a reference of a new copy of the empty_handle hash, used by the
# constructors of the class.
sub get_empty {
	my %new_empty = %empty_handle;
	$new_empty{options} = { %{$empty_handle{options}} };
	$new_empty{restore_options} = { %{$empty_handle{restore_options}} };
	return \%new_empty;
}

# One of the three function below (just_get_handle, get_handle and
# check_options) must be called at each entry-point of the library with the
# syntax: '&function;' which allow the current @_ array to be passed to the
# function without being copied.
# Their purpose is to check if the method was invoqued as a method or as a
# function in which case the default class instance is used.
#
# This function is called by the very few entry point of the library which are
# not supposed to clear the errstr field of the instance.
sub just_get_handle {
	return (scalar(@_) && blessed $_[0] && $_[0]->isa(__PACKAGE__)) ? shift @_ : $default_handle;
}

# See above for the purpose and usage of this function.
#
# This function is called by the entry points which must not restore the saved
# options or which are not expected to receive any function.
sub get_handle {
	my $c = &just_get_handle;
	delete $c->{errstr};
	delete $c->{warnstr};
	return $c;
}

# See above for the purpose and usage of this function.
#
# This function is called by most of the entry points of the library which are
# generally expected to work both as package function and as instance method.
# Also, this function check if the last argument it receives is a hash-ref and,
# if so, assume that it is option to be applied for the duration of the current
# call.
sub check_options {
	my $c = &get_handle;

	my $h = {};
	if (@_ && ref($_[-1]) && ref($_[-1]) eq 'HASH') {
		$h = pop @_;
	}
	
	my $ro = $c->set_options($h);
	
	if ($ro) {
		$c->{restore_options} = $ro;
	} else {
		$c->strict_error('The options were not correctly applied due to errors') and return;
	}

	return $c;
}

# Just a small helper function for the sub-classes to check if a given DBD
# driver is installed.
sub test_driver {
	my ($driver) = @_;

	return any { $_ eq $driver } DBI->available_drivers();
}

# function used to sanitize the input to the option set/get methods.
sub __boolean {
	if (defined $_[0]) {
		return $_[0] ? 1 : 0;
	} else {
		return undef;
	}
}

sub __set_boolean_opt {
	my ($c, $o, @v) = @_;

	$c->__restore_options();
	my $r = $c->{options}{$o};
	$c->{options}{$o} = __boolean($v[0]) if @v;
	return $r;
}

################################################################################
################################################################################
##                                                                            ##
##                         CONSTRUCTORS/DESTRUCTORS                           ##
##                                                                            ##
################################################################################
################################################################################



=head1 CONSTRUCTORS/DESTRUCTORS

If you want to use this library in an object oriented way (or if you want to use
multiple database connection at once) you will need to create C<SQL::Exec>
object using the constructors described here. If you want to use this library in
a purely functionnal way then you will want to take a look at the L</"connect">
function described below which will allow you to connect the library without using
a single object.

=head2 new

  my $h = SQL::Exec->new($dsn, $user, $password, %opts);

Create a new C<SQL::Exec> object and connect-it to the database defined by
the C<$dsn> argument, with the supplied C<$user> and C<$password> if necessary.

The syntax of the C<$dsn> argument is described in the manual of your C<DBD>
driver. However, you will probably want to use one of the existing sub-classes of
this module to assist you in connecting to some specific database.

The C<%opts> argument is optionnal and may be given as a hash or as a hash
reference. If the argument is given it set accordingly the option of the object
being created. See the L</"set_options"> method for a description of the available
options.

If your DB has a specific support in a L<sub-classe|/"Sub-classes"> you must
use its specific constructor to get the additionnal benefits it will offer.

=head2 new_no_connect

  my $h = SQL::Exec->new_no_connect(%opts);

This constructor creates a C<SQL::Exec> object without connecting it to any
database. You will need to call the L</"connect"> option on the handle to connect
it to a database.

The C<%opts> argument is optionnal and is the same as for the C<new> constructor.

=head2 destructor

Whenever you have finished working with a database connection you may close it
(see the L</"disconnect"> function) or you may just let go of the database handle.
There is a C<DESTROY> method in this package which will take care of closing the
database connection correctly whenever your handle is garbage collected.

=cut

# Les options que l'on donne à new, sont valable pour l'objet, pas juste
# pour l'appel de fonctions/méthode, comme les autres fonctions.
# Les options sont a fixer à chaque création d'objet (indépendamment de l'objet
# par défaut).
# A constructor which will not connect 
sub new_no_connect {
	my ($class, @opt) = @_;

	my $c = get_empty();
	bless $c, $class;
	$c->set_options(@opt);
	return $c;
}

# dans le cas ou la connection échoue, l'objet est quand même créée et renvoyé
# si jamais on ignore les erreurs.
sub new {
	my ($class, @args) = @_;
	
	my ($con_str, $user, $pwd, @opt) = $class->build_connect_args(@args);
	my $c = new_no_connect($class, @opt);
	$c->__connect($con_str, $user, $pwd);
	return $c;
}

# This bless the default handle. The handle is blessed again if it is
# connected in a sub classe.
UNITCHECK {
	$default_handle = __PACKAGE__->new_no_connect();
}


sub DESTROY {
	my $c = shift;
	$c->__disconnect() if $c->{is_connected};
}



################################################################################
################################################################################
##                                                                            ##
##                            INTERNAL METHODS                                ##
##                                                                            ##
################################################################################
################################################################################
# The methods in this section are for internal use only by this package
# or by subclasses. The functions here ARE methods and must be called explicitely
# on an instance of this class (or of one of its sub-classes).


# The purpose of this function is to be overidden in sub-classes which would
# take a different set of argument for their constructors without having to
# redefine the constructor itself.
sub build_connect_args {
	my ($class, $con_str, $user, $pwd, @opt) = @_;

	return ($con_str, $user, $pwd, @opt);
}

# This method must be called when an error condition happen. It croaks, carps or
# does nothing depending on the current option. It also set the errstr variable.
sub error {
	my ($c, $msg, @args) = @_;

	$c->{errstr} = sprintf $msg, @args;

	if ($c->{options}{die_on_error}) {
		croak $c->{errstr};
	} elsif ($c->{options}{print_error}) {
		carp $c->{errstr};
	}

	return;
}

# Same thing but for warning which may only be printed.
sub warning {
	my ($c, $msg, @args) = @_;

	$c->{warnstr} = sprintf $msg, @args;

	if ($c->{options}{print_warning}) {
		carp $c->{warnstr};
	}

	return;
}

# Same thing but for violation of strictness, test if the currant instance is in
# strict mode and, if so, convert strictness violations into errors.
#
# if the condition which trigger a strict_error is  costly then it must be tested
# only when strict_error is defined (true or false). Otherwise, the strict_error
# method may be called without testing the strict_error option.
# You must not return when a strict error is detected, as the processing is able to
# continue after it. You must check for the return value of the function and return
# if it is true C<$c->strict_error(...) and return;
sub strict_error {
	my ($c, $msg, @args) = @_;

	if (defined $c->{options}{strict}) {
		if ($c->{options}{strict}) {
			$c->error($msg, @args);
			return 1;
		} else {
			$c->warning($msg, @args);
			return;
		}
	} else {
		return;
	}
}

sub format_dbi_error {
	my ($c, $msg, @args) = @_;
	
	my $dbh = $c->{db_con}->dbh();
	my $errstr = $dbh->errstr // '';
	my $err = $dbh->err // '0';
	my $state = $dbh->state // '0'; # // pour la coloration syntaxique de Gedit
	my $err_msg = "Error during the execution of the following request:\n\t".$c->{last_req_str}."\n";
	$err_msg .= "Error: $msg\n\t Error Code: $err\n\t Error Message: $errstr\n\t State: $state";

	return $err_msg;
}
# This function is called in case of error in a call to the DBI in order to
# format an error message
sub dbi_error {
	my ($c, $msg, @args) = @_;

	$c->error($c->format_dbi_error($msg,@args));

	return;
}

sub __replace {
	my ($c, $str) = @_;

	my $r = $c->{options}{replace};
	if ($r && reftype($r) eq 'CODE') {
		$str = eval { $r->($str) };
		return $c->error("A call to the replace procedure has failed with: $@") if $@;
	} elsif ($r and blessed($_[0]) and $_[0]->can('replace')) {
		$str = eval { $r->replace($str) };
		return $c->error("A call to the replace method of the object given procedure has failed with: $@") if $@;
	} elsif ($r) {
		confess "should not happen";
	}

	return $str;
}

# This function is called each time an SQL statement is sent to the database
# it possibly apply the replace procedure of a String::Replace object on the
# SQL query string and save the query.
sub query {
	my ($c, $query) = @_;

	$query = $c->__replace($query) or return;

	if (defined $c->{options}{print_query}) {
		chomp (my $r = $query);
		print { $c->{options}{print_query} } $r."\n";
	}
	
	$c->{last_req_str} = $query;

	return $query;
}


# This function must be called by the library entry-points (user called
# functions) if they need a connection to the database.
sub check_conn {
	my ($c) = @_;

	if (!$c->{is_connected}) {
		$c->error("The library is not connected");
		return;
	}
	return 1;
}


# This internal version of the disconnect function may be called from the
# connect function.
sub __disconnect {
	my ($c) = @_;
	if ($c->{is_connected}) {
		$c->{last_req}->finish() if defined $c->{last_req} && !$c->{req_over};
		$c->query("logout");
		$c->{db_con}->disconnect if defined $c->{db_con};
		$c->{is_connected} = 0;
		return 1;
	} else {
		$c->strict_error("The library is not connected");
		return;
	}
}

# This function is also expected to be extended in sub-classes and is used by
# the default constructors.
sub get_default_connect_option {
	return (
		PrintError => 0, # les erreurs sont récupéré par le code qui les affiches
		RaiseError => 0, # lui même.
		Warn => 1,      # des warning généré par DBI
		PrintWarn => 1, # les warning renvoyé par le drivers lui même
		AutoCommit => 1,
		AutoInactiveDestroy => 1, # pour DBIx::Connector
		ChopBlanks => 0,
		LongReadLen => 4096, # TODO: Il faut une fonction pour le modifier, Cf la doc de ce paramètre
		#TODO: il faudrait aussi ajouter du support pour les options Taint...
		FetchHashKeyName => 'NAME_lc'
	);
}

# Internal connect method, called by the constructors and by the connect function
# and by the sub-classses.
sub __connect {
	my ($c, $con_str, $user, $pwd) = @_;
	
	if ($c->{is_connected}) {
		$c->strict_error("The object is already connected") and return;
		$c->__disconnect();
	}
	
	{
		my $usr = $user // ''; # //
		$c->query("login to ${con_str} with user ${usr}");
	}
	
	my $con_opt = $c->{options}{connect_options} // { $c->get_default_connect_option() }; # //
	
	if ($c->{options}{use_connector}) {
		$c->{db_con} = DBIx::Connector->new($con_str, $user, $pwd, $con_opt);
		$c->{db_con}->disconnect_on_destroy(1);
		$c->{db_con}->mode('fixup');
	} else {
		$c->{db_con} = DBI->connect($con_str, $user, $pwd, $con_opt);
	}

	if (!$c->{db_con}) {
		$c->error("Cannot connect to the database");
		return;
	}	

	
	$c->{is_connected} = 1;
	return 1;
}

sub __restore_options {
	my ($c) = @_;

	foreach my $k (keys %{$c->{restore_options}}) {
		$c->{options}{$k} = $c->{restore_options}{$k};
	}

	$c->{restore_options} = {};

	return;
}


# The function below are responsible for the effective works of the library.
# Pretty much self-descriptive.

# Prepare a statement, return false on error (if die_on_error is false)
# only one statement may be prepared at a time in a database handle.
sub low_level_prepare {
	my ($c, $req_str) = @_;
	
	$req_str = $c->query($req_str) or return $c->error('No query to prepare');

	my $s = sub { 
			my $req = $_->prepare($req_str);
			if (!$req) {
				die $c->format_dbi_error("Cannot prepare the statement");
			} else {
				return $req;
			}
		};
	my $req = eval { $c->{db_con}->run($s) };
	if ($@) {
		return $c->error($@);
	}
	$c->{last_req} = $req;
	$c->{req_over} = 0;
	return 1;
}

# execute the prepared statement of the handle. Return undef on failure (0 may
# be returned on success).
sub low_level_execute {
	my ($c) = @_;
	confess "No statement currently prepared" if $c->{req_over};

	my $v = $c->{last_req}->execute();
	if (!$v) {
		$c->dbi_error("Cannot execute the statement");
		return;
	}
	
	return $v;
}


# Return one raw of result. The same array ref is returned for each call so
# its content must be copied somewhere before the next call.
sub low_level_fetchrow_arrayref {
	my ($c) = @_;
	confess "No statement currently prepared" if $c->{req_over};

	my $row = $c->{last_req}->fetchrow_arrayref();
	if (!$row && $c->{last_req}->err) {
		$c->dbi_error("A row cannot be fetched");
		return;
	} elsif (!$row) {
		return 0;
	} else {
		return $row;
	}
}

sub low_level_finish {
	my ($c) = @_;
	confess "No statement currently prepared" if $c->{req_over};

	$c->{last_req}->finish;
	$c->{req_over} = 1;

	return $1;
}

# Test whether there is one raw available in the prepared statement.
# this function destroy the raw so it should not be called if you actually
# want to read to raw.
sub test_next_row {
	my ($c) = @_;
	confess "No statement currently prepared" if $c->{req_over};
	
	return $c->{last_req}->fetchrow_arrayref() || $c->{last_req}->err
}

my %splitstatement_opt = (
		keep_terminator => 0,
		keep_extra_spaces => 0,
		keep_comments => 1,
		keep_empty_statements => 0,
	);
my %splitstatement_opt_grep = (
		keep_comments => 0,
		keep_empty_statements => 0,
	); 

my $sql_splitter = SQL::SplitStatement->new(%splitstatement_opt);
my $sql_split_grepper = SQL::SplitStatement->new(%splitstatement_opt_grep);

# split a string containing multiple query separated by ';' characters.
sub split_query {
	my ($c, $str) = @_;
	return $str if not $c->{options}{auto_split};
	return grep { $sql_split_grepper->split($_) } $sql_splitter->split($str);
}

sub get_one_query {
	my ($c, $str) = @_;

	my @l = $c->split_query($str);

	if (@l > 1) {
		return $c->error("The supplied query contains more than one statement");
	} elsif (@l == 0) {
		return $c->error("The supplied query does not contain any statements");
	} else {
		return $l[0]; # is always true
	}
}

################################################################################
#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!#
#!                                                                            !#
#!                                WARNINGS                                    !#
#!                                                                            !#
#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!#
################################################################################

# All the functions below this points may be called by the users either in OO
# or in functionnal mode. So they must all fetch the correct handle to work with.
#
# This function may also all accept temporary option which will apply only for
# the duration of the function call. As these arguments are deactivated when the
# same handle is used next, none of this functions may be called by another
# function of the library (or else, the option handling would be wrong). Only
# function above this point may be called by other functions of this package.

################################################################################
################################################################################
##                                                                            ##
##                          GETTER/SETTER AND OPTIONS                         ##
##                                                                            ##
################################################################################
################################################################################

=head1 GETTER/SETTER AND OPTIONS

The functions and method described below are related to knowing and manipulating
the state of a database connection and of its options. The main function to set
the options of a database connection is the L<C<set_options>|/"set_options">
functions. However, you can pass a hash reference as the I<last> argument to any
function of this library with the same syntax as for the C<set_options> function
and the options that it describes will be in effect for the duration of the
function or method call.

Any invalid option given in this way to a function/method will result in a
C<'no such option'> error. If you do not die on error but are in strict mode, then
the called function will not be executed.

=head2 connect

  connect($dsn, $user, $password, %opts);
  $h->connect($dsn, $user, $password, %opts);

This function/method permits to connect a handle which is not currently connected
to a database (either because it was created with C<new_no_connect> or because
C<disconnect> has been called on it). It also enable to connect to library to
a database in a purely functionnal way (without using objects). In that case
you can maintain only a single connection to a database. This is the connection
that will be used by all the function of this library when not called as an
object method. This connection will be refered to as the I<default handle> in this
documentation. Its the handle that all other function will use when not applied
to an object.

You can perfectly mix together the two styles (OO and functionnal): that is, have
the library connected in a functionnal style to a database and have multiple
other connections openned through the OO interface (with C<new>).

As stated above, this function accepts an optional hash reference as its last
argument. Note, however, that the option in this hash will be in effect only for
the duration of the C<connect> call, while options passed as the last argument of
the constructors (C<new> and C<new_no_connect>) remain in effect until they are
modified. This is true even if C<connect> is called to create a default connection
for the library. You should use C<set_options> to set options permanently for the
default database handle (or any other handle after its creation).

This function will return a I<true> value if the connection succeed and will die
or return C<undef> otherwise (depending on the C<die_on_error> option). Not that
in strict mode it is an error to try to connect a handle which is already connected
to a database.

=head2 disconnect

  disconnect();

This function disconnect the default handle of the library from its current
connection. You can later on reconnect the library to an other database (or to
the same) with the C<connect> function.

  $h->disconnect();

This function disconnect the handle it is applied on from its database. Note that
the handle itself is not destroyed and can be reused later on with the C<connect>
method.

=head2 is_connected

  my $v = is_connected();
  my $v = $h->is_connected();

This call returns whether the default handle of the library and/or a given handle
is currently connected to a database.

This function does not actually check the connection to the database. So it is
possible that this call returns I<true> but that a later call to a function
which does access the database will fail if, e.g., you have lost your network
connection.

=head2 get_default_handle

  my $h = get_default_handle();

Return the default handle of the library (the one used by all function when not
applied on an object). The returned handle may then be used as any other handle
through the OO interface, but it will still be used by the functionnal interface
of this library.

=head2 errstr

  my $e = errstr();
  my $e = $c->errstr;

This function returns an error string associated with the last call to the library
made with a given handle (or with the default handle). This function will return
C<undef> if the last call did not raise an error.

=head2 warnstr

  my $e = warnstr();
  my $e = $c->warnstr;

This function returns a warning string associated with the last call to the library
made with a given handle (or with the default handle). This function will return
C<undef> if the last call did not raise a warning.

Note that a single call way raise multiple warning. In that case, only the last
one will we stored in this variable.

=head2 set_options

  set_options(HASH);
  $c->set_options(HASH);

This function sets the option of the given connection handle (or of the default
handle). The C<HASH> describing the option may be given as a list of C<<option => value>>
or as a reference to a hash.

The function returns a hash with the previous value of all modified
options. As a special case, if the function is called without argument, it will
returns a hash with the value of all the options. In both cases, this hash is
returned as a list in list context and as a hash reference in scalar context.

If an error happen (e.g. use of an invalid value for an option) the function
returns undef or an empty list and nothing is modified. In C<strict> mode it is
also an error to try to set an nonexistant option.

If the options that you are setting include the C<strict> option, the value of
the C<strict> mode is not defined during the execution of this function (that is,
it may either be I<true> or I<false>).

See below for a list of the available options.

=head2 Options

You will find below a list of the currently available options. Each of these options
may be accessed through its dedicated function or with either of the C<set_option>/C<set_options>
functions.

=head3 die_on_error

  set_options(die_on_error => val);
  die_on_error(val);

=head3 print_error

  set_options(print_error => val);
  print_error(val);

=head3 print_warning

  set_options(print_warning => val);
  print_warning(val);

=head3 print_query

  set_options(print_query => FH);
  print_query(FH);

=head3 strict

  set_options(strict => val);
  strict(val);

=head3 replace

  set_option(replace => \&code);
  strict(\&code);

=head3 connect_options

Do not use this option...

=head3 auto_split

This option control whether the queries are split in atomic statement before being
sent to the database. This option default to I<true>. If it is not set, your
queries will be sent I<as-is> to the database, with their ending terminator (if
any), etc. You should not set this option to some I<false> value unless you know
what you are doing.

The spliting facility is provided by the C<SQL::SplitStatement> package.

=head3 auto_transaction

  set_options(auto_transaction => val);
  auto_transaction(val);

=head3 use_connector

Do not use this option...

=head3 stop_on_error

  set_options(stop_on_error => val);
  stop_on_error(val);

=cut

push @EXPORT_OK, ('connect', 'disconnect', 'is_connected', 'get_default_handle',
	'errstr', 'set_options', 'set_option', 'die_on_error', 'print_error',
	'print_warning', 'print_query', 'strict', 'replace', 'connect_options',
	'auto_transaction', 'auto_split', 'use_connector', 'stop_on_error');

# contrairement à new, connect met des options temporaire. bien ?
sub connect {
	my $c = &check_options or return;
	return $c->__connect(@_);
}

sub disconnect {
	my $c = &check_options or return;
	return $c->__disconnect(@_);
}

sub is_connected {
	my $c = &check_options or return;
	return $c->{is_connected};
}

sub get_default_handle {
	return just_get_handle();
}

# renvoie la dernière erreur et undef si le dernier appel a réussi.
sub errstr {
	my $c = &just_get_handle;
	return $c->{errstr};
}

sub die_on_error {
	my $c = &get_handle;
	return $c->__set_boolean_opt('die_on_error', @_);
}

sub print_error {
	my $c = &get_handle;
	return $c->__set_boolean_opt('print_error', @_);
}

sub print_warning {
	my $c = &get_handle;
	return $c->__set_boolean_opt('print_warning', @_);
}



# undef si l'argument est invalide, 0 sinon (pour les autres fonctions, il n'y a pas d'argument invalide).
sub print_query {
	my $c = &get_handle;

	$c->__restore_options();
	my $r = $c->{options}{print_query};

	if (@_) {
		if (not $_[0]) {
			$c->{options}{print_query} = 0;
		} elsif (openhandle($_[0])) {
			$c->{options}{print_query} = $_[0];
		} else {
			return $c->error('Invalid file handle as argument to print_query');
		}
	}

	return $r;
}

sub strict {
	my $c = &get_handle;
	return $c->__set_boolean_opt('strict', @_);
}

sub replace {
	my $c = &get_handle;

	$c->__restore_options();
	my $r = $c->{options}{replace};

	if (@_) {
		if (not $_[0]) {
			$c->{options}{replace} = undef;
		} elsif ((reftype($_[0]) // '') eq 'CODE') {
			$c->{options}{replace} = $_[0];
		} elsif (blessed($_[0]) and $_[0]->can('replace')) {
			$c->{options}{replace} = $_[0];
		} elsif ((reftype($_[0]) // '') eq 'HASH') {
			if (eval { require String::Replace }) {
				my $v = eval { String::Replace->new($_[0]) };
				return $c->error("Creating a String::Replace object has failed: $@") if $@;
				$c->{options}{replace} = $v;
			} else {
				return $c->error('The String::Replace module is needed to handle HASH ref as argument to replace');
			}
		} else {
			return $c->error('Invalid argument to replace, expexted an object or HASH or CODE ref');
		}
	}

	return $r // 0;	# //
}

# idem que print_query
sub connect_options {
	my $c = &get_handle;

	$c->__restore_options();
	my $r = $c->{options}{connect_options};

	if (@_) {
		if (not $_[0]) {
			$c->{options}{connect_options} = undef;
		} elsif ((reftype($_[0]) // '') eq 'HASH') { # //
			$c->{options}{connect_options} = $_[0];
		} else {
			return $c->error('Invalid argument to connect_options, expexted a HASH ref');
		}
	}

	return $r // 0; #//
}

sub auto_transaction {
	my $c = &get_handle;
	return $c->__set_boolean_opt('auto_transaction', @_);
}

sub auto_split {
	my $c = &get_handle;
	return $c->__set_boolean_opt('auto_split', @_);
}

sub use_connector {
	my $c = &get_handle;
	return $c->error('The use_connector option cannot be changed when connected to a DB') if @_ && $c->{is_connected};
	return $c->__set_boolean_opt('use_connector', @_);
}

sub stop_on_error {
	my $c = get_handle;
	return $c->__set_boolean_opt('stop_on_error', @_);
}

# Il faut que si on recoit \{} en argument alors on renvoie
# un restore option vide (mais pas toutes les options) car
# c'est ce qu'attend check_option.
#
# le hash restore_options est rempli dans check_options, important, sinon
# on le vide dans chaque appel aux petites fonctions d'option.
#
# la gestion en cas d'erreur est un peu complexe...
sub set_options {
	my $c = &get_handle;

	$c->__restore_options();

	if (not @_) {
		return wantarray ? %{$c->{options}} : { %{$c->{options}} };
	}
	my %h;
	if (ref $_[0] && ref $_[0] ne "HASH") {
		return error("Invalid argument in %s::set_options", ref $c);
	} elsif (ref $_[0]) {
		%h = %{$_[0]};
	} else {
		%h = @_;
	}
	my %old = ();
	
	#TODO: test this
	$c->{restore_options} = { %{$c->{options}} };

	while (my ($k, $v) = each %h) {
		given($k) {
			when('die_on_error') { $old{$k} = $c->die_on_error($v) }
			when('print_error') { $old{$k} = $c->print_error($v) }
			when('print_warning') { $old{$k} = $c->print_warning($v) }
			when('print_query') {
					my $r = $c->print_query($v);
					$c->strict_error('Some option has not been set due to ignored errors') and return if not defined $r;
					$old{$k} = $r
				}
			when('strict') { $old{$k} = $c->strict($v) }
			when('replace') {
					my $r = $c->replace($v);
					$c->strict_error('Some option has not been set due to ignored errors') and return if not defined $r;
					$old{$k} = $r
				}
			when('connect_options') {
					my $r = $c->connect_options($v);
					$c->strict_error('Some option has not been set due to ignored errors') and return if not defined $r;
					$old{$k} = $r
				}
			when('auto_transaction') { $old{$k} = $c->auto_transaction($v) }
			when('auto_split') { $old{$k} = $c->auto_split($v) }
			when('use_connector') { $old{$k} = $c->use_connector($v) }
			when('stop_on_error') { $old{$k} = $c->stop_on_error($v) }
			default { $c->strict_error("No such option: $k") and return }
		}
	}

	$c->{restore_options} = { };

	return wantarray ? %old : \%old;
}


=for comment

sub set_option { 
	my $c = &get_handle;

	return $c->set_options({$_[0] => $_[1]}) if @_ == 2;
	
	$c->error("Bad number of arguments in %s::set_option", ref $c);
	return;
}

=cut




################################################################################
################################################################################
##                                                                            ##
##                          STANDARD QUERY FUNCTIONS                          ##
##                                                                            ##
################################################################################
################################################################################


=head1 STANDARD QUERY FUNCTIONS

=head2 execute

  execute(SQL);
  $c->execute(SQL);

This function execute the SQL code contained in its argument. The SQL is first
split at the boundary of each statement that it contains (except if the C<auto_split>
option is false) and is then executed statement by statement in a single transaction
(meaning that if one of the statement fails, nothing is changed in your database),
except if the C<auto_transaction> option is false.

The function will return a C<defined> value if everything succeeded, and C<undef>
if an error happen (and it is ignored, otherwise, the function will C<croak>).

The returned value may or may not be the total number of lines modified by your
query.

=head2 query_one_value

  my $v = query_one_value(SQL);
  my $v = $h->query_one_value(SQL);

This function return one scalar value corresponding to the result of the SQL query
provided. This query must be a data returning query (e.g. C<SELECT>).

The function will raise an error if nothing is returned by your query (even if
the SQL code itself is valid) and, if in C<strict> mode, the function will also
fail if your query returns more than one line or one column (but note that the
query is still executed).

In case of an error (and if C<die_on_error> is not set) the function will return
C<undef>. You must not that this value may also be returned if your query returns
a C<NULL> value. In that case to check if an error happened you must check the
C<errstr> function which will return C<undef> if there was no errors.

Also, if C<auto_split> is activated, the SQL query provided to this function may
not contains more than one statement (otherwise an error is thrown). If the
option is not set, this condition will not be tested and there is no guarantee
on what will happens if you try to execute more than one statement with this function.

=head2 query_one_line

  my @l = query_one_line(SQL);
  my @l = $h->query_one_line(SQL);
  my $l = query_one_line(SQL);
  my $l = $h->query_one_line(SQL);

This function returns a list corresponding to one line of result of the provided
SQL query. If called in scalar context, the function will return a reference to an
array rather than a list. You may safely store this array which will not be reused
by the library.

In list context, the function will return an empty list in case of an error. You
may distinguish this from a query returning no columns with the C<errstr> function.
In scalar context, the function will return C<undef> in case of error or a reference
to an empty array for query returning no columns.

An error will happen if the query returns no rows at all and, if you are in
C<strict> mode, an error will also happen if the query returns more than one rows.

The same limitation applies to this function as for the C<query_one_line> about
the number of statement in your query.

=head2 query_all_lines

  my @a = query_all_lines(SQL);
  my @a = $h->query_all_lines(SQL);
  my $a = query_all_lines(SQL);
  my $a = $h->query_all_lines(SQL);

This function executes the given SQL and returns all the returned data from this
query. In list context, the fonction returns a list of all the lines. Each lines
is a reference to an array, even if there is only one column per lines. In scalar
context, the function returns a reference to an array containing each of the array
reference for each lines.

In case of errors, if C<die_on_error> is not set, the function will return C<undef>
in scalar context and an empty list in list context. This could also be the correct
result of a query returning no rows, use the C<errstr> function to distinguish
between these two cases.

If there is an error during the fetching of the data and that C<die_on_error> is
not set and you are not in C<strict> mode, then all the data already fetched will
be returned but no tentatives will be done to try to fetch any more data.

The same limitation applies to this function as for the C<query_one_line> about
the number of statement in your query.

=head2 query_one_column

  my @l = query_one_column(SQL);
  my @l = $h->query_one_column(SQL);
  my $l = query_one_column(SQL);
  my $l = $h->query_one_column(SQL);

This function returns a list corresponding to one column of result of the provided
SQL query. If called in scalar context, the function will return a reference to an
array rather than a list. You may safely store this array which will not be reused
by the library.

In list context, the function will return an empty list in case of an error. You
may distinguish this from a query returning no lines with the C<errstr> function.
In scalar context, the function will return C<undef> in case of error or a reference
to an empty array for query returning no lines.

An error will happen if the query returns no columns at all and, if you are in
C<strict> mode, an error will also happen if the query returns more than one columns.

The same limitation applies to this function as for the C<query_one_line> about
the number of statement in your query.

=head2 query_to_file

  query_to_file(SQL, file_name, separator, new_line);
  my $v = $h->query_one_value(SQL, file_name, separator, new_line);

This function...

=cut


push @EXPORT_OK, ('execute', 'query_one_value', 'query_one_line', 'query_all_lines',
				'query_one_column', 'query_to_file');


sub execute {
	my $c = &check_options or return;

	$c->check_conn() or return;
	my @queries = $c->split_query($_[0]);
	
	my $proc = sub {
			my $a = 0;

			for my $r (@queries) {
			# TODO: lever l'erreur strict seulement dans le mode stop_on_error
			# et s'il reste des requête à exécuter.
				if (!$c->low_level_prepare($r)) {
					$c->strict_error("Some queries have not been executed due to an error") and die "EINT\n";
					die "ESTOP:$a\n" if $c->{options}{stop_on_error};
					next;
				}
				my $v = $c->low_level_execute();
				$c->low_level_finish();
				if (not defined $v) {
					$c->strict_error("Some queries have not been executed due to an error") and die "EINT\n";
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
	my ($c, $req) = @_;

	$req = $c->get_one_query($req) or return;

	$c->check_conn() or return;
	$c->low_level_prepare($req) or return;
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
	my $c = &check_options or return;
	return $c->__query_one_value(@_);
}

# array ou array-ref selon le contexte (sûr, pas écraser au prochain appel).
sub query_one_line {
	my $c = &check_options or return;
	
	my $req = $c->get_one_query($_[0]) or return;

	$c->check_conn() or return;
	$c->low_level_prepare($req) or return;
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
	my $c = &check_options or return;
	
	my $req = $c->get_one_query($_[0]) or return;

	$c->check_conn() or return;
	$c->low_level_prepare($req) or return;
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
	my $c = &check_options or return;

	my $req = $c->get_one_query($_[0]) or return;

	$c->check_conn() or return;
	$c->low_level_prepare($req) or return;

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


# low_level_query_to_file(req, FH, sep, nl)
# s'il n'y a qu'un argument effectif c'est la requête
# le suivant est le FH, etc. Ils peuvent être omis en partant de la fin.
# FH peut être une chaîne, éventuellement préfixé par '>>' pour append et non pas troncation
# du fichier. Sinon c'est STDOUT. sinon une ref à un IO ou GLOB
# sep est ";" par défaut et nl est '\n' par défaut).
# renvoie le nombre de lignes lues.
# On a les même limitations en cas d'erreur que pour la fonction request_all
# Particulièrement, on renvoie toujours le  nombre de lignes lues
# même si une erreur se produit (à condition qu'on l'ignore, of course).
# Par contre on renvoie undef si on ne peut pas ouvrir le fichier demandé.
# ou pas écrire dedans.
#
# Un jour il faut le réécrire pour bypasser le fetch_row_array_ref par une méthode plus rapide
# qui réutilise le même array à chaque fois.
sub query_to_file {
	my $c = &check_options or return;
	my ($req, $fh, $sep, $nl) = @_;
	
	$req = $c->get_one_query($req) or return;

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
	$c->low_level_prepare($req) or return;
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


################################################################################
################################################################################
##                                                                            ##
##                         HIGH LEVEL QUERY FUNCTIONS                         ##
##                                                                            ##
################################################################################
################################################################################


=head1 HIGH LEVEL QUERY FUNCTIONS

These functions (or method) provide higher level interface to the database. The implemetations
provided here try to be generic and portable but they may not work with any database
driver. If necessary, these functions will be overidden in the database specific
sub-classes. Be sure to check the documentation for the sub-classe that you are
using (if any) because the arguments of these function may differ from their base
version.

=head2 count_lines

  my $n = count_lines(SQL);
  my $n = $c->count_lines(SQL);

This function takes an SQL query (C<SELECT>-like), executes it and return the
number of lines that the query would have returned (with, e.g., the C<query_all_lines>
functions).

=head2 table_exists

  my $b = table_exists(table_name);
  my $b = $c->table_exists(table_name);

This function returns a boolean value indicating if there is a table with name
C<table_name>. The default implementation may erroneously returns I<false> if the
table exists but you do not have enough rights to access it.

This function might also returns I<true> when there is an object with the correct
name looking I<like> a table (e.g. a view) in the database.

=cut

push @EXPORT_OK, ('count_lines', 'table_exists');


sub __count_lines {
	my ($c, $req) = @_;

	$req = $c->get_one_query($req) or return;

#	return $c->__query_one_value("SELECT count(*) from (${req}) T_ANY_NAME");
	
	my $proc = sub {
			my $c = $c->__query_one_value("SELECT count(*) from (${req}) T_ANY_NAME");
			if (defined $c) {
				die "EGET:$c\n";
			} else {
				die "EINT\n";
			}
		};

	my $v = eval { $c->{db_con}->txn($proc) };

	if ($@ =~ m/^EINT$/) {
		return;
	} elsif ($@ =~ m/^EGET:(\d+)$/) {
		return $1;
	} elsif ($@) {
		die $@;
	} else {
		confess 'Should not happen';
	}
}

sub count_lines {
	my $c = &check_options;
	$c->check_conn() or return;

	return $c->__count_lines(@_);
}

# test aussi le droit en lecture, très mauvaise implémentation...
sub table_exists {
	my $c = &check_options;
	$c->check_conn() or return;

	my ($table) = @_;
	
	$table = $c->__replace($table);
		
	eval {
			$c->low_level_prepare("select * from $table") or die "FAIL\n";
			$c->low_level_finish();
			1;
		};

	if ($@) {
		return 0;
	} else {
		return 1;
	}

}

$EXPORT_TAGS{'all'} = [ @EXPORT_OK ];

1;

=head1 SUB-CLASSING

The implementation of this library is as generic as possible. However some
specific functions can be better written for some specific database server and
some helper function can be easier to use if they are tuned for a single
database server.

This specific support is provided through sub-classse which extend both the OO
and the functionnal interface of this library. As stated above, if there is a
sub-classe for your specific database, you should use it instead of this module,
otherwise.

=head2 Sub-classes

The sub-classes currently existing are the following ones:

=over 4

=item * L<SQLite|SQL::Exec::SQLite>: the in-file or in memory database with C<L<DBD::SQLite>>;

=item * L<Oracle|SQL::Exec::Oracle>: access to Oracle database server with C<L<DBD::Oracle>>;

=item * L<ODBC|SQL::Exec::ODBC>: access to any ODBC enabled DBMS through C<L<DBD::ODBC>>;

=item * L<Teradata|SQL::Exec::ODBC::Teradata>: access to a Teradata database with
the C<ODBC> driver (there is a C<DBD::Teradata> C<DBI> driver using the native
driver for this database (C<CLI>), but its latest version is not on CPAN, so I
recommend using the C<ODBC> interface).

=back

If your database of choice is not yet supported, let me know it and I will do my
best to add a module for it (if the DBMS is freely available) or help you add
this support (if I cannot have access to an instance of this database server).

In the meantime, C<SQL::Exec> should just work with your database. If that is
not the case, you should report this as a L<bug|/"BUGS">.

=head2 How to

...

=head1 EXAMPLE

Examples would be good.

=head1 CAVEATS

There is currently no support for placeholders (named or positional) in queries.
Mostly because I have not yet found a I<simple> way to expose this functionnality.

=head1 BUGS

Please report any bugs or feature requests to C<bug-sql-exec@rt.cpan.org>, or
through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=SQL-Exec>.

=head1 SEE ALSO

At some point or another you will want to look at the L<DBI> documentation,
mother of all database manipulation in Perl. You may also want to look at the
C<L<DBIx::Connector>> and C<L<SQL::SplitStatement>> modules upon which C<SQL::Exec>
is based.

There is several CPAN module similar to C<SQL::Exec>, I list here only the
closest (e.g. which does not impose OO upon your code), you should have a look
at them before deciding to use C<SQL::Exec>:
C<L<DBI::Simple>>, C<L<DBIx::Simple>>, C<L<DBIx::DWIW>>, C<L<DBIx::Wrapper>>, 
C<L<DBIx::SimpleGoBetween>>, C<L<DBIx::Sunny>>, C<L<SQL::Executor>>.

Also, C<SQL::Exec> will try its best to enable you to run your SQL code
in a simple and efficiant way but it will not boil your coffee. You may be
interested in other packages which may be used to go beyond C<SQL::Exec>
functionnalities, like C<L<SQL::Abstract>> and C<L<SQL::Transformer>>.

=head1 AUTHOR

Mathias Kende (mathias@cpan.org)

=head1 VERSION

Version 0.02 (January 2013)


=head1 COPYRIGHT & LICENSE

Copyright 2012 © Mathias Kende.  All rights reserved.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut


