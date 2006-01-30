package DBIx::Class::Schema::Loader::Generic;

use strict;
use warnings;

use Carp;
use Lingua::EN::Inflect;
use base qw/Class::Accessor::Fast/;

require DBIx::Class::Core;

# The first group are all arguments which are may be defaulted within,
# The last two (classes, monikers) are generated locally:

__PACKAGE__->mk_ro_accessors(qw/
                                schema
                                dsn
                                user
                                password
                                options
                                exclude
                                constraint
                                additional_classes
                                additional_base_classes
                                left_base_classes
                                relationships
                                inflect
                                db_schema
                                drop_db_schema
                                debug

                                classes
                                monikers
                             /);

=head1 NAME

DBIx::Class::Schema::Loader::Generic - Generic DBIx::Class::Schema::Loader Implementation.

=head1 SYNOPSIS

See L<DBIx::Class::Schema::Loader>

=head1 DESCRIPTION

=head2 OPTIONS

Available constructor options are:

=head3 additional_base_classes

List of additional base classes your table classes will use.

=head3 left_base_classes

List of additional base classes, that need to be leftmost.

=head3 additional_classes

List of additional classes which your table classes will use.

=head3 constraint

Only load tables matching regex.

=head3 exclude

Exclude tables matching regex.

=head3 debug

Enable debug messages.

=head3 dsn

DBI Data Source Name.

=head3 password

Password.

=head3 relationships

Try to automatically detect/setup has_a and has_many relationships.

=head3 inflect

An hashref, which contains exceptions to Lingua::EN::Inflect::PL().
Useful for foreign language column names.

=head3 user

Username.

=head2 METHODS

=cut

=head3 new

Constructor for L<DBIx::Class::Schema::Loader::Generic>, used internally
by L<DBIx::Class::Schema::Loader>.

=cut

# ensure that a peice of object data is a valid arrayref, creating
# an empty one or encapsulating whatever's there.
sub _ensure_arrayref {
    my $self = shift;

    foreach (@_) {
        $self->{$_} ||= [];
        $self->{$_} = [ $self->{$_} ]
            unless ref $self->{$_} eq 'ARRAY';
    }
}

sub new {
    my ( $class, %args ) = @_;

    my $self = { %args };

    bless $self => $class;

    $self->{db_schema}  ||= '';
    $self->{constraint} ||= '.*';
    $self->{inflect}    ||= {};
    $self->_ensure_arrayref(qw/additional_classes
                               additional_base_classes
                               left_base_classes/);

    $self->{monikers} = {};
    $self->{classes} = {};

    $self->schema->connection($self->dsn, $self->user,
                              $self->password, $self->options);

    warn qq/\### START DBIx::Class::Schema::Loader dump ###\n/
        if $self->debug;

    $self->_load_classes;
    $self->_load_relationships if $self->relationships;

    warn qq/\### END DBIx::Class::Schema::Loader dump ###\n/
        if $self->debug;
    $self->schema->storage->dbh->disconnect; # XXX this should be ->storage->disconnect later?

    $self;
}

# Overload in your driver class
sub _db_classes { croak "ABSTRACT METHOD" }

# Inflect a relationship name
#   XXX (should pluralize, but currently also tends to de-pluralize plurals)
sub _inflect_relname {
    my ($self, $relname) = @_;

    return $self->inflect->{$relname} if exists $self->inflect->{$relname};
    return Lingua::EN::Inflect::PL($relname);
}

# Set up a simple relation with just a local col and foreign table
sub _make_simple_rel {
    my ($self, $table, $other, $col) = @_;

    my $table_class = $self->classes->{$table};
    my $other_class = $self->classes->{$other};
    my $table_relname = $self->_inflect_relname(lc $table);

    warn qq/\# Belongs_to relationship\n/ if $self->debug;
    warn qq/$table_class->belongs_to( '$col' => '$other_class' );\n\n/
      if $self->debug;
    $table_class->belongs_to( $col => $other_class );

    warn qq/\# Has_many relationship\n/ if $self->debug;
    warn qq/$other_class->has_many( '$table_relname' => '$table_class',/
      .  qq/$col);\n\n/
      if $self->debug;

    $other_class->has_many( $table_relname => $table_class, $col);
}

# not a class method, just a helper for cond_rel XXX
sub _stringify_hash {
    my $href = shift;

    return '{ ' .
           join(q{, }, map("$_ => $href->{$_}", keys %$href))
           . ' }';
}

# Set up a complex relation based on a hashref condition
sub _make_cond_rel {
    my ( $self, $table, $other, $cond ) = @_;

    my $table_class = $self->classes->{$table};
    my $other_class = $self->classes->{$other};
    my $table_relname = $self->_inflect_relname(lc $table);
    my $other_relname = lc $other;

    # for single-column case, set the relname to the column name,
    # to make filter accessors work
    if(scalar keys %$cond == 1) {
        my ($col) = keys %$cond;
        $other_relname = $cond->{$col};
    }

    my $rev_cond = { reverse %$cond };

    my $cond_printable = _stringify_hash($cond)
        if $self->debug;
    my $rev_cond_printable = _stringify_hash($rev_cond)
        if $self->debug;

    warn qq/\# Belongs_to relationship\n/ if $self->debug;

    warn qq/$table_class->belongs_to( '$other_relname' => '$other_class',/
      .  qq/$cond_printable);\n\n/
      if $self->debug;

    $table_class->belongs_to( $other_relname => $other_class, $cond);

    warn qq/\# Has_many relationship\n/ if $self->debug;

    warn qq/$other_class->has_many( '$table_relname' => '$table_class',/
      .  qq/$rev_cond_printable);\n\n/
      .  qq/);\n\n/
      if $self->debug;

    $other_class->has_many( $table_relname => $table_class, $rev_cond);
}

# Load and setup classes
sub _load_classes {
    my $self = shift;

    my @tables     = $self->_tables();
    my @db_classes = $self->_db_classes();
    my $schema     = $self->schema;

    foreach my $table (@tables) {
        my $constraint = $self->constraint;
        my $exclude = $self->exclude;

        next unless $table =~ /$constraint/;
        next if defined $exclude && $table =~ /$exclude/;

        my ($db_schema, $tbl) = split /\./, $table;
        my $tablename = lc $table;
        if($tbl) {
            $tablename = $self->drop_db_schema ? $tbl : lc $table;
        }
        my $lc_tblname = lc $tablename;

        my $table_moniker = $self->_table2moniker($db_schema, $tbl);
        my $table_class = $schema . q{::} . $table_moniker;

        # XXX all of this needs require/eval error checking
        $schema->inject_base( $table_class, 'DBIx::Class::Core' );
        $_->require for @db_classes;
        $schema->inject_base( $table_class, $_ ) for @db_classes;
        $schema->inject_base( $table_class, $_ )
            for @{$self->additional_base_classes};
        eval "package $table_class; use $_;"
            for @{$self->additional_classes};
        $schema->inject_base( $table_class, $_ )
            for @{$self->left_base_classes};

        warn qq/\# Initializing table "$tablename" as "$table_class"\n/
            if $self->debug;
        $table_class->table($lc_tblname);

        my ( $cols, $pks ) = $self->_table_info($table);
        carp("$table has no primary key") unless @$pks;
        $table_class->add_columns(@$cols);
        $table_class->set_primary_key(@$pks) if @$pks;

        warn qq/$table_class->table('$tablename');\n/ if $self->debug;
        my $columns = join "', '", @$cols;
        warn qq/$table_class->add_columns('$columns')\n/ if $self->debug;
        my $primaries = join "', '", @$pks;
        warn qq/$table_class->set_primary_key('$primaries')\n/
            if $self->debug && @$pks;

        $schema->register_class($table_moniker, $table_class);
        $self->classes->{$lc_tblname} = $table_class;
        $self->monikers->{$lc_tblname} = $table_moniker;
    }
}

=head3 tables

Returns a sorted list of tables.

    my @tables = $loader->tables;

=cut

sub tables {
    my $self = shift;

    return sort keys %{ $self->monikers };
}

# Find and setup relationships
sub _load_relationships {
    my $self = shift;

    my $dbh = $self->schema->storage->dbh;
    my $quoter = $dbh->get_info(29) || q{"};
    foreach my $table ( $self->tables ) {
        my $rels = {};
        my $sth = $dbh->foreign_key_info( '',
            $self->db_schema, '', '', '', $table );
        next if !$sth;
        while(my $raw_rel = $sth->fetchrow_hashref) {
            my $uk_tbl  = lc $raw_rel->{UK_TABLE_NAME};
            my $uk_col  = lc $raw_rel->{UK_COLUMN_NAME};
            my $fk_col  = lc $raw_rel->{FK_COLUMN_NAME};
            my $relid   = lc $raw_rel->{UK_NAME};
            $uk_tbl =~ s/$quoter//g;
            $uk_col =~ s/$quoter//g;
            $fk_col =~ s/$quoter//g;
            $relid  =~ s/$quoter//g;
            $rels->{$relid}->{tbl} = $uk_tbl;
            $rels->{$relid}->{cols}->{$uk_col} = $fk_col;
        }

        foreach my $relid (keys %$rels) {
            my $reltbl = $rels->{$relid}->{tbl};
            my $cond   = $rels->{$relid}->{cols};
            eval { $self->_make_cond_rel( $table, $reltbl, $cond ) };
              warn qq/\# belongs_to_many failed "$@"\n\n/
                if $@ && $self->debug;
        }
    }
}

# Make a moniker from a table
sub _table2moniker {
    my ( $self, $db_schema, $table ) = @_;

    my $db_schema_ns;

    if($table) {
        $db_schema = ucfirst lc $db_schema;
        $db_schema_ns = $db_schema if(!$self->drop_db_schema);
    } else {
        $table = $db_schema;
    }

    my $moniker = join '', map ucfirst, split /[\W_]+/, lc $table;
    $moniker = $db_schema_ns ? $db_schema_ns . $moniker : $moniker;

    return $moniker;
}

# Overload in driver class
sub _tables { croak "ABSTRACT METHOD" }

sub _table_info { croak "ABSTRACT METHOD" }

=head1 SEE ALSO

L<DBIx::Class::Schema::Loader>

=cut

1;
