package PVE::InitSystem::SysVInit;

# sysvinit backend for PVE::InitSystem - manages services via the
# distribution-neutral `service` wrapper, and places/tracks resource scopes
# by manipulating cgroupv2 directly instead of asking systemd to do it (there
# is no sysvinit equivalent of systemd's transient scope units or of waiting
# on D-Bus job-completion signals).
#
# Resource scopes are therefore a best-effort approximation of the systemd
# backend's enter_systemd_scope/wait_for_unit_removed/is_unit_active (names
# kept for API compatibility with PVE::InitSystem's fixed interface, even
# though they are systemd vocabulary): every scope is a plain cgroup
# directory under SCOPE_PARENT_SLICE. Properties that are systemd
# service-manager semantics rather than cgroup attributes (Slice placement,
# KillMode, After, Before, SendSIGKILL, TimeoutStopUSec) have no equivalent
# here and are ignored. CPUShares (a cgroupv1 notion) is rejected rather than
# converted, since a numerically "equivalent" cgroupv2 weight does not exist;
# callers need to pass CPUWeight under this backend.
#
# See PVE::InitSystem for the backend-agnostic interface that callers should
# use instead of this module directly.

use strict;
use warnings;

use File::Find qw(find);
use File::Path qw(make_path);
use Time::HiRes qw(usleep);

use PVE::CGroup;
use PVE::Cmd qw(run);
use PVE::Exception qw(raise_param_exc);
use PVE::File qw(file_get_contents file_set_contents);
use PVE::ProcFSTools;

use constant SCOPE_PARENT_SLICE => 'pve.slice';
use constant WAIT_POLL_INTERVAL_US => 200_000; # 0.2s, while waiting for a scope to empty out
use constant ZONEINFO_DIR => '/usr/share/zoneinfo';

my sub scope_cgroup_path {
    my ($unit) = @_;

    die "resource scopes under the sysvinit backend require cgroupv2\n"
        if PVE::CGroup::cgroup_mode() != 2;

    return PVE::CGroup::cgroupv2_base_path() . '/' . SCOPE_PARENT_SLICE . "/$unit";
}

sub start_service {
    my ($name) = @_;

    run(['service', $name, 'start']);
}

sub stop_service {
    my ($name) = @_;

    run(['service', $name, 'stop']);
}

sub restart_service {
    my ($name, $use_hup) = @_;

    if ($use_hup) {
        # LSB init scripts aren't guaranteed to support 'reload', fall back
        # to a full restart if it fails (mirroring systemd's reload-or-restart).
        eval { run(['service', $name, 'reload']); };
        return if !$@;
    }

    run(['service', $name, 'restart']);
}

# Note that the description is accepted (and required, as in the systemd
# backend) but unused here - only for API compatibility.
sub enter_systemd_scope {
    my ($unit, $description, %extra) = @_;
    die "missing description\n" if !defined($description);

    $unit .= '.scope';
    my $path = scope_cgroup_path($unit);

    make_path($path);
    PVE::ProcFSTools::write_proc_entry("$path/cgroup.procs", "$$");

    if (defined(my $quota = delete $extra{CPUQuota})) {
        my $period = 100_000; # 100ms, matches systemd's default accounting period
        PVE::ProcFSTools::write_proc_entry("$path/cpu.max", int($quota * $period / 100) . " $period");
    }

    if (defined(my $weight = delete $extra{CPUWeight})) {
        PVE::ProcFSTools::write_proc_entry("$path/cpu.weight", $weight);
    }

    delete $extra{$_} for qw(Slice KillMode After Before SendSIGKILL TimeoutStopUSec timeout);

    if (%extra) {
        die "don't know how to apply " . join(', ', sort keys %extra)
            . " for a sysvinit resource scope\n";
    }

    return 1;
}

sub wait_for_unit_removed($;$) {
    my ($unit, $timeout) = @_;

    my $path = scope_cgroup_path($unit);

    return 1 if !-d $path;

    my $deadline = defined($timeout) ? time() + $timeout : undef;

    while (1) {
        return 1 if !-d $path;

        my $events = eval { file_get_contents("$path/cgroup.events") };
        if (defined($events) && $events =~ m/^populated\s+0\s*$/m) {
            # Nothing else cleans this up once the cgroup is empty - do it
            # ourselves, like systemd would once a transient scope empties out.
            rmdir($path);
            return 1;
        }

        die "timeout waiting for '$unit' to be removed\n"
            if defined($deadline) && time() >= $deadline;

        usleep(WAIT_POLL_INTERVAL_US);
    }
}

sub is_unit_active($;$) {
    my ($unit) = @_;

    my $path = scope_cgroup_path($unit);
    return 0 if !-d $path;

    my $events = eval { file_get_contents("$path/cgroup.events") };
    return 0 if !defined($events);

    return $events =~ m/^populated\s+1\s*$/m ? 1 : 0;
}

sub get_timezone {
    my $tz = eval { file_get_contents('/etc/timezone') };
    return undef if !defined($tz);

    chomp $tz;
    return $tz;
}

sub set_timezone {
    my ($timezone) = @_;

    raise_param_exc({ 'timezone' => "No such timezone" })
        if (!grep { $_ eq $timezone } list_timezones());

    file_set_contents('/etc/timezone', "$timezone\n");

    unlink('/etc/localtime');
    symlink(ZONEINFO_DIR . "/$timezone", '/etc/localtime')
        or die "unable to activate timezone '$timezone' - $!\n";
}

sub list_timezones {
    my @timezones;

    find(
        {
            no_chdir => 1,
            wanted => sub {
                return if !-f $_;
                return if m{/(?:posix|right)/}; # duplicate alternate trees

                my $fh;
                return if !open($fh, '<', $_);
                my $magic;
                read($fh, $magic, 4);
                close($fh);
                return if $magic ne 'TZif'; # skip zone.tab, leapseconds, etc.

                my $name = $_;
                $name =~ s{^\Q${\ZONEINFO_DIR}\E/}{};
                push @timezones, $name;
            },
        },
        ZONEINFO_DIR,
    );

    @timezones = sort @timezones;
    return @timezones;
}

1;
