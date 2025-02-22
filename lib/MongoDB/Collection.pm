#  Copyright 2009 - present MongoDB, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

use strict;
use warnings;
package MongoDB::Collection;


# ABSTRACT: A MongoDB Collection

use version;
our $VERSION = 'v2.2.1';

use MongoDB::ChangeStream;
use MongoDB::Error;
use MongoDB::IndexView;
use MongoDB::InsertManyResult;
use MongoDB::QueryResult;
use MongoDB::WriteConcern;
use MongoDB::Op::_Aggregate;
use MongoDB::Op::_BatchInsert;
use MongoDB::Op::_BulkWrite;
use MongoDB::Op::_Count;
use MongoDB::Op::_CreateIndexes;
use MongoDB::Op::_Delete;
use MongoDB::Op::_Distinct;
use MongoDB::Op::_DropCollection;
use MongoDB::Op::_FindAndDelete;
use MongoDB::Op::_FindAndUpdate;
use MongoDB::Op::_InsertOne;
use MongoDB::Op::_ListIndexes;
use MongoDB::Op::_ParallelScan;
use MongoDB::Op::_RenameCollection;
use MongoDB::Op::_Query;
use MongoDB::Op::_Update;
use MongoDB::_Types qw(
    BSONCodec
    NonNegNum
    ReadPreference
    ReadConcern
    WriteConcern
);
use Types::Standard qw(
    HashRef
    InstanceOf
    Str
);
use Tie::IxHash;
use Carp 'carp';
use boolean;
use Safe::Isa;
use Scalar::Util qw/blessed reftype/;
use Moo;
use namespace::clean -except => 'meta';

#--------------------------------------------------------------------------#
# constructor attributes
#--------------------------------------------------------------------------#

=attr database

The L<MongoDB::Database> representing the database that contains
the collection.

=cut

has database => (
    is       => 'ro',
    isa      => InstanceOf['MongoDB::Database'],
    required => 1,
);

=attr name

The name of the collection.

=cut

has name => (
    is       => 'ro',
    isa      => Str,
    required => 1,
);

=attr read_preference

A L<MongoDB::ReadPreference> object.  It may be initialized with a string
corresponding to one of the valid read preference modes or a hash reference
that will be coerced into a new MongoDB::ReadPreference object.
By default it will be inherited from a L<MongoDB::Database> object.

=cut

has read_preference => (
    is       => 'ro',
    isa      => ReadPreference,
    required => 1,
    coerce   => ReadPreference->coercion,
);

=attr write_concern

A L<MongoDB::WriteConcern> object.  It may be initialized with a hash
reference that will be coerced into a new MongoDB::WriteConcern object.
By default it will be inherited from a L<MongoDB::Database> object.

=cut

has write_concern => (
    is       => 'ro',
    isa      => WriteConcern,
    required => 1,
    coerce   => WriteConcern->coercion,
);

=attr read_concern

A L<MongoDB::ReadConcern> object.  May be initialized with a hash
reference or a string that will be coerced into the level of read
concern.

By default it will be inherited from a L<MongoDB::Database> object.

=cut

has read_concern => (
    is       => 'ro',
    isa      => ReadConcern,
    required => 1,
    coerce   => ReadConcern->coercion,
);

=attr max_time_ms

Specifies the default maximum amount of time in milliseconds that the
server should use for working on a query.

B<Note>: this will only be used for server versions 2.6 or greater, as that
was when the C<$maxTimeMS> meta-operator was introduced.

=cut

has max_time_ms => (
    is      => 'ro',
    isa     => NonNegNum,
    required => 1,
);

=attr bson_codec

An object that provides the C<encode_one> and C<decode_one> methods, such
as from L<BSON>.  It may be initialized with a hash reference that
will be coerced into a new L<BSON> object.  By default it will be
inherited from a L<MongoDB::Database> object.

=cut

has bson_codec => (
    is       => 'ro',
    isa      => BSONCodec,
    coerce   => BSONCodec->coercion,
    required => 1,
);

#--------------------------------------------------------------------------#
# computed attributes
#--------------------------------------------------------------------------#

=method client

    $client = $coll->client;

Returns the L<MongoDB::MongoClient> object associated with this
object.

=cut

has _client => (
    is      => 'lazy',
    isa     => InstanceOf['MongoDB::MongoClient'],
    reader  => 'client',
    init_arg => undef,
    builder => '_build__client',
);

sub _build__client {
    my ($self) = @_;
    return $self->database->_client;
}

=method full_name

    $full_name = $coll->full_name;

Returns the full name of the collection, including the namespace of the
database it's in prefixed with a dot character.  E.g. collection "foo" in
database "test" would result in a C<full_name> of "test.foo".

=cut

has _full_name => (
    is      => 'lazy',
    isa     => Str,
    reader  => 'full_name',
    init_arg => undef,
    builder => '_build__full_name',
);

sub _build__full_name {
    my ($self) = @_;
    my $name    = $self->name;
    my $db_name = $self->database->name;
    return "${db_name}.${name}";
}

=method indexes

    $indexes = $collection->indexes;

    $collection->indexes->create_one( [ x => 1 ], { unique => 1 } );
    $collection->indexes->drop_all;

Returns a L<MongoDB::IndexView> object for managing the indexes associated
with the collection.

=cut

has _indexes => (
    is      => 'lazy',
    isa     => InstanceOf['MongoDB::IndexView'],
    reader  => 'indexes',
    init_arg => undef,
    builder => '_build__indexes',
);

sub _build__indexes {
    my ($self) = @_;
    return MongoDB::IndexView->new( collection => $self );
}

# these are constant, so we cache them
has _op_args => (
    is       => 'lazy',
    isa      => HashRef,
    init_arg => undef,
    builder  => '_build__op_args',
);

sub _build__op_args {
    my ($self) = @_;
    return {
        client              => $self->client,
        db_name             => $self->database->name,
        bson_codec          => $self->bson_codec,
        coll_name           => $self->name,
        write_concern       => $self->write_concern,
        read_concern        => $self->read_concern,
        read_preference     => $self->read_preference,
        full_name           => join( ".", $self->database->name, $self->name ),
        monitoring_callback => $self->client->monitoring_callback,
    };
}

with $_ for qw(
  MongoDB::Role::_DeprecationWarner
);

#--------------------------------------------------------------------------#
# public methods
#--------------------------------------------------------------------------#

=method clone

    $coll2 = $coll1->clone( write_concern => { w => 2 } );

Constructs a copy of the original collection, but allows changing
attributes in the copy.

=cut

sub clone {
    my ($self, @args) = @_;
    my $class = ref($self);
    if ( @args == 1 && ref( $args[0] ) eq 'HASH' ) {
        return $class->new( %$self, %{$args[0]} );
    }

    return $class->new( %$self, @args );
}

=method with_codec

    $coll2 = $coll1->with_codec( $new_codec );
    $coll2 = $coll1->with_codec( prefer_numeric => 1 );

Constructs a copy of the original collection, but clones the C<bson_codec>.
If given an object that does C<encode_one> and C<decode_one>, it is
equivalent to:

    $coll2 = $coll1->clone( bson_codec => $new_codec );

If given a hash reference or a list of key/value pairs, it is equivalent
to:

    $coll2 = $coll1->clone(
        bson_codec => $coll1->bson_codec->clone( @list )
    );

=cut

sub with_codec {
    my ( $self, @args ) = @_;
    if ( @args == 1 ) {
        my $arg = $args[0];
        if ( eval { $arg->can('encode_bson') && $arg->can('decode_bson') } ) {
            return $self->clone( bson_codec => $arg );
        }
        elsif ( ref $arg eq 'HASH' ) {
            return $self->clone( bson_codec => $self->bson_codec->clone(%$arg) );
        }
    }
    elsif ( @args % 2 == 0 ) {
        return $self->clone( bson_codec => $self->bson_codec->clone(@args) );
    }

    # fallthrough is argument error
    MongoDB::UsageError->throw(
        "argument to with_codec must be new codec, hashref or key/value pairs" );
}

=method insert_one

    $res = $coll->insert_one( $document );
    $res = $coll->insert_one( $document, $options );
    $id = $res->inserted_id;

Inserts a single L<document|/Document> into the database and returns a
L<MongoDB::InsertOneResult> or L<MongoDB::UnacknowledgedResult> object.

If no C<_id> field is present, one will be added when a document is
serialized for the database without modifying the original document.
The generated C<_id> may be retrieved from the result object.

An optional hash reference of options may be given.

Valid options include:

=for :list
* C<bypassDocumentValidation> - skips document validation, if enabled; this
  is ignored for MongoDB servers older than version 3.2.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>

=cut

# args not unpacked for efficiency; args are self, document
sub insert_one {
    MongoDB::UsageError->throw("document argument must be a reference")
      unless ref( $_[1] );

    return $_[0]->client->send_retryable_write_op(
        MongoDB::Op::_InsertOne->_new(
            session => $_[0]->client->_get_session_from_hashref( $_[2] ),
            ( defined $_[2] ? (%{$_[2]}) : () ),
            document => $_[1],
            %{ $_[0]->_op_args },
        )
    );
}

=method insert_many

    $res = $coll->insert_many( [ @documents ] );
    $res = $coll->insert_many( [ @documents ], { ordered => 0 } );

Inserts each of the L<documents|/Documents> in an array reference into the
database and returns a L<MongoDB::InsertManyResult> or
L<MongoDB::UnacknowledgedResult>.  This is syntactic sugar for doing a
L<MongoDB::BulkWrite> operation.

If no C<_id> field is present, one will be added when a document is
serialized for the database without modifying the original document.
The generated C<_id> may be retrieved from the result object.

An optional hash reference of options may be provided.

Valid options include:

=for :list
* C<bypassDocumentValidation> - skips document validation, if enabled; this
  is ignored for MongoDB servers older than version 3.2.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>
* C<ordered> – when true, the server will halt insertions after the first
  error (if any).  When false, all documents will be processed and any
  error will only be thrown after all insertions are attempted.  The
  default is true.

On MongoDB servers before version 2.6, C<insert_many> bulk operations are
emulated with individual inserts to capture error information.  On 2.6 or
later, this method will be significantly faster than individual C<insert_one>
calls.

=cut

# args not unpacked for efficiency; args are self, document, options
sub insert_many {
    MongoDB::UsageError->throw("documents argument must be an array reference")
      unless ref( $_[1] ) eq 'ARRAY';

    my $op = MongoDB::Op::_BulkWrite->_new(
        # default
        ordered => 1,
        # user overrides
        session => $_[0]->client->_get_session_from_hashref( $_[2] ),
        ( defined $_[2] ? ( %{ $_[2] } ) : () ),
        # un-overridable
        queue => [ map { [ insert => $_ ] } @{ $_[1] } ],
        # insert_many is specifically retryable (PERL-792)
        _retryable => 1,
        %{ $_[0]->_op_args },
    );

    # internally ends up performing a retryable write if possible, see OP::_BulkWrite
    my $res = $_[0]->client->send_write_op( $op );

    return $op->_should_use_acknowledged_write
      ? MongoDB::InsertManyResult->_new(
        acknowledged         => 1,
        inserted             => $res->inserted,
        write_errors         => [],
        write_concern_errors => [],
      )
      : MongoDB::UnacknowledgedResult->_new(
        write_errors         => [],
        write_concern_errors => [],
      );
}

=method delete_one

    $res = $coll->delete_one( $filter );
    $res = $coll->delete_one( { _id => $id } );
    $res = $coll->delete_one( $filter, { collation => { locale => "en_US" } } );

Deletes a single document that matches a L<filter expression|/Filter expression> and returns a
L<MongoDB::DeleteResult> or L<MongoDB::UnacknowledgedResult> object.

A hash reference of options may be provided.

Valid options include:

=for :list
* C<collation> - a L<document|/Document> defining the collation for this operation.
  See docs for the format of the collation document here:
  L<https://docs.mongodb.com/master/reference/collation/>.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>

=cut

# args not unpacked for efficiency; args are self, filter, options
sub delete_one {
    MongoDB::UsageError->throw("filter argument must be a reference")
      unless ref( $_[1] );

    return $_[0]->client->send_retryable_write_op(
        MongoDB::Op::_Delete->_new(
            session => $_[0]->client->_get_session_from_hashref( $_[2] ),
            ( defined $_[2] ? (%{$_[2]}) : () ),
            filter   => $_[1],
            just_one => 1,
            %{ $_[0]->_op_args },
        )
    );
}

=method delete_many

    $res = $coll->delete_many( $filter );
    $res = $coll->delete_many( { name => "Larry" } );
    $res = $coll->delete_many( $filter, { collation => { locale => "en_US" } } );

Deletes all documents that match a L<filter expression|/Filter expression>
and returns a L<MongoDB::DeleteResult> or L<MongoDB::UnacknowledgedResult>
object.

Valid options include:

=for :list
* C<collation> - a L<document|/Document> defining the collation for this operation.
  See docs for the format of the collation document here:
  L<https://docs.mongodb.com/master/reference/collation/>.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>

=cut

# args not unpacked for efficiency; args are self, filter, options
sub delete_many {
    MongoDB::UsageError->throw("filter argument must be a reference")
      unless ref( $_[1] );

    return $_[0]->client->send_write_op(
        MongoDB::Op::_Delete->_new(
            session => $_[0]->client->_get_session_from_hashref( $_[2] ),
            ( defined $_[2] ? (%{$_[2]}) : () ),
            filter   => $_[1],
            just_one => 0,
            %{ $_[0]->_op_args },
        )
    );
}

=method replace_one

    $res = $coll->replace_one( $filter, $replacement );
    $res = $coll->replace_one( $filter, $replacement, { upsert => 1 } );

Replaces one document that matches a L<filter expression|/Filter
expression> and returns a L<MongoDB::UpdateResult> or
L<MongoDB::UnacknowledgedResult> object.

The replacement document must not have any field-update operators in it (e.g.
C<$set>).

A hash reference of options may be provided.

Valid options include:

=for :list
* C<bypassDocumentValidation> - skips document validation, if enabled; this
  is ignored for MongoDB servers older than version 3.2.
* C<collation> - a L<document|/Document> defining the collation for this operation.
  See docs for the format of the collation document here:
  L<https://docs.mongodb.com/master/reference/collation/>.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>
* C<upsert> – defaults to false; if true, a new document will be added if one
  is not found

=cut

# args not unpacked for efficiency; args are self, filter, update, options
sub replace_one {
    MongoDB::UsageError->throw("filter and replace arguments must be references")
      unless ref( $_[1] ) && ref( $_[2] );

    return $_[0]->client->send_retryable_write_op(
        MongoDB::Op::_Update->_new(
            session => $_[0]->client->_get_session_from_hashref( $_[3] ),
            ( defined $_[3] ? (%{$_[3]}) : () ),
            filter     => $_[1],
            update     => $_[2],
            multi      => false,
            is_replace => 1,
            %{ $_[0]->_op_args },
        )
    );
}

=method update_one

    $res = $coll->update_one( $filter, $update );
    $res = $coll->update_one( $filter, $update, { upsert => 1 } );

Updates one document that matches a L<filter expression|/Filter expression>
and returns a L<MongoDB::UpdateResult> or L<MongoDB::UnacknowledgedResult>
object.

The update document must have only field-update operators in it (e.g.
C<$set>).

A hash reference of options may be provided.

Valid options include:

=for :list
* C<arrayFilters> - An array of filter documents that determines which array
  elements to modify for an update operation on an array field. Only available
  for MongoDB servers of version 3.6+.
* C<bypassDocumentValidation> - skips document validation, if enabled; this
  is ignored for MongoDB servers older than version 3.2.
* C<collation> - a L<document|/Document> defining the collation for this operation.
  See docs for the format of the collation document here:
  L<https://docs.mongodb.com/master/reference/collation/>.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>
* C<upsert> – defaults to false; if true, a new document will be added if
  one is not found by taking the filter expression and applying the update
  document operations to it prior to insertion.

=cut

# args not unpacked for efficiency; args are self, filter, update, options
sub update_one {
    MongoDB::UsageError->throw("filter and update arguments must be references")
      unless ref( $_[1] ) && ref( $_[2] );

    return $_[0]->client->send_retryable_write_op(
        MongoDB::Op::_Update->_new(
            session => $_[0]->client->_get_session_from_hashref( $_[3] ),
            ( defined $_[3] ? (%{$_[3]}) : () ),
            filter     => $_[1],
            update     => $_[2],
            multi      => false,
            is_replace => 0,
            %{ $_[0]->_op_args },
        )
    );
}

=method update_many

    $res = $coll->update_many( $filter, $update );
    $res = $coll->update_many( $filter, $update, { upsert => 1 } );

Updates one or more documents that match a L<filter expression|/Filter
expression> and returns a L<MongoDB::UpdateResult> or
L<MongoDB::UnacknowledgedResult> object.

The update document must have only field-update operators in it (e.g.
C<$set>).

A hash reference of options may be provided.

Valid options include:

=for :list
* C<arrayFilters> - An array of filter documents that determines which array
  elements to modify for an update operation on an array field. Only available
  for MongoDB servers of version 3.6+.
* C<bypassDocumentValidation> - skips document validation, if enabled; this
  is ignored for MongoDB servers older than version 3.2.
* C<collation> - a L<document|/Document> defining the collation for this operation.
  See docs for the format of the collation document here:
  L<https://docs.mongodb.com/master/reference/collation/>.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>
* C<upsert> – defaults to false; if true, a new document will be added if
  one is not found by taking the filter expression and applying the update
  document operations to it prior to insertion.

=cut

# args not unpacked for efficiency; args are self, filter, update, options
sub update_many {
    MongoDB::UsageError->throw("filter and update arguments must be references")
      unless ref( $_[1] ) && ref( $_[2] );

    return $_[0]->client->send_write_op(
        MongoDB::Op::_Update->_new(
            session => $_[0]->client->_get_session_from_hashref( $_[3] ),
            ( defined $_[3] ? (%{$_[3]}) : () ),
            filter     => $_[1],
            update     => $_[2],
            multi      => true,
            is_replace => 0,
            %{ $_[0]->_op_args },
        )
    );
}

=method find

    $cursor = $coll->find( $filter );
    $cursor = $coll->find( $filter, $options );

    $cursor = $coll->find({ i => { '$gt' => 42 } }, {limit => 20});

Executes a query with a L<filter expression|/Filter expression> and returns a
B<lazy> C<MongoDB::Cursor> object.  (The query is not immediately
issued to the server; see below for details.)

The query can be customized using L<MongoDB::Cursor> methods, or with an
optional hash reference of options.

Valid options include:

=for :list
* C<allowPartialResults> - get partial results from a mongos if some shards are
  down (instead of throwing an error).
* C<batchSize> – the number of documents to return per batch.
* C<collation> - a L<document|/Document> defining the collation for this operation.
  See docs for the format of the collation document here:
  L<https://docs.mongodb.com/master/reference/collation/>.
* C<comment> – attaches a comment to the query.
* C<cursorType> – indicates the type of cursor to use. It must be one of three
  string values: C<'non_tailable'> (the default), C<'tailable'>, and
  C<'tailable_await'>.
* C<hint> – L<specify an index to
  use|http://docs.mongodb.org/manual/reference/command/count/#specify-the-index-to-use>;
  must be a string, array reference, hash reference or L<Tie::IxHash> object.
* C<limit> – the maximum number of documents to return.
* C<max> – L<specify the B<exclusive> upper bound for a specific index|
  https://docs.mongodb.com/manual/reference/operator/meta/max/>.
* C<maxAwaitTimeMS> – the maximum amount of time for the server to wait on
  new documents to satisfy a tailable cursor query. This only applies
  to a C<cursorType> of 'tailable_await'; the option is otherwise ignored.
  (Note, this will be ignored for servers before version 3.2.)
* C<maxScan> – (DEPRECATED) L<maximum number of documents or index keys to scan|
  https://docs.mongodb.com/manual/reference/operator/meta/maxScan/>.
* C<maxTimeMS> – the maximum amount of time to allow the query to run.
  (Note, this will be ignored for servers before version 2.6.)
* C<min> – L<specify the B<inclusive> lower bound for a specific index|
  https://docs.mongodb.com/manual/reference/operator/meta/min/>.
* C<modifiers> – (DEPRECATED) a hash reference of dollar-prefixed L<query
  modifiers|http://docs.mongodb.org/manual/reference/operator/query-modifier/>
  modifying the output or behavior of a query. Top-level options will always
  take precedence over corresponding modifiers.  Supported modifiers include
  $comment, $hint, $maxScan, $maxTimeMS, $max, $min, $orderby, $returnKey,
  $showDiskLoc, and $snapshot.  Some options may not be supported by
  newer server versions.
* C<noCursorTimeout> – if true, prevents the server from timing out a cursor
  after a period of inactivity.
* C<projection> - a hash reference defining fields to return. See "L<limit
  fields to return|http://docs.mongodb.org/manual/tutorial/project-fields-from-query-results/>"
  in the MongoDB documentation for details.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>
* C<returnKey> – L<Only return the index field or fields for the results of
  the query|https://docs.mongodb.com/manual/reference/operator/meta/returnKey/>.
* C<showRecordId> – modifies the output of a query by adding a field
  L<$recordId|https://docs.mongodb.com/manual/reference/method/cursor.showRecordId/>
  that uniquely identifies a document in a collection.
* C<skip> – the number of documents to skip before returning.
* C<sort> – an L<ordered document|/Ordered document> defining the order in which
  to return matching documents.  See the L<$orderby
  documentation|https://docs.mongodb.com/manual/reference/operator/meta/orderby/>
  for examples.

For more information, see the L<Read Operations
Overview|http://docs.mongodb.org/manual/core/read-operations-introduction/> in
the MongoDB documentation.

B<Note>, a L<MongoDB::Cursor> object holds the query and does not issue the
query to the server until the L<result|MongoDB::Cursor/result> method is
called on it or until an iterator method like L<next|MongoDB::Cursor/next>
is called.  Performance will be better directly on a
L<MongoDB::QueryResult> object:

    my $query_result = $coll->find( $filter )->result;

    while ( my $next = $query_result->next ) {
        ...
    }

=cut

sub find {
    my ( $self, $filter, $options ) = @_;
    $options ||= {};

    # backwards compatible sort option for deprecated 'query' alias
    $options->{sort} = delete $options->{sort_by} if $options->{sort_by};

    # possibly fallback to default maxTimeMS
    if ( !exists $options->{maxTimeMS} && $self->max_time_ms ) {
        $options->{maxTimeMS} = $self->max_time_ms;
    }

    my $session = $self->client->_get_session_from_hashref( $options );

    # coerce to IxHash
    __ixhash( $options, 'sort' );

    return MongoDB::Cursor->new(
        client => $self->{_client},
        query => MongoDB::Op::_Query->_new(
            filter  => $filter || {},
            options => MongoDB::Op::_Query->precondition_options($options),
            session => $session,
            %{ $self->_op_args },
        )
    );
}

=method find_one

    $doc = $collection->find_one( $filter, $projection );
    $doc = $collection->find_one( $filter, $projection, $options );

Executes a query with a L<filter expression|/Filter expression> and returns a
single document.

If a projection argument is provided, it must be a hash reference specifying
fields to return.  See L<Limit fields to
return|http://docs.mongodb.org/manual/tutorial/project-fields-from-query-results/>
in the MongoDB documentation for details.

If only a filter is provided or if the projection document is an empty hash
reference, all fields will be returned.

    my $doc = $collection->find_one( $filter );
    my $doc = $collection->find_one( $filter, {}, $options );

A hash reference of options may be provided as a third argument. Valid keys
include:

=for :list
* C<collation> - a L<document|/Document> defining the collation for this operation.
  See docs for the format of the collation document here:
  L<https://docs.mongodb.com/master/reference/collation/>.
* C<maxTimeMS> – the maximum amount of time in milliseconds to allow the
  command to run.  (Note, this will be ignored for servers before version 2.6.)
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>
* C<sort> – an L<ordered document|/Ordered document> defining the order in which
  to return matching documents. If C<$orderby> also exists in the modifiers
  document, the sort field overwrites C<$orderby>.  See docs for
  L<$orderby|http://docs.mongodb.org/manual/reference/operator/meta/orderby/>.

See also core documentation on querying:
L<http://docs.mongodb.org/manual/core/read/>.

=cut

sub find_one {
    my ( $self, $filter, $projection, $options ) = @_;
    $options ||= {};

    # possibly fallback to default maxTimeMS
    if ( !exists $options->{maxTimeMS} && $self->max_time_ms ) {
        $options->{maxTimeMS} = $self->max_time_ms;
    }

    my $session = $self->client->_get_session_from_hashref( $options );

    # coerce to IxHash
    __ixhash( $options, 'sort' );
    # overide projection and limit
    $options->{projection} = $projection;
    $options->{limit} = -1;

    return $self->client->send_retryable_read_op(
        MongoDB::Op::_Query->_new(
            filter => $filter || {},
            options => MongoDB::Op::_Query->precondition_options($options),
            session => $session,
            %{ $self->_op_args },
          )
    )->next;
}

=method find_id

    $doc = $collection->find_id( $id );
    $doc = $collection->find_id( $id, $projection );
    $doc = $collection->find_id( $id, $projection, $options );

Executes a query with a L<filter expression|/Filter expression> of C<< { _id
=> $id } >> and returns a single document.

See the L<find_one|/find_one> documentation for details on the $projection and $options parameters.

See also core documentation on querying:
L<http://docs.mongodb.org/manual/core/read/>.

=cut

sub find_id {
    my $self = shift;
    my $id = shift;
    return $self->find_one({ _id => $id }, @_);
}

=method find_one_and_delete

    $doc = $coll->find_one_and_delete( $filter );
    $doc = $coll->find_one_and_delete( $filter, $options );

Given a L<filter expression|/Filter expression>, this deletes a document from
the database and returns it as it appeared before it was deleted.

A hash reference of options may be provided. Valid keys include:

=for :list
* C<collation> - a L<document|/Document> defining the collation for this operation.
  See docs for the format of the collation document here:
  L<https://docs.mongodb.com/master/reference/collation/>.
* C<maxTimeMS> – the maximum amount of time in milliseconds to allow the
  command to run.  (Note, this will be ignored for servers before version 2.6.)
* C<projection> - a hash reference defining fields to return. See "L<limit
  fields to
  return|http://docs.mongodb.org/manual/tutorial/project-fields-from-query-results/>"
  in the MongoDB documentation for details.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>
* C<sort> – an L<ordered document|/Ordered document> defining the order in
  which to return matching documents.  See docs for
  L<$orderby|http://docs.mongodb.org/manual/reference/operator/meta/orderby/>.

=cut

sub find_one_and_delete {
    MongoDB::UsageError->throw("filter argument must be a reference")
      unless ref( $_[1] );

    my ( $self, $filter, $options ) = @_;
    $options ||= {};

    # rename projection -> fields
    $options->{fields} = delete $options->{projection} if exists $options->{projection};

    # possibly fallback to default maxTimeMS
    if ( ! exists $options->{maxTimeMS} && $self->max_time_ms ) {
        $options->{maxTimeMS} = $self->max_time_ms;
    }

    my $session = $self->client->_get_session_from_hashref( $options );

    # coerce to IxHash
    __ixhash($options, 'sort');

    my $op = MongoDB::Op::_FindAndDelete->_new(
        %{ $_[0]->_op_args },
        filter        => $filter,
        options       => $options,
        session       => $session,
    );

    return $op->_should_use_acknowledged_write
      ? $self->client->send_retryable_write_op( $op )
      : $self->client->send_write_op( $op );
}

=method find_one_and_replace

    $doc = $coll->find_one_and_replace( $filter, $replacement );
    $doc = $coll->find_one_and_replace( $filter, $replacement, $options );

Given a L<filter expression|/Filter expression> and a replacement document,
this replaces a document from the database and returns it as it was either
right before or right after the replacement.  The default is 'before'.

The replacement document must not have any field-update operators in it (e.g.
C<$set>).

A hash reference of options may be provided. Valid keys include:

=for :list
* C<bypassDocumentValidation> - skips document validation, if enabled; this
  is ignored for MongoDB servers older than version 3.2.
* C<collation> - a L<document|/Document> defining the collation for this operation.
  See docs for the format of the collation document here:
  L<https://docs.mongodb.com/master/reference/collation/>.
* C<maxTimeMS> – the maximum amount of time in milliseconds to allow the
  command to run.
* C<projection> - a hash reference defining fields to return. See "L<limit
  fields to
  return|http://docs.mongodb.org/manual/tutorial/project-fields-from-query-results/>"
  in the MongoDB documentation for details.
* C<returnDocument> – either the string C<'before'> or C<'after'>, to indicate
  whether the returned document should be the one before or after replacement.
  The default is C<'before'>.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>
* C<sort> – an L<ordered document|/Ordered document> defining the order in
  which to return matching documents.  See docs for
  L<$orderby|http://docs.mongodb.org/manual/reference/operator/meta/orderby/>.
* C<upsert> – defaults to false; if true, a new document will be added if one
  is not found

=cut

sub find_one_and_replace {
    MongoDB::UsageError->throw("filter and replace arguments must be references")
      unless ref( $_[1] ) && ref( $_[2] );

    my ( $self, $filter, $replacement, $options ) = @_;
    $options->{is_replace} = 1;
    return $self->_find_one_and_update_or_replace($filter, $replacement, $options);
}

=method find_one_and_update

    $doc = $coll->find_one_and_update( $filter, $update );
    $doc = $coll->find_one_and_update( $filter, $update, $options );

Given a L<filter expression|/Filter expression> and a document of update
operators, this updates a single document and returns it as it was either right
before or right after the update.  The default is 'before'.

The update document must contain only field-update operators (e.g. C<$set>).

A hash reference of options may be provided. Valid keys include:

=for :list
* C<arrayFilters> - An array of filter documents that determines which array
  elements to modify for an update operation on an array field. Only available
  for MongoDB servers of version 3.6+.
* C<bypassDocumentValidation> - skips document validation, if enabled; this
  is ignored for MongoDB servers older than version 3.2.
* C<collation> - a L<document|/Document> defining the collation for this operation.
  See docs for the format of the collation document here:
  L<https://docs.mongodb.com/master/reference/collation/>.
* C<maxTimeMS> – the maximum amount of time in milliseconds to allow the
  command to run.  (Note, this will be ignored for servers before version 2.6.)
* C<projection> - a hash reference defining fields to return. See "L<limit
  fields to
  return|http://docs.mongodb.org/manual/tutorial/project-fields-from-query-results/>"
  in the MongoDB documentation for details.
* C<returnDocument> – either the string C<'before'> or C<'after'>, to indicate
  whether the returned document should be the one before or after replacement.
  The default is C<'before'>.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>
* C<sort> – an L<ordered document|/Ordered document> defining the order in
  which to return matching documents.  See docs for
  L<$orderby|http://docs.mongodb.org/manual/reference/operator/meta/orderby/>.
* C<upsert> – defaults to false; if true, a new document will be added if one
  is not found

=cut

my $foau_args;
sub find_one_and_update {
    MongoDB::UsageError->throw("filter and update arguments must be references")
      unless ref( $_[1] ) && ref( $_[2] );

    my ( $self, $filter, $update, $options ) = @_;
    $options->{is_replace} = 0;
    return $self->_find_one_and_update_or_replace($filter, $update, $options);
}

=method watch

Watches for changes on this collection-

Perform an aggregation with an implicit initial C<$changeStream> stage
and returns a L<MongoDB::ChangeStream> result which can be used to
iterate over the changes in the collection. This functionality is
available since MongoDB 3.6.

    my $stream = $collection->watch();
    my $stream = $collection->watch( \@pipeline );
    my $stream = $collection->watch( \@pipeline, \%options );

    while (1) {

        # This inner loop will only run until no more changes are
        # available.
        while (my $change = $stream->next) {
            # process $change
        }
    }

The returned stream will not block forever waiting for changes. If you
want to respond to changes over a longer time use C<maxAwaitTimeMS> and
regularly call C<next> in a loop.

B<Note>: Using this helper method is preferred to manually aggregating
with a C<$changeStream> stage, since it will automatically resume when
the connection was terminated.

The optional first argument must be an array-ref of
L<aggregation pipeline|http://docs.mongodb.org/manual/core/aggregation-pipeline/>
documents. Each pipeline document must be a hash reference. Not all
pipeline stages are supported after C<$changeStream>.

The optional second argument is a hash reference with options:

=for :list
* C<fullDocument> - The fullDocument to pass as an option to the
  C<$changeStream> stage. Allowed values: C<default>, C<updateLookup>.
  Defaults to C<default>.  When set to C<updateLookup>, the change
  notification for partial updates will include both a delta describing the
  changes to the document, as well as a copy of the entire document that
  was changed from some time after the change occurred.
* C<resumeAfter> - The logical starting point for this change stream.
  This value can be obtained from the C<_id> field of a document returned
  by L<MongoDB::ChangeStream/next>. Cannot be specified together with
  C<startAtOperationTime>
* C<maxAwaitTimeMS> - The maximum number of milliseconds for the server
  to wait before responding.
* C<startAtOperationTime> - A L<BSON::Timestamp> specifying at what point
  in time changes will start being watched. Cannot be specified together
  with C<resumeAfter>. Plain values will be coerced to L<BSON::Timestamp>
  objects.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>

See L</aggregate> for more available options.

See the L<manual section on Change Streams|https://docs.mongodb.com/manual/changeStreams/>
for general usage information on change streams.

See the L<Change Streams specification|https://github.com/mongodb/specifications/blob/master/source/change-streams.rst>
for details on change streams.

=cut

sub watch {
    my ( $self, $pipeline, $options ) = @_;

    $pipeline ||= [];
    $options ||= {};

    my $session = $self->client->_get_session_from_hashref( $options );

    return MongoDB::ChangeStream->new(
        exists($options->{startAtOperationTime})
            ? (start_at_operation_time => delete $options->{startAtOperationTime})
            : (),
        exists($options->{fullDocument})
            ? (full_document => delete $options->{fullDocument})
            : (full_document => 'default'),
        exists($options->{resumeAfter})
            ? (resume_after => delete $options->{resumeAfter})
            : (),
        exists($options->{startAfter})
            ? (start_after => delete $options->{startAfter})
            : (),
        exists($options->{maxAwaitTimeMS})
            ? (max_await_time_ms => delete $options->{maxAwaitTimeMS})
            : (),
        client => $self->client,
        pipeline => $pipeline,
        session => $session,
        options => $options,
        op_args => $self->_op_args,
    );
}

=method aggregate

    @pipeline = (
        { '$group' => { _id => '$state,' totalPop => { '$sum' => '$pop' } } },
        { '$match' => { totalPop => { '$gte' => 10 * 1000 * 1000 } } }
    );

    $result = $collection->aggregate( \@pipeline );
    $result = $collection->aggregate( \@pipeline, $options );

Runs a query using the MongoDB 2.2+ aggregation framework and returns a
L<MongoDB::QueryResult> object.

The first argument must be an array-ref of L<aggregation
pipeline|http://docs.mongodb.org/manual/core/aggregation-pipeline/> documents.
Each pipeline document must be a hash reference.

B<Note>: Some pipeline documents have ordered arguments, such as C<$sort>.
Be sure to provide these argument using L<Tie::IxHash>.  E.g.:

    { '$sort' => Tie::IxHash->new( age => -1, posts => 1 ) }

A hash reference of options may be provided. Valid keys include:

=for :list
* C<allowDiskUse> – if, true enables writing to temporary files.
* C<batchSize> – the number of documents to return per batch.
* C<bypassDocumentValidation> - skips document validation, if enabled.
  (Note, this will be ignored for servers before version 3.2.)
* C<collation> - a L<document|/Document> defining the collation for this operation.
  See docs for the format of the collation document here:
  L<https://docs.mongodb.com/master/reference/collation/>.
* C<explain> – if true, return a single document with execution information.
* C<maxTimeMS> – the maximum amount of time in milliseconds to allow the
  command to run.  (Note, this will be ignored for servers before version 2.6.)
* C<hint> - An index to use for this aggregation. (Only compatible with servers
  above version 3.6.) For more information, see the other aggregate options here:
  L<https://docs.mongodb.com/manual/reference/command/aggregate/index.html>
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>

B<Note> MongoDB 2.6+ added the '$out' pipeline operator.  If this operator is
used to write aggregation results directly to a collection, an empty result
will be returned. Create a new collection> object to query the generated result
collection.  When C<$out> is used, the command is treated as a write operation
and read preference is ignored.

See L<Aggregation|http://docs.mongodb.org/manual/aggregation/> in the MongoDB manual
for more information on how to construct aggregation queries.

B<Note> The use of aggregation cursors is automatic based on your server
version.  However, if migrating a sharded cluster from MongoDB 2.4 to 2.6
or later, you must upgrade your mongod servers first before your mongos
routers or aggregation queries will fail.  As a workaround, you may
pass C<< cursor => undef >> as an option.

=cut

my $aggregate_args;
sub aggregate {
    MongoDB::UsageError->throw("pipeline argument must be an array reference")
      unless ref( $_[1] ) eq 'ARRAY';

    my ( $self, $pipeline, $options ) = @_;
    $options ||= {};

    my $session = $self->client->_get_session_from_hashref( $options );

    # boolify some options
    for my $k (qw/allowDiskUse explain/) {
        $options->{$k} = ( $options->{$k} ? true : false ) if exists $options->{$k};
    }

    # possibly fallback to default maxTimeMS
    if ( ! exists $options->{maxTimeMS} && $self->max_time_ms ) {
        $options->{maxTimeMS} = $self->max_time_ms;
    }

    # string is OK so we check ref, not just exists
    __ixhash( $options, 'hint' ) if ref $options->{hint};

    # read preferences are ignored if the last stage is $out
    my $last_op = '';
    # If $pipeline is an empty array, this can explode
    if ( scalar( @$pipeline ) > 0 ) { ($last_op) = keys %{ $pipeline->[-1] } };
    my $has_out = !!($last_op =~ m/\$out|\$merge/);

    my $op = MongoDB::Op::_Aggregate->_new(
        pipeline     => $pipeline,
        options      => $options,
        read_concern => $self->read_concern,
        has_out      => $has_out,
        exists($options->{maxAwaitTimeMS})
            ? (maxAwaitTimeMS => delete $options->{maxAwaitTimeMS})
            : (),
        session      => $session,
        %{ $self->_op_args },
    );

    return $has_out ?
        $self->client->send_read_op($op)
        : $self->client->send_retryable_read_op($op);
}

=method count_documents

    $count = $coll->count_documents( $filter );
    $count = $coll->count_documents( $filter, $options );

Returns a count of documents matching a L<filter expression|/Filter expression>.
To return a count of all documents, use an empty hash reference as the filter.

B<NOTE>: this may result in a scan of all documents in the collection.
For a fast count of the total documents in a collection see
L</estimated_document_count> instead.

A hash reference of options may be provided. Valid keys include:

=for :list
* C<collation> - a L<document|/Document> defining the collation for this operation.
  See docs for the format of the collation document here:
  L<https://docs.mongodb.com/master/reference/collation/>.
* C<hint> – specify an index to use; must be a string, array reference,
  hash reference or L<Tie::IxHash> object. (Requires server version 3.6 or later.)
* C<limit> – the maximum number of documents to count.
* C<maxTimeMS> – the maximum amount of time in milliseconds to allow the
  command to run.  (Note, this will be ignored for servers before version 2.6.)
* C<skip> – the number of documents to skip before counting documents.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>

B<NOTE>: When upgrading from the deprecated C<count> method, some legacy
operators are not supported and must be replaced:

    +-------------+--------------------------------+
    | Legacy      | Modern Replacement             |
    +=============+================================+
    | $where      | $expr (Requires MongoDB 3.6+)  |
    +-------------+--------------------------------+
    | $near       | $geoWithin with $center        |
    +-------------+--------------------------------+
    | $nearSphere | $geoWithin with $centerSphere  |
    +-------------+--------------------------------+

=cut

sub count_documents {
    my ( $self, $filter, $options ) = @_;
    MongoDB::UsageError->throw("filter argument must be a reference")
      unless ref( $filter );

    $options ||= {};

    my $pipeline = [ { '$match' => $filter } ];

    if ( exists $options->{skip} ) {
        push @$pipeline, { '$skip', delete $options->{skip} };
    }

    if ( exists $options->{limit} ) {
        push @$pipeline, { '$limit', delete $options->{limit} };
    }

    push @$pipeline, { '$group' => { '_id' => 1, 'n' => { '$sum' => 1 } } };

    # possibly fallback to default maxTimeMS
    if ( ! exists $options->{maxTimeMS} && $self->max_time_ms ) {
        $options->{maxTimeMS} = $self->max_time_ms;
    }

    # string is OK so we check ref, not just exists
    __ixhash($options, 'hint') if ref $options->{hint};

    my $res = $self->aggregate($pipeline, $options)->next;

    return $res->{n} // 0;
}

=method estimated_document_count

    $count = $coll->estimated_document_count();
    $count = $coll->estimated_document_count($options);

Returns an estimated count of documents based on collection metadata.

B<NOTE>: this method does not support sessions or transactions.

A hash reference of options may be provided. Valid keys include:

=for :list
* C<maxTimeMS> – the maximum amount of time in milliseconds to allow the
  command to run.  (Note, this will be ignored for servers before version 2.6.)

=cut

sub estimated_document_count {
    my ( $self, $options ) = @_;
    $options ||= {};

    # only maxTimeMS is supported
    my $filtered = {
        ( exists $options->{maxTimeMS} ? ( maxTimeMS => $options->{maxTimeMS} ) : () )
    };

    # possibly fallback to default maxTimeMS
    if ( ! exists $filtered->{maxTimeMS} && $self->max_time_ms ) {
        $filtered->{maxTimeMS} = $self->max_time_ms;
    }

    # XXX replace this with direct use of a command op?
    my $op = MongoDB::Op::_Count->_new(
        options         => $filtered,
        filter          => undef,
        session         => $self->client->_maybe_get_implicit_session,
        %{ $self->_op_args },
    );

    my $res = $self->client->send_retryable_read_op($op);

    return $res->{n} // 0;
}

=method distinct

    $result = $coll->distinct( $fieldname );
    $result = $coll->distinct( $fieldname, $filter );
    $result = $coll->distinct( $fieldname, $filter, $options );

Returns a L<MongoDB::QueryResult> object that will provide distinct values for
a specified field name.

The query may be limited by an optional L<filter expression|/Filter
expression>.

A hash reference of options may be provided. Valid keys include:

=for :list
* C<collation> - a L<document|/Document> defining the collation for this operation.
  See docs for the format of the collation document here:
  L<https://docs.mongodb.com/master/reference/collation/>.
* C<maxTimeMS> – the maximum amount of time in milliseconds to allow the
  command to run.  (Note, this will be ignored for servers before version 2.6.)
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>

See documentation for the L<distinct
command|http://docs.mongodb.org/manual/reference/command/distinct/> for
details.

=cut

my $distinct_args;

sub distinct {
    MongoDB::UsageError->throw("fieldname argument is required")
      unless defined( $_[1] );

    my ( $self, $fieldname, $filter, $options ) = @_;
    $filter ||= {};
    $options ||= {};

    # possibly fallback to default maxTimeMS
    if ( ! exists $options->{maxTimeMS} && $self->max_time_ms ) {
        $options->{maxTimeMS} = $self->max_time_ms;
    }

    my $session = $self->client->_get_session_from_hashref( $options );

    my $op = MongoDB::Op::_Distinct->_new(
        fieldname       => $fieldname,
        filter          => $filter,
        options         => $options,
        session         => $session,
        %{ $self->_op_args },
    );

    return $self->client->send_retryable_read_op($op);
}

=method rename

    $newcollection = $collection->rename("mynewcollection");

Renames the collection.  If a collection already exists with the new collection
name, this method will throw an exception.

A hashref of options may be provided.

Valid options include:

=for :list
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>

It returns a new L<MongoDB::Collection> object corresponding to the renamed
collection.

=cut

sub rename {
    my ( $self, $new_name, $options ) = @_;

    my $session = $self->client->_get_session_from_hashref( $options );

    my $op = MongoDB::Op::_RenameCollection->_new(
        src_ns => $self->full_name,
        dst_ns => join( ".", $self->database->name, $new_name ),
        options => $options,
        session => $session,
        %{ $self->_op_args },
    );

    $self->client->send_write_op($op);

    return $self->database->get_collection($new_name);
}

=method drop

    $collection->drop;

Deletes a collection as well as all of its indexes.

=cut

sub drop {
    my ( $self, $options ) = @_;

    my $session = $self->client->_get_session_from_hashref( $options );

    $self->client->send_write_op(
        MongoDB::Op::_DropCollection->_new(
            options => $options,
            session => $session,
            %{ $self->_op_args },
        )
    );

    return;
}

=method ordered_bulk

    $bulk = $coll->ordered_bulk;
    $bulk->insert_one( $doc1 );
    $bulk->insert_one( $doc2 );
    ...
    $result = $bulk->execute;

Returns a L<MongoDB::BulkWrite> object to group write operations into fewer network
round-trips.  This method creates an B<ordered> operation, where operations halt after
the first error. See L<MongoDB::BulkWrite> for more details.

The method C<initialize_ordered_bulk_op> may be used as an alias.

A hash reference of options may be provided.

Valid options include:

=for :list
* C<bypassDocumentValidation> - skips document validation, if enabled; this
  is ignored for MongoDB servers older than version 3.2.

=cut

sub initialize_ordered_bulk_op {
    my ($self, $args) = @_;
    $args ||= {};
    return MongoDB::BulkWrite->new( %$args, collection => $self, ordered => 1, );
}

=method unordered_bulk

This method works just like L</ordered_bulk> except that the order that
operations are sent to the database is not guaranteed and errors do not halt processing.
See L<MongoDB::BulkWrite> for more details.

The method C<initialize_unordered_bulk_op> may be used as an alias.

A hash reference of options may be provided.

Valid options include:

=for :list
* C<bypassDocumentValidation> - skips document validation, if enabled; this
  is ignored for MongoDB servers older than version 3.2.

=cut

sub initialize_unordered_bulk_op {
    my ($self, $args) = @_;
    $args ||= {};
    return MongoDB::BulkWrite->new( %$args, collection => $self, ordered => 0 );
}

=method bulk_write

    $res = $coll->bulk_write( [ @requests ], $options )

This method provides syntactic sugar to construct and execute a bulk operation
directly, without using C<initialize_ordered_bulk> or
C<initialize_unordered_bulk> to generate a L<MongoDB::BulkWrite> object and
then calling methods on it.  It returns a L<MongoDB::BulkWriteResponse> object
just like the L<MongoDB::BulkWrite execute|MongoDB::BulkWrite/execute> method.

The first argument must be an array reference of requests.  Requests consist
of pairs of a MongoDB::Collection write method name (e.g. C<insert_one>,
C<delete_many>) and an array reference of arguments to the corresponding
method name.  They may be given as pairs, or as hash or array
references:

    # pairs -- most efficient
    @requests = (
        insert_one  => [ { x => 1 } ],
        replace_one => [ { x => 1 }, { x => 4 } ],
        delete_one  => [ { x => 4 } ],
        update_many => [ { x => { '$gt' => 5 } }, { '$inc' => { x => 1 } } ],
    );

    # hash references
    @requests = (
        { insert_one  => [ { x => 1 } ] },
        { replace_one => [ { x => 1 }, { x => 4 } ] },
        { delete_one  => [ { x => 4 } ] },
        { update_many => [ { x => { '$gt' => 5 } }, { '$inc' => { x => 1 } } ] },
    );

    # array references
    @requests = (
        [ insert_one  => [ { x => 1 } ] ],
        [ replace_one => [ { x => 1 }, { x => 4 } ] ],
        [ delete_one  => [ { x => 4 } ] ],
        [ update_many => [ { x => { '$gt' => 5 } }, { '$inc' => { x => 1 } } ] ],
    );

Valid method names include C<insert_one>, C<insert_many>, C<delete_one>,
C<delete_many> C<replace_one>, C<update_one>, C<update_many>.

An optional hash reference of options may be provided.

Valid options include:

=for :list
* C<bypassDocumentValidation> - skips document validation, if enabled; this
  is ignored for MongoDB servers older than version 3.2.
* C<ordered> – when true, the bulk operation is executed like
  L</initialize_ordered_bulk>. When false, the bulk operation is executed
  like L</initialize_unordered_bulk>.  The default is true.
* C<session> - the session to use for these operations. If not supplied, will
  use an implicit session. For more information see L<MongoDB::ClientSession>

See L<MongoDB::BulkWrite> for more details on bulk writes.  Be advised that
the legacy Bulk API method names differ slightly from MongoDB::Collection
method names.

=cut

sub bulk_write {
    my ( $self, $requests, $options ) = @_;

    MongoDB::UsageError->throw("requests not an array reference")
      unless ref $requests eq 'ARRAY';
    MongoDB::UsageError->throw("empty request list") unless @$requests;
    MongoDB::UsageError->throw("options not a hash reference")
      if defined($options) && ref($options) ne 'HASH';

    $options ||= {};

    my $ordered = exists $options->{ordered} ? delete $options->{ordered} : 1;

    my $session = $self->client->_get_session_from_hashref( $options );

    my $bulk =
      $ordered ? $self->ordered_bulk($options) : $self->unordered_bulk($options);

    my $i = 0;

    while ( $i <= $#$requests ) {
        my ( $method, $args );

        # pull off document or pair
        if ( my $type = ref $requests->[$i] ) {
            if ( $type eq 'ARRAY' ) {
                ( $method, $args ) = @{ $requests->[$i] };
            }
            elsif ( $type eq 'HASH' ) {
                ( $method, $args ) = %{ $requests->[$i] };
            }
            else {
                MongoDB::UsageError->throw("$requests->[$i] is not a hash or array reference");
            }
            $i++;
        }
        else {
            ( $method, $args ) = @{$requests}[ $i, $i + 1 ];
            $i += 2;
        }

        MongoDB::UsageError->throw("'$method' requires an array reference of arguments")
          unless ref($args) eq 'ARRAY';

        # handle inserts
        if ( $method eq 'insert_one' || $method eq 'insert_many' ) {
            $bulk->insert_one($_) for @$args;
        }
        else {
            my ( $filter, $arg2, $arg3 ) = @$args;

            my $is_delete = $method eq 'delete_one' || $method eq 'delete_many';
            my $update_doc = $is_delete ? undef : $arg2;
            my $opts       = $is_delete ? $arg2 : $arg3;

            my $view = $bulk->find($filter);

            # set collation
            $view = $view->collation( $opts->{collation} ) if $opts && $opts->{collation};

            # handle deletes
            if ( $method eq 'delete_one' ) {
                $view->delete_one;
                next;
            }
            elsif ( $method eq 'delete_many' ) {
                $view->delete_many;
                $bulk->_retryable( 0 );
                next;
            }

            # updates might be upserts
            $view = $view->upsert if $opts && $opts->{upsert};

            # handle updates
            if ( $method eq 'replace_one' ) {
                $view->replace_one($update_doc);
            }
            elsif ( $method eq 'update_one' ) {
                $view->update_one($update_doc);
            }
            elsif ( $method eq 'update_many' ) {
                $view->update_many($update_doc);
                $bulk->_retryable( 0 );
            }
            else {
                MongoDB::UsageError->throw("unknown bulk operation '$method'");
            }
        }
    }

    return $bulk->execute(
        $options->{writeConcern},
        { session => $session },
    );
}

BEGIN {
    # aliases
    no warnings 'once';
    *query = \&find;
    *ordered_bulk = \&initialize_ordered_bulk_op;
    *unordered_bulk = \&initialize_unordered_bulk_op;
}

#--------------------------------------------------------------------------#
# private methods
#--------------------------------------------------------------------------#

sub _dynamic_write_concern {
    my ( $self, $opts ) = @_;
    if ( !exists( $opts->{safe} ) || $opts->{safe} ) {
        return $self->write_concern;
    }
    else {
        return MongoDB::WriteConcern->new( w => 0 );
    }
}

sub _find_one_and_update_or_replace {
    my ($self, $filter, $modifier, $options) = @_;
    $options ||= {};
    my $is_replace = delete $options->{is_replace};

    # rename projection -> fields
    $options->{fields} = delete $options->{projection} if exists $options->{projection};

    # possibly fallback to default maxTimeMS
    if ( ! exists $options->{maxTimeMS} && $self->max_time_ms ) {
        $options->{maxTimeMS} = $self->max_time_ms;
    }

    # coerce to IxHash
    __ixhash($options, 'sort');

    # returnDocument ('before'|'after') maps to field 'new'
    if ( exists $options->{returnDocument} ) {
        MongoDB::UsageError->throw("Invalid returnDocument parameter '$options->{returnDocument}'")
            unless $options->{returnDocument} =~ /^(?:before|after)$/;
        $options->{new} = delete( $options->{returnDocument} ) eq 'after' ? true : false;
    }

    # pass separately for MongoDB::Role::_BypassValidation
    my $bypass = delete $options->{bypassDocumentValidation};

    my $session = $self->client->_get_session_from_hashref( $options );

    my $op = MongoDB::Op::_FindAndUpdate->_new(
        filter         => $filter,
        modifier       => $modifier,
        options        => $options,
        bypassDocumentValidation => $bypass,
        session        => $session,
        is_replace     => $is_replace,
        %{ $self->_op_args },
    );

    return $op->_should_use_acknowledged_write
      ? $self->client->send_retryable_write_op( $op )
      : $self->client->send_write_op( $op );
}

#--------------------------------------------------------------------------#
# Deprecated functions
#--------------------------------------------------------------------------#

sub parallel_scan {
    my ( $self, $num_cursors, $options ) = @_;
    $self->_warn_deprecated_method('parallel_scan' => []);

    unless (defined $num_cursors && $num_cursors == int($num_cursors)
        && $num_cursors > 0 && $num_cursors <= 10000
    ) {
        MongoDB::UsageError->throw( "first argument to parallel_scan must be a positive integer between 1 and 10000" )
    }
    $options = ref $options eq 'HASH' ? $options : { };

    my $op = MongoDB::Op::_ParallelScan->_new(
        %{ $self->_op_args },
        num_cursors     => $num_cursors,
        options         => $options,
    );

    my $result = $self->client->send_read_op( $op );
    my $response = $result->output;

    MongoDB::UsageError->throw("No cursors returned")
        unless $response->{cursors} && ref $response->{cursors} eq 'ARRAY';

    my @cursors;
    for my $c ( map { $_->{cursor} } @{$response->{cursors}} ) {
        my $batch = $c->{firstBatch};
        my $qr = MongoDB::QueryResult->_new(
            _client       => $self->client,
            _address      => $result->address,
            _full_name    => $c->{ns},
            _bson_codec   => $self->bson_codec,
            _batch_size   => scalar @$batch,
            _cursor_at    => 0,
            _limit        => 0,
            _cursor_id    => $c->{id},
            _cursor_start => 0,
            _cursor_flags => {},
            _cursor_num   => scalar @$batch,
            _docs         => $batch,
        );
        push @cursors, $qr;
    }

    return @cursors;
}

sub count {
    my ( $self, $filter, $options ) = @_;

    $self->_warn_deprecated_method( 'count' => [qw/count_documents estimated_document_count/] );

    $filter  ||= {};
    $options ||= {};

    # possibly fallback to default maxTimeMS
    if ( !exists $options->{maxTimeMS} && $self->max_time_ms ) {
        $options->{maxTimeMS} = $self->max_time_ms;
    }

    my $session = $self->client->_get_session_from_hashref($options);

    # string is OK so we check ref, not just exists
    __ixhash( $options, 'hint' ) if ref $options->{hint};

    my $op = MongoDB::Op::_Count->_new(
        options => $options,
        filter  => $filter,
        session => $session,
        %{ $self->_op_args },
    );

    my $res = $self->client->send_read_op($op);

    return $res->{n};
}

#--------------------------------------------------------------------------#
# utility function
#--------------------------------------------------------------------------#

# utility function to coerce array/hashref to Tie::Ixhash
sub __ixhash {
    my ($hash, $key) = @_;
    return unless exists $hash->{$key};
    my $ref = $hash->{$key};
    my $type = ref($ref);
    return if $type eq 'Tie::IxHash';
    if ( $type eq 'HASH' ) {
        $hash->{$key} = Tie::IxHash->new( %$ref );
    }
    elsif ( $type eq 'ARRAY' || $type eq 'BSON::Doc' ) {
        $hash->{$key} = Tie::IxHash->new( @$ref );
    }
    else {
        MongoDB::UsageError->throw("Can't convert $type to a Tie::IxHash");
    }
    return;
}

# we have a private _run_command rather than using the 'database' attribute
# so that we're using our BSON codec and not the source database one
sub _run_command {
    my ( $self, $command ) = @_;

    my $op = MongoDB::Op::_Command->_new(
        db_name             => $self->database->name,
        query               => $command,
        query_flags         => {},
        bson_codec          => $self->bson_codec,
        monitoring_callback => $self->client->monitoring_callback,
    );

    my $obj = $self->client->send_retryable_read_op($op);

    return $obj->output;
}

1;

__END__

=pod

=for Pod::Coverage
count
initialize_ordered_bulk_op
initialize_unordered_bulk_op
batch_insert
find_and_modify
insert
query
remove
update

=head1 SYNOPSIS

    # get a Collection via the Database object
    $coll = $db->get_collection("people");

    # insert a document
    $coll->insert_one( { name => "John Doe", age => 42 } );

    # insert one or more documents
    $coll->insert_many( \@documents );

    # delete a document
    $coll->delete_one( { name => "John Doe" } );

    # update a document
    $coll->update_one( { name => "John Doe" }, { '$inc' => { age => 1 } } );

    # find a single document
    $doc = $coll->find_one( { name => "John Doe" } )

    # Get a MongoDB::Cursor for a query
    $cursor = $coll->find( { age => 42 } );

    # Cursor iteration
    while ( my $doc = $cursor->next ) {
        ...
    }

=head1 DESCRIPTION

This class models a MongoDB collection and provides an API for interacting
with it.

Generally, you never construct one of these directly with C<new>.  Instead, you
call C<get_collection> on a L<MongoDB::Database> object.

=head1 USAGE

=head2 Error handling

Unless otherwise explicitly documented, all methods throw exceptions if
an error occurs.  The error types are documented in L<MongoDB::Error>.

To catch and handle errors, the L<Try::Tiny> and L<Safe::Isa> modules
are recommended:

    use Try::Tiny;
    use Safe::Isa; # provides $_isa

    try {
        $coll->insert_one( $doc )
    }
    catch {
        if ( $_->$_isa("MongoDB::DuplicateKeyError" ) {
            ...
        }
        else {
            ...
        }
    };

To retry failures automatically, consider using L<Try::Tiny::Retry>.

=head2 Transactions

To conduct operations in a transactions, get a L<MongoDB::ClientSession>
from L<MongoDB::MongoClient/start_session>.  Start the transaction on the
session using C<start_transaction> and pass the session as an option to all
operations.  Then call C<commit_transaction> or C<abort_transaction> on the
session.  See the L<MongoDB::ClientSession> for options and usage details.

For detailed instructions on using transactions with MongoDB, see the
MongoDB manual page:
L<Transactions|https://docs.mongodb.com/master/core/transactions>.

=head2 Terminology

=head3 Document

A collection of key-value pairs.  A Perl hash is a document.  Array
references with an even number of elements and L<Tie::IxHash> objects may also
be used as documents.

=head3 Ordered document

Many MongoDB::Collection method parameters or options require an B<ordered
document>: an ordered list of key/value pairs.  Perl's hashes are B<not>
ordered and since Perl v5.18 are guaranteed to have random order.  Therefore,
when an ordered document is called for, you may use an array reference of pairs
or a L<Tie::IxHash> object.  You may use a hash reference if there is only
one key/value pair.

=head3 Filter expression

A filter expression provides the L<query
criteria|http://docs.mongodb.org/manual/tutorial/query-documents/> to select a
document for deletion.  It must be an L</Ordered document>.

=cut

# vim: set ts=4 sts=4 sw=4 et tw=75:
