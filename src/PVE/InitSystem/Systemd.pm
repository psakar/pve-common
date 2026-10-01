package PVE::InitSystem::Systemd;

# systemd backend for PVE::InitSystem - talks to systemd over D-Bus for
# service and scope management, and shells out to systemd's timedatectl for
# timezone handling.
#
# See PVE::InitSystem for the backend-agnostic interface that callers should
# use instead of this module directly.

use strict;
use warnings;

use Net::DBus qw(dbus_uint32 dbus_uint64 dbus_boolean);
use Net::DBus::Callback;
use Net::DBus::Reactor;

use PVE::Cmd qw(run);
use PVE::Exception qw(raise_param_exc);

# $code should take the parameters ($interface, $reactor, $finish_callback).
#
# $finish_callback can be used by dbus-signal-handlers to stop the reactor.
#
# In order to even start waiting on the reactor, $code needs to return undef, if it returns a
# defined value instead, it is assumed that this is the result already and we can stop.
# NOTE: This calls the dbus main loop and must not be used when another dbus
# main loop is being used as we need to wait signals.
sub systemd_call($;$) {
    my ($code, $timeout) = @_;

    my $bus = Net::DBus->system();
    my $reactor = Net::DBus::Reactor->main();

    my $service = $bus->get_service('org.freedesktop.systemd1');
    my $if = $service->get_object('/org/freedesktop/systemd1', 'org.freedesktop.systemd1.Manager');

    my ($finished, $current_result, $timer, $signal_info);
    my $finish_callback = sub {
        my ($result) = @_;

        $current_result = $result;

        $finished = 1;

        if (defined($timer)) {
            $reactor->remove_timeout($timer);
            $timer = undef;
        }

        if (defined($signal_info)) {
            $if->disconnect_from_signal($signal_info->{name}, $signal_info->{handle});
            $signal_info = undef;
        }

        if (defined($reactor)) {
            $reactor->shutdown();
            $reactor = undef;
        }
    };

    (my $result, $signal_info) = $code->($if, $reactor, $finish_callback);
    # Are we done immediately?
    return $result if defined $result;

    # Alterantively $finish_callback may have been called already?
    return $current_result if $finished;

    # Otherwise wait:
    my $on_timeout = sub {
        $finish_callback->(undef);
        die "timeout waiting on systemd\n";
    };
    $timer = $reactor->add_timeout($timeout * 1000, Net::DBus::Callback->new(method => $on_timeout))
        if defined($timeout);

    $reactor->run();
    $reactor->shutdown() if defined($reactor); # $finish_callback clears it

    return $current_result;
}

# Polling the job status instead doesn't work because this doesn't give us the
# distinction between success and failure.
#
# Note that the description is mandatory for security reasons.
sub enter_systemd_scope {
    my ($unit, $description, %extra) = @_;
    die "missing description\n" if !defined($description);

    my $timeout = delete $extra{timeout};

    $unit .= '.scope';
    my $properties = [[PIDs => [dbus_uint32($$)]]];

    foreach my $key (keys %extra) {
        if ($key eq 'Slice' || $key eq 'KillMode' || $key eq 'After' || $key eq 'Before') {
            push @{$properties}, [$key, $extra{$key}];
        } elsif ($key eq 'SendSIGKILL') {
            push @{$properties}, [$key, dbus_boolean($extra{$key})];
        } elsif ($key eq 'CPUShares' || $key eq 'CPUWeight' || $key eq 'TimeoutStopUSec') {
            push @{$properties}, [$key, dbus_uint64($extra{$key})];
        } elsif ($key eq 'CPUQuota') {
            push @{$properties}, ['CPUQuotaPerSecUSec', dbus_uint64($extra{$key} * 10_000)];
        } else {
            die "Don't know how to encode $key for systemd scope\n";
        }
    }

    systemd_call(
        sub {
            my ($if, $reactor, $finish_cb) = @_;

            my $job;

            my $signal_name = 'JobRemoved';
            my $signal_handle = $if->connect_to_signal(
                $signal_name,
                sub {
                    my ($id, $removed_job, $signaled_unit, $result) = @_;
                    return if $signaled_unit ne $unit || $removed_job ne $job;
                    if ($result ne 'done') {
                        # I seem to remember $reactor->run() catching die() at some point?
                        # so better call finish to be sure...:
                        $finish_cb->(0);
                        die "systemd job failed\n";
                    } else {
                        $finish_cb->(1);
                    }
                },
            );

            $job = $if->StartTransientUnit($unit, 'fail', $properties, []);

            my $signal_info = {
                name => $signal_name,
                handle => $signal_handle,
            };

            return (undef, $signal_info);
        },
        $timeout,
    );
}

sub wait_for_unit_removed($;$) {
    my ($unit, $timeout) = @_;

    systemd_call(
        sub {
            my ($if, $reactor, $finish_cb) = @_;

            my $unit_obj = eval { $if->GetUnit($unit) };
            return 1 if !$unit_obj;

            my $signal_name = 'UnitRemoved';
            my $signal_handle = $if->connect_to_signal(
                $signal_name,
                sub {
                    my ($id, $removed_unit) = @_;
                    $finish_cb->(1) if $removed_unit eq $unit_obj;
                },
            );

            my $signal_info = {
                name => $signal_name,
                handle => $signal_handle,
            };

            # Deal with what we lost between GetUnit() and connecting to UnitRemoved:
            my $unit_obj_new = eval { $if->GetUnit($unit) };
            if (!$unit_obj_new) {
                return (1, $signal_info);
            }

            return (undef, $signal_info);
        },
        $timeout,
    );
}

sub is_unit_active($;$) {
    my ($unit) = @_;

    my $bus = Net::DBus->system();
    my $reactor = Net::DBus::Reactor->main();

    my $service = $bus->get_service('org.freedesktop.systemd1');
    my $if = $service->get_object('/org/freedesktop/systemd1', 'org.freedesktop.systemd1.Manager');

    my $unit_path = eval { $if->GetUnit($unit) }
        or return 0;
    $if = $service->get_object($unit_path, 'org.freedesktop.systemd1.Unit')
        or return 0;
    my $state = $if->ActiveState;
    return defined($state) && $state eq 'active';
}

# Start/stop/restart a service unit via systemctl. Used by PVE::Daemon's
# start/stop/restart API calls when they're not invoked by the service itself
# (i.e. when init didn't directly fork us).
sub start_service {
    my ($name) = @_;

    run(['systemctl', 'start', $name]);
}

sub stop_service {
    my ($name) = @_;

    run(['systemctl', 'stop', $name]);
}

sub restart_service {
    my ($name, $use_hup) = @_;

    run(['systemctl', $use_hup ? 'reload-or-restart' : 'restart', $name]);
}

# Use systemds timedatectl for managing timezone settings
sub get_timezone {
    my $timezone;

    run(
        ['timedatectl', 'show', '--property=Timezone', '--value'],
        outfunc => sub { $timezone //= shift },
    );

    return $timezone;
}

sub set_timezone {
    my ($timezone) = @_;

    raise_param_exc({ 'timezone' => "No such timezone" })
        if (!grep { $_ eq $timezone } list_timezones());

    run(['timedatectl', 'set-timezone', $timezone]);
}

sub list_timezones {
    my @timezones = ();

    run(
        ['timedatectl', 'list-timezones'], outfunc => sub { push(@timezones, shift); },
    );

    return @timezones;
}

1;
