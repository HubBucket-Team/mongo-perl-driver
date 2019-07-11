#  Copyright 2018 - present MongoDB, Inc.
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
use JSON::MaybeXS qw( is_bool decode_json );
use Path::Tiny 0.054; # basename with suffix
use Test::More 0.96;
use Test::Deep;
use Math::BigInt;
use Storable qw( dclone );

use utf8;

use MongoDB;
use MongoDB::_Types qw/
    to_IxHash
/;
use MongoDB::Error;

use lib "t/lib";

use if $ENV{MONGOVERBOSE}, qw/Log::Any::Adapter Stderr/;

use MongoDBTest qw/
    build_client
    get_test_db
    server_version
    server_type
    clear_testdbs
    get_unique_collection
    skip_unless_mongod
    skip_unless_failpoints_available
    set_failpoint
    clear_failpoint
    skip_unless_transactions
/;
use MongoDBSpecTest qw/
    maybe_skip_multiple_mongos
    foreach_spec_test
/;

skip_unless_mongod();
skip_unless_failpoints_available();
skip_unless_transactions();

my @events;

sub clear_events { @events = () }
sub event_count { scalar @events }
# Must use dclone, as was causing action at a distance for binc on txn number
sub event_cb { push @events, dclone $_[0] }
# disabling wtimeout default of 5000 in MongoDBTest
my $conn           = build_client( wtimeout => undef );
my $server_version = server_version($conn);
my $server_type    = server_type($conn);

# defines which argument hash fields become positional arguments
my %method_args = (
    insert_one  => [qw( document )],
    insert_many => [qw( documents )],
    delete_one  => [qw( filter )],
    delete_many => [qw( filter )],
    replace_one => [qw( filter replacement )],
    update_one  => [qw( filter update )],
    update_many => [qw( filter update )],
    find        => [qw( filter )],
    count       => [qw( filter )],
    count_documents => [qw( filter )],
    bulk_write  => [qw( requests )],
    find_one_and_update => [qw( filter update )],
    find_one_and_replace => [qw( filter replacement )],
    find_one_and_delete => [qw( filter )],
    run_command => [qw( command readPreference )],
    aggregate   => [qw( pipeline )],
    distinct    => [qw( fieldName filter )],
);

my $dir = path("t/data/transactions");
foreach_spec_test($dir, $conn, sub {
    my ($test, $plan) = @_;
    my $test_db_name = $plan->{database_name};
    my $test_coll_name = $plan->{collection_name};

    my $description = $test->{description};
    local $TODO = 'does a run_command read_preference count as a user configurable read_preference?' if $description =~ /explicit secondary read preference/;

    subtest $description => sub {
        plan skip_all => $test->{skipReason} if $test->{skipReason};
        maybe_skip_multiple_mongos( $conn, $test->{useMultipleMongoses} );

        #my $client = build_client( wtimeout => undef );

        # Kills its own session as well
        eval { $conn->send_admin_command([ killAllSessions => [] ]) };
        my $test_db = $conn->get_database( $test_db_name );

        # We crank wtimeout up to 10 seconds to help reduce
        # replication timeouts in testing
        my $test_coll = $test_db->get_collection(
            $test_coll_name,
            { write_concern => { w => 'majority', wtimeout => 10000 } }
        );
        $test_coll->drop;

        # Drop first to make sure its clear for the next test.
        # MongoDB::Collection doesnt have a ->create option so done as
        # a seperate step.
        $test_db->run_command([ create => $test_coll_name ]);

        if ( scalar @{ $plan->{data} } > 0 ) {
            $test_coll->insert_many( $plan->{data} );
        }

        # PERL-1083 Work around StaleDbVersion issue. Guarded against possible errors
        if ( $description eq 'distinct' && $conn->_topology->type eq 'Sharded' ) {
            eval { $test_coll->distinct( '_id' ) };
        }

        set_failpoint( $conn, $test->{failPoint} );
        run_test( $test_db_name, $test_coll_name, $test );
        clear_failpoint( $conn, $test->{failPoint} );

        if ( defined $test->{outcome}{collection}{data} ) {
            # Need to use a specific read concern and read preference to check
            my $outcome_coll = $test_coll->clone(
                read_preference => 'primary',
                read_concern => 'local',
            );
            my @outcome = $outcome_coll->find()->all;
            cmp_deeply( \@outcome, $test->{outcome}{collection}{data}, 'outcome as expected' )
        }
    };
});

sub to_snake_case {
    my $t = shift;
    $t =~ s{([A-Z])}{_\L$1}g;
    return $t;
}

sub remap_hash_to_snake_case {
    my $hash = shift;
    return {
        map {
            my $k = to_snake_case( $_ );
            $k => $hash->{ $_ }
        } keys %$hash
    }
}

# Global so can get values when checking sessions
my %sessions;

sub run_test {
    my ( $test_db_name, $test_coll_name, $test ) = @_;

    my $client_options = $test->{clientOptions} // {};
    $client_options = remap_hash_to_snake_case( $client_options );

    # TODO Why is read_preference a read only mutator????....
    if ( exists $client_options->{read_preference} ) {
        $client_options->{read_pref_mode} = delete $client_options->{read_preference};
    }

    my $client = build_client(
      monitoring_callback => \&event_cb,
      # Explicitly disable retry_writes for the test, as they change the
      # txnNumber counting used in the test specs.
      retry_writes => 0,
      wtimeout => undef,
      %$client_options
    );

    my $session_options = $test->{sessionOptions} // {};

    %sessions = (
      session0 => $client->start_session( $session_options->{session0} ),
      session1 => $client->start_session( $session_options->{session1} ),
    );
    $sessions{session0_lsid} = $sessions{session0}->session_id;
    $sessions{session1_lsid} = $sessions{session1}->session_id;

    # Force handshakes before clearing event monitoring log
    $client->topology_status( refresh => 1 );

    clear_events();
    for my $operation ( @{ $test->{operations} } ) {

        my $collection_options = $operation->{collectionOptions} // {};
        $collection_options = remap_hash_to_snake_case( $collection_options );

        my $op_result = $operation->{result};

        my $cmd = to_snake_case( $operation->{name} );
        eval {
            $sessions{ database } = $client->get_database( $test_db_name );
            $sessions{ collection } = $sessions{ database }->get_collection( $test_coll_name, $collection_options );

            # TODO count is checked specifically for errors during a transaction so warning here is not useful - we cannot change to count_documents, which is actually allowed in transactions.
            local $ENV{PERL_MONGO_NO_DEP_WARNINGS} = 1 if $cmd eq 'count';

            my $special_op = 'special_op_' . $cmd;
            if ( my $op_sub = main->can($special_op) ) {
                $op_sub->( $operation->{ arguments } );
            } elsif ( $cmd =~ /_transaction$/ ) {
                my $op_args = $operation->{arguments} // {};
                $sessions{ $operation->{object} }->$cmd( $op_args->{options} );
            } else {
                my @args = _adjust_arguments( $cmd, $operation->{arguments} );
                $args[-1]->{session} = $sessions{ $args[-1]->{session} }
                    if exists $args[-1]->{session};
                $args[-1]->{returnDocument} = lc $args[-1]->{returnDocument}
                    if exists $args[-1]->{returnDocument};

                if ( $cmd eq 'find' ) {
                    # not every find command actually has a filter
                    @args = ( undef, $args[0] )
                        if scalar( @args ) == 1;
                }
                if ( $cmd eq 'run_command' ) {
                    $args[0] = to_IxHash( $args[0] );
                    # move command to the beginning of the hash
                    my $cmd_arg = $args[0]->DELETE( $operation->{command_name} );
                    $args[0]->Unshift( $operation->{command_name}, $cmd_arg );
                    # May not have had a readPreference set
                    @args = ( $args[0], undef, $args[1] )
                        if scalar( @args ) == 2;
                }
                if ( $cmd eq 'distinct' ) {
                    @args = ( $args[0], undef, $args[1] )
                        if scalar( @args ) == 2;
                }

                # Die if this takes longer than 5 minutes
                alarm 666;
                my $object = $sessions{ $operation->{object} } || __PACKAGE__;
                my $ret = $object->$cmd( @args );
                alarm 0;
                # special case 'find' so commands are actually emitted
                my $result = $ret;
                $result = [ $ret->all ]
                    if ( grep { $cmd eq $_ } qw/ find aggregate distinct / );

                check_result_outcome( $result, $op_result )
                    if exists $operation->{result};
            }
        };
        my $err = $@;
        if ($operation->{error}) {
            ok($err);
        }
        else {
            check_error( $err, $op_result, $cmd );
        }
    }

    if ( defined $sessions{ clear_targeted_fail_point } ) {
        special_op_clear_targeted_fail_point();
    }

    $sessions{session0}->end_session;
    $sessions{session1}->end_session;

    if ( defined $test->{expectations} ) {
        check_event_expectations( _adjust_types( $test->{expectations} ) );
    }
    %sessions = ();
}

# Special Operation Types for test runner
sub special_op_targeted_fail_point {
    my ( $args ) = @_;
    return unless $conn->_topology->type eq 'Sharded';

    # session must be pinned
    special_op_assert_session_pinned( $args );

    my $session = $sessions{ $args->{ session } };
    my $failpoint = $args->{ failPoint };
    my $command = [
        configureFailPoint => $failpoint->{configureFailPoint},
        mode => $failpoint->{mode},
        defined $failpoint->{data}
          ? ( data => $failpoint->{data} )
          : (),
    ];

    $conn->_send_direct_admin_command( $session->_address, $command );

    # Store targeted fail point
    $sessions{ clear_targeted_fail_point } = {
        address   => $session->_address,
        failpoint => $failpoint,
    };
}

sub special_op_clear_targeted_fail_point {
    my $args = $sessions{ clear_targeted_fail_point };

    my $command = [
        configureFailPoint => $args->{failpoint}->{configureFailPoint},
        mode => 'off',
    ];

    $conn->_send_direct_admin_command( $args->{address}, $command );

    delete $sessions{ clear_targeted_fail_point };
}

sub special_op_assert_session_pinned {
    my ( $args ) = @_;
    return unless $conn->_topology->type eq 'Sharded';

    ok defined( $sessions{ $args->{ session } }->_address ),
        'assert session is pinned';
}

sub special_op_assert_session_unpinned {
    my ( $args ) = @_;
    return unless $conn->_topology->type eq 'Sharded';

    ok ! defined( $sessions{ $args->{ session } }->_address ),
        'assert session is unpinned';
}

sub check_error {
    my ( $err, $exp, $cmd ) = @_;

    my $expecting_error = 0;
    if ( ref( $exp ) eq 'HASH' ) {
        $expecting_error = grep {/^error/} keys %{ $exp };
    }
    if ( $err ) {
        unless ( $expecting_error ) {
            my $diag_msg = 'Not expecting error, got "' . $err->message . '"';
            fail $diag_msg;
            return;
        }

        my $err_contains        = $exp->{errorContains};
        my $err_code_name       = $exp->{errorCodeName};
        my $err_labels_contains = $exp->{errorLabelsContain};
        my $err_labels_omit     = $exp->{errorLabelsOmit};
        if ( defined $err_contains ) {
            if ($cmd eq 'count') {
                # MongoDB 4.0.7 - 4.0.9 changed the error for count in a transaction
                $err_contains .= "|Command is not supported as the first command in a transaction";
            }
            $err_contains =~ s/abortTransaction/abort_transaction/;
            $err_contains =~ s/commitTransaction/commit_transaction/;
            like $err->message, qr/$err_contains/i, 'error contains ' . $err_contains;
        }
        if ( defined $err_code_name ) {
            my $result = $err->result;
            if ( $result->isa('MongoDB::CommandResult') ) {
                is $result->output->{codeName},
                    $err_code_name,
                    'error has name ' . $err_code_name;
            }
        }
        if ( defined $err_labels_omit ) {
            for my $err_label ( @{ $err_labels_omit } ) {
                ok ! $err->has_error_label( $err_label ), 'error doesnt have label ' . $err_label;
            }
        }
        if ( defined $err_labels_omit ) {
            for my $err_label ( @{ $err_labels_contains } ) {
                ok $err->has_error_label( $err_label ), 'error has label ' . $err_label;
            }
        }
    } elsif ( $expecting_error ) {
        fail 'Expecting error, but no error found';
    } else {
        pass 'No error from command ' . $cmd;
    }
}

sub check_result_outcome {
    my ( $got, $exp ) = @_;

    if ( ref( $exp ) eq 'ARRAY' ) {
        check_array_result_outcome( $got, $exp );
    } else {
        check_hash_result_outcome( $got, $exp );
    }
}

sub check_array_result_outcome {
    my ( $got, $exp ) = @_;

    cmp_deeply $got, $exp, 'result as expected';
}

sub check_hash_result_outcome {
    my ( $got, $exp ) = @_;

    my $ok = 1;
    if ( ref $exp ne 'HASH' ) {
        is_deeply($got, $exp, "non-hash result correct");
    } else {
        for my $key ( keys %$exp ) {
            my $obj_key = to_snake_case( $key );
            next if ( $key eq 'upsertedCount' && !$got->can('upserted_count') );
            # Some results are just raw results
            if ( ref $got eq 'HASH' ) {
                $ok &&= cmp_deeply $got->{ $obj_key }, $exp->{ $key }, "$key result correct";
            } else {
                # if we got something of the wrong type, it won't have the
                # right methods and we can note that and skip.
                unless ( can_ok($got, $obj_key) ) {
                    $ok = 0;
                    next;
                }
                $ok &&= cmp_deeply $got->$obj_key, $exp->{ $key }, "$key result correct";
            }
        }
    }
    if ( !$ok ) {
        diag "GOT:\n", explain($got), "\nEXPECT:\n", explain($exp);
    }
}

# Following subs modified from monitoring_spec.t
#


# prepare collection method arguments
# adjusts data structures and extracts leading positional arguments
sub _adjust_arguments {
    my ($method, $args) = @_;
    $args = _adjust_types($args);
    my @fields = @{ $method_args{$method} || [] };
    my @field_values = map {
        my $val = delete $args->{$_};
        # bulk write is special cased to reuse argument extraction
        ($method eq 'bulk_write' and $_ eq 'requests')
            ? _adjust_bulk_write_requests($val)
            : $val;
    } @fields;

    return(
        (grep { defined } @field_values),
        scalar(keys %$args) ? $args : (),
    );
}

# prepare bulk write requests for use as argument to ->bulk_write
sub _adjust_bulk_write_requests {
    my ($requests) = @_;

    return [map {
        # Different data structure in bulk writes compared to command_monitoring
        my $name = to_snake_case( $_->{name} );
        +{ $name => [_adjust_arguments($name, $_->{arguments})] };
    } @$requests];
}

# some type transformations
# turns { '$numberLong' => $n } into 0+$n
sub _adjust_types {
    my ($value) = @_;
    if (ref $value eq 'HASH') {
        if (scalar(keys %$value) == 1) {
            my ($name, $value) = %$value;
            if ($name eq '$numberLong') {
                return 0+$value;
            }
        }
        return +{map {
            my $key = $_;
            ($key, _adjust_types($value->{$key}));
        } keys %$value};
    }
    elsif (ref $value eq 'ARRAY') {
        return [map { _adjust_types($_) } @$value];
    }
    else {
        return $value;
    }
}

# common overrides for event data expectations
sub prepare_data_spec {
    my ($spec) = @_;
    if ( ! defined $spec ) {
        return $spec;
    }
    elsif (not ref $spec) {
        if ($spec eq 'test') {
            return any(qw( test test_collection ));
        }
        if ($spec eq 'test-unacknowledged-bulk-write') {
            return code(\&_verify_is_nonempty_str);
        }
        if ($spec eq 'command-monitoring-tests.test') {
            return code(\&_verify_is_nonempty_str);
        }
        return $spec;
    }
    elsif (is_bool $spec) {
        my $specced = $spec ? 1 : 0;
        return code(sub {
            my $value = shift;
            return(0, 'expected a true boolean value')
                if $specced and not $value;
            return(0, 'expected a false boolean value')
                if $value and not $specced;
            return 1;
        });
    }
    elsif (ref $spec eq 'ARRAY') {
        return [map {
            prepare_data_spec($_)
        } @$spec];
    }
    elsif (ref $spec eq 'HASH') {
        return +{map {
            ($_, prepare_data_spec($spec->{$_}))
        } keys %$spec};
    }
    else {
        return $spec;
    }
}

sub check_event_expectations {
    my ( $expected ) = @_;
    # We only care about command_started events; also ignoring sasl* and
    # ismaster commands caused by re-negotiation after network error
    my @got = grep { ($_->{type} // '') eq 'command_started' &&
        ($_->{commandName} // '') !~ /sasl|ismaster/ } @events;

    for my $exp ( @$expected ) {
        my ($exp_type, $exp_spec) = %$exp;
        # We only have command_started_event checks
        subtest $exp_type => sub {
            ok(scalar(@got), 'event available')
                or return;
            my $event = shift @got;
            is($event->{type}.'_event', $exp_type, "is a $exp_type")
                or return;
            my $event_tester = "check_$exp_type";
            main->can($event_tester)->($exp_spec, $event);
        };
    }

    is scalar(@got), 0, 'no outstanding events';
}

sub check_event {
    my ($exp, $event) = @_;
    for my $key (sort keys %$exp) {
        my $check = "check_${key}_field";
        main->can($check)->($exp->{$key}, $event);
    }
}

#
# per-event type test handlers
#

sub check_command_started_event {
    my ($exp, $event) = @_;
    check_event($exp, $event);
}

#
# verificationi subs for use with Test::Deep::code
#

sub _verify_is_positive_num {
    my $value = shift;
    return(0, "error code is not defined")
        unless defined $value;
    return(0, "error code is not positive")
        unless $value > 1;
    return 1;
}

sub _verify_is_nonempty_str {
    my $value = shift;
    return(0, "error message is not defined")
        unless defined $value;
    return(0, "error message is empty")
        unless length $value;
    return 1;
}

#
# event field test handlers
#

# $event.database_name
sub check_database_name_field {
    my ($exp_name, $event) = @_;
    ok defined($event->{databaseName}), "database_name defined";
    ok length($event->{databaseName}), "database_name non-empty";
}

# $event.command_name
sub check_command_name_field {
    my ($exp_name, $event) = @_;
    is $event->{commandName}, $exp_name, "command name";
}

# $event.reply
sub check_reply_field {
    my ($exp_reply, $event) = @_;
    my $event_reply = $event->{reply};

    # special case for $event.reply.cursor.id
    if (exists $exp_reply->{cursor}) {
        if (exists $exp_reply->{cursor}{id}) {
            $exp_reply->{cursor}{id} = code(\&_verify_is_positive_num)
                if $exp_reply->{cursor}{id} eq '42';
        }
    }

    # special case for $event.reply.writeErrors
    if (exists $exp_reply->{writeErrors}) {
        for my $i ( 0 .. $#{ $exp_reply->{writeErrors} } ) {
            my $error = $exp_reply->{writeErrors}[$i];
            if (exists $error->{code} and $error->{code} eq 42) {
                $error->{code} = code(\&_verify_is_positive_num);
            }
            if (exists $error->{errmsg} and $error->{errmsg} eq '') {
                $error->{errmsg} = code(\&_verify_is_nonempty_str);
            }
            $exp_reply->{writeErrors}[$i] = superhashof( $error );
        }
    }

    # special case for $event.command.cursorsUnknown on killCursors
    if ($event->{commandName} eq 'killCursors'
        and defined $exp_reply->{cursorsUnknown}
    ) {
        for my $index (0 .. $#{ $exp_reply->{cursorsUnknown} }) {
            $exp_reply->{cursorsUnknown}[$index]
                = code(\&_verify_is_positive_num)
                if $exp_reply->{cursorsUnknown}[$index] eq 42;
        }
    }

    for my $exp_key (sort keys %$exp_reply) {
        cmp_deeply
            $event_reply->{$exp_key},
            prepare_data_spec($exp_reply->{$exp_key}),
            "reply field $exp_key" or diag explain $event_reply->{$exp_key};
    }
}

# $event.command
sub check_command_field {
    my ($exp_command, $event) = @_;
    my $event_command = $event->{command};

    # ordered defaults to true
    delete $exp_command->{ordered};

    # special case for $event.command.getMore
    if (exists $exp_command->{getMore}) {
        $exp_command->{getMore} = code(\&_verify_is_positive_num)
            if $exp_command->{getMore} eq '42';
    }

    # special case for $event.command.writeConcern.wtimeout
    if ( defined $exp_command->{writeConcern} ) {
        unless ( defined $exp_command->{writeConcern}->{wtimeout} ) {
            $exp_command->{writeConcern}{wtimeout} = ignore();
            $exp_command->{writeConcern} = subhashof($exp_command->{writeConcern});
        }
    }
    else {
        $exp_command->{writeConcern} = ignore();
    }

    # special case for $event.command.cursors on killCursors
    if ($event->{commandName} eq 'killCursors'
        and defined $exp_command->{cursors}
    ) {
        for my $index (0 .. $#{ $exp_command->{cursors} }) {
            $exp_command->{cursors}[$index]
                = code(\&_verify_is_positive_num)
                if $exp_command->{cursors}[$index] eq 42;
        }
    }

    if ( defined $exp_command->{lsid} ) {
        # Stuff correct session id in
        $exp_command->{lsid} = $sessions{ $exp_command->{lsid} . '_lsid' };
    }

    if ( defined $exp_command->{readConcern} ) {
        $exp_command->{readConcern}{afterClusterTime} = Isa('BSON::Timestamp')
            if ( defined $exp_command->{readConcern}{afterClusterTime} && $exp_command->{readConcern}{afterClusterTime} eq '42' );
    }

    if ( defined $exp_command->{txnNumber} ) {
        $exp_command->{txnNumber} = Math::BigInt->new($exp_command->{txnNumber});
    }

    if ( defined $exp_command->{recoveryToken} ) {
        $exp_command->{recoveryToken} = ignore()
            if $exp_command->{recoveryToken} eq '42';
    }

    for my $exp_key (sort keys %$exp_command) {
        my $event_value = $event_command->{$exp_key};
        my $exp_value = prepare_data_spec($exp_command->{$exp_key});
        my $label = "command field '$exp_key'";

        if (
            (grep { $exp_key eq $_ } qw( comment maxTimeMS ))
            or
            ($event->{commandName} eq 'getMore' and $exp_key eq 'batchSize')
        ) {
            cmp_deeply $event_value, $exp_value, $label;
        }
        elsif ( !defined $exp_value )
        {
            ok ! exists $event_command->{$exp_key}, $label . ' does not exist';
        }
        else {
            cmp_deeply $event_value, $exp_value, $label;
        }
    }
}

sub assert_session_transaction_state {
    my ($pkg, $args) = @_;
    my ($session, $state) = @$args{qw(session state)};
    ok($session->_in_transaction_state($state), 'assert session txn state');
}

clear_testdbs;

done_testing;
