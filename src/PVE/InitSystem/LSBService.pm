package PVE::InitSystem::LSBService;

# LSB/service(8) backend for PVE::InitSystem - manages services via the
# distribution-neutral `service` wrapper (which itself dispatches to
# sysvinit, OpenRC, or whatever else provides an LSB-style /etc/init.d
# interface - this backend is not specific to sysvinit), and places/tracks
# resource scopes by manipulating cgroupv2 directly instead of asking
# systemd to do it (none of these init systems have an equivalent of
# systemd's transient scope units or of waiting on D-Bus job-completion
# signals).
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
# controllers delegated down to the scopes, if the kernel provides them
use constant SCOPE_CONTROLLERS => qw(cpu io memory pids);
use constant WAIT_POLL_INTERVAL_US => 200_000; # 0.2s, while waiting for a scope to empty out
use constant ZONEINFO_DIR => '/usr/share/zoneinfo';

my sub scope_cgroup_path {
    my ($unit) = @_;

    die "resource scopes under the LSBService backend require cgroupv2\n"
        if PVE::CGroup::cgroup_mode() != 2;

    return PVE::CGroup::cgroupv2_base_path() . '/' . SCOPE_PARENT_SLICE . "/$unit";
}

# Create SCOPE_PARENT_SLICE and delegate SCOPE_CONTROLLERS from the cgroupv2
# root down through it, so that scopes below it get their cpu.max/cpu.weight/...
# interface files. Under systemd this delegation is done by systemd itself;
# here nobody else does it (OpenRC only enables controllers for its own
# per-service cgroups), and without it a scope only has the cgroup.* core
# files. This is fine with cgroupv2's "no internal processes" rule as long as
# nothing is placed in the slice itself, only in scopes below it.
my sub setup_scope_parent {
    my $base = PVE::CGroup::cgroupv2_base_path();
    my $slice = "$base/" . SCOPE_PARENT_SLICE;

    make_path($slice);

    for my $cgroup ($base, $slice) {
        my %available = map { $_ => 1 } split(/\s+/, file_get_contents("$cgroup/cgroup.controllers"));
        my @enable = map { "+$_" } grep { $available{$_} } SCOPE_CONTROLLERS;
        next if !@enable;
        PVE::ProcFSTools::write_proc_entry("$cgroup/cgroup.subtree_control", join(' ', @enable));
    }
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

    # Validate everything before touching the cgroup tree, so that a rejected
    # property leaves neither a stray scope nor the caller moved into it.
    my $quota = delete $extra{CPUQuota};
    my $weight = delete $extra{CPUWeight};

    delete $extra{$_} for qw(Slice KillMode After Before SendSIGKILL TimeoutStopUSec timeout);

    if (%extra) {
        die "don't know how to apply " . join(', ', sort keys %extra)
            . " for an LSBService resource scope\n";
    }

    setup_scope_parent();
    make_path($path);

    if (defined($quota)) {
        my $period = 100_000; # 100ms, matches systemd's default accounting period
        PVE::ProcFSTools::write_proc_entry("$path/cpu.max", int($quota * $period / 100) . " $period");
    }

    if (defined($weight)) {
        PVE::ProcFSTools::write_proc_entry("$path/cpu.weight", $weight);
    }

    # move ourselves in last, once the limits are in place
    PVE::ProcFSTools::write_proc_entry("$path/cgroup.procs", "$$");

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

# The /etc/localtime symlink is authoritative (it's also what timedatectl reads
# in the systemd backend). /etc/timezone is only a fallback: tzdata stopped
# shipping it with Debian 13 trixie (and thus Devuan 6 excalibur).
sub get_timezone {
    if (defined(my $target = readlink('/etc/localtime'))) {
        return $1 if $target =~ m{(?:^|/)zoneinfo/(.+)$};
    }

    my $tz = eval { file_get_contents('/etc/timezone') };
    return undef if !defined($tz);

    chomp $tz;
    return $tz;
}

sub set_timezone {
    my ($timezone) = @_;

    raise_param_exc({ 'timezone' => "No such timezone" })
        if (!grep { $_ eq $timezone } list_timezones());

    # only keep /etc/timezone in sync where it still exists, don't recreate it
    file_set_contents('/etc/timezone', "$timezone\n") if -e '/etc/timezone';

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
