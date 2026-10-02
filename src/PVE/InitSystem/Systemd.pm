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

# Change resource properties of a running scope, with the same names and units
# as enter_systemd_scope: CPUQuota (percent of one CPU), CPUWeight (cgroup v2)
# and CPUShares (cgroup v1). An undef value resets it to the default.
sub set_scope_properties {
    my ($unit, %props) = @_;

    my $properties = [];
    for my $key (sort keys %props) {
        my $value = $props{$key};
        if ($key eq 'CPUQuota') {
            push @$properties,
                ['CPUQuotaPerSecUSec', dbus_uint64(defined($value) ? $value * 10_000 : -1)];
        } elsif ($key eq 'CPUWeight' || $key eq 'CPUShares') {
            push @$properties, [$key, dbus_uint64($value // -1)];
        } else {
            die "Don't know how to encode $key for systemd scope\n";
        }
    }

    systemd_call(sub {
        my ($if, $reactor, $finish_cb) = @_;
        # runtime only, like the transient scope itself
        $if->SetUnitProperties($unit, dbus_boolean(1), $properties);
        return 1;
    });
}

# Stop a scope, i.e. its processes. How is up to the scope's own KillMode,
# SendSIGKILL and TimeoutStopUSec properties, so %opts (see the LSBService
# backend) is ignored here. Dies if systemctl fails.
sub stop_scope {
    my ($unit, %opts) = @_;

    run(['systemctl', 'stop', $unit], outfunc => sub { }, errfunc => sub { });
}

# Reset the 'failed' state of units, e.g. so that a failed scope or a unit
# PartOf= it doesn't block starting a new scope with the same name. Errors,
# e.g. for units not loaded, are ignored.
sub reset_failed {
    my (@units) = @_;

    for my $unit (@units) {
        eval { run(['systemctl', 'reset-failed', $unit], outfunc => sub { }, errfunc => sub { }) };
    }
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

# Whether we were run by the init system itself, e.g. as a unit's ExecStart=,
# rather than by a user or another service. systemd runs those as its children.
sub started_by_init {
    return getppid() == 1;
}

sub reload_service {
    my ($name) = @_;

    run(['systemctl', 'reload', $name]);
}

# reload (or restart, if reload isn't supported) only if already running
sub try_reload_or_restart_service {
    my (@names) = @_;

    run(['systemctl', 'try-reload-or-restart', @names]);
}

# $opts{runtime}: only enable/disable until the next reboot
sub enable_service {
    my ($name, %opts) = @_;

    run(['systemctl', 'enable', $opts{runtime} ? ('--runtime') : (), $name]);
}

sub disable_service {
    my ($name, %opts) = @_;

    run(['systemctl', 'disable', $opts{runtime} ? ('--runtime') : (), $name]);
}

# Returns the state of a service as a hash with the keys:
#   description  - human readable description, undef if the service doesn't exist
#   load_state   - 'loaded' or 'not-found'
#   unit_state   - e.g. 'enabled', 'disabled', 'static'
#   active_state - e.g. 'active', 'inactive', 'failed'
#   sub_state    - e.g. 'running', 'dead', 'exited'
#   type         - e.g. 'simple', 'forking', 'oneshot' (if known)
#   result       - result of the last run, e.g. 'success' (if known)
sub service_status {
    my ($name) = @_;

    my $props = {};
    run(
        ['systemctl', 'show', $name],
        outfunc => sub {
            my ($line) = @_;
            $props->{$1} = $2 if $line =~ m/^([^=\s]+)=(.*)$/;
        },
    );

    return {
        description => $props->{Description},
        load_state => $props->{LoadState},
        unit_state => $props->{UnitFileState},
        active_state => $props->{ActiveState},
        sub_state => $props->{SubState},
        type => $props->{Type},
        result => $props->{Result},
    };
}

# Returns the main PID of a running service, or 0 if it's not running.
sub service_main_pid {
    my ($name) = @_;

    my $pid = 0;
    run(
        ['systemctl', 'show', $name, '--property', 'MainPID', '--value'],
        outfunc => sub { $pid = int($1) if $_[0] =~ m/^(\d+)$/ },
    );

    return $pid;
}

# some services log under a different unit than the name they're known by
my $log_unit_aliases = {
    postfix => 'postfix@-',
    sshd => 'ssh',
};

# Returns ($count, $lines) for paging through the system log, in the same
# format as PVE::Tools::dump_logfile.
sub dump_syslog {
    my ($start, $limit, $since, $until, $service) = @_;

    my $lines = [];
    my $count = 0;

    $start = 0 if !$start;
    $limit = 50 if !$limit;

    my $parser = sub {
        my $line = shift;

        return if $count++ < $start;
        return if $limit <= 0;
        push @$lines, { n => int($count), t => $line };
        $limit--;
    };

    my $cmd = ['journalctl', '-o', 'short', '--no-pager'];

    push @$cmd, '--unit', $log_unit_aliases->{$service} // $service if $service;
    push @$cmd, '--since', $since if $since;
    push @$cmd, '--until', $until if $until;
    run($cmd, outfunc => $parser);

    # HACK: ExtJS store.guaranteeRange() does not like empty array
    # so we add a line
    if (!$count) {
        $count++;
        push @$lines, { n => $count, t => "no content" };
    }

    return ($count, $lines);
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
