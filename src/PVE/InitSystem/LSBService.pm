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
# directory in the slice given by the Slice property (SCOPE_PARENT_SLICE if
# none), at the same path as systemd would use. Properties that are systemd
# service-manager semantics rather than cgroup attributes (KillMode, After,
# Before, SendSIGKILL, TimeoutStopUSec) have no equivalent here and are
# ignored. CPUShares (a cgroupv1 notion) is rejected rather than
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
use Time::Local qw(timegm timelocal);

use PVE::CGroup;
use PVE::Cmd qw(run);
use PVE::Exception qw(raise_param_exc);
use PVE::File qw(file_get_contents file_set_contents);
use PVE::ProcFSTools;
use PVE::Tools ();

# for scopes created without a Slice= property
use constant SCOPE_PARENT_SLICE => 'pve.slice';
# controllers delegated down to the scopes, if the kernel provides them
use constant SCOPE_CONTROLLERS => qw(cpu io memory pids);
use constant WAIT_POLL_INTERVAL_US => 200_000; # 0.2s, while waiting for a scope to empty out
use constant ZONEINFO_DIR => '/usr/share/zoneinfo';

my sub cgroup_base {
    die "resource scopes under the LSBService backend require cgroupv2\n"
        if PVE::CGroup::cgroup_mode() != 2;

    return PVE::CGroup::cgroupv2_base_path();
}

# The cgroup directories of a slice, following systemd's naming: a dash in the
# name nests it, e.g. 'a-b.slice' is 'a.slice/a-b.slice'. Placing scopes the
# same way as systemd keeps their cgroup paths independent of the backend, e.g.
# qemu-server's 'qemu.slice/<vmid>.scope' (PVE::QemuServer::CGroup).
my sub slice_dirs {
    my ($slice) = @_;

    die "invalid slice name '$slice'\n"
        if $slice !~ m/^([A-Za-z0-9_.:\\]+(?:-[A-Za-z0-9_.:\\]+)*)\.slice$/;

    my @parts = split(/-/, $1);
    return map { join('-', @parts[0 .. $_]) . '.slice' } 0 .. $#parts;
}

# Create the slice for a scope and delegate SCOPE_CONTROLLERS from the cgroupv2
# root down through it, so that scopes below it get their cpu.max/cpu.weight/...
# interface files. Under systemd this delegation is done by systemd itself;
# here nobody else does it (OpenRC only enables controllers for its own
# per-service cgroups), and without it a scope only has the cgroup.* core
# files. This is fine with cgroupv2's "no internal processes" rule as long as
# nothing is placed in the slices themselves, only in scopes below them.
# Returns the slice's path.
my sub setup_slice {
    my ($slice) = @_;

    my $base = cgroup_base();
    my @dirs = slice_dirs($slice);
    my $path = join('/', $base, @dirs);

    make_path($path);

    my $cgroup = $base;
    for my $dir (undef, @dirs) {
        $cgroup .= "/$dir" if defined($dir);
        my %available = map { $_ => 1 } split(/\s+/, file_get_contents("$cgroup/cgroup.controllers"));
        my @enable = map { "+$_" } grep { $available{$_} } SCOPE_CONTROLLERS;
        next if !@enable;
        PVE::ProcFSTools::write_proc_entry("$cgroup/cgroup.subtree_control", join(' ', @enable));
    }

    return $path;
}

# Find an existing scope by its unit name, in whatever slice it was created.
my sub find_scope_path {
    my ($unit) = @_;

    my $base = cgroup_base();
    for my $depth (1 .. 4) {
        my $pattern = join('/', $base, ('*.slice') x $depth, $unit);
        my ($path) = grep { -d } glob($pattern);
        return $path if defined($path);
    }

    return undef;
}

# Paths are package variables so that tests can point them elsewhere.
our $INITD_DIR = '/etc/init.d';
# sysv-rc start links and OpenRC runlevels, either marks a service as enabled
our $RC_DIR_GLOB = '/etc/rc[2345].d';
our $OPENRC_RUNLEVEL_GLOB = '/etc/runlevels/*';
# oldest first, only uncompressed files are read
our $SYSLOG_FILES = ['/var/log/syslog.1', '/var/log/syslog'];

# Names that systemd resolves as unit aliases, mapped to the Debian init script
# providing them. A '.service' suffix is accepted and dropped.
my $service_aliases = {
    sshd => 'ssh',
    syslog => 'rsyslog',
};

my sub init_script_name {
    my ($name) = @_;

    $name =~ s/\.service$//;
    return $service_aliases->{$name} // $name;
}

# LSB 'status' exit codes, see the LSB core spec's "Init Script Actions"
my $lsb_status_states = {
    0 => ['active', 'running'],
    1 => ['failed', 'failed'], # dead, but pid file exists
    2 => ['failed', 'failed'], # dead, but lock file exists
    3 => ['inactive', 'dead'],
};

my sub service_cmd {
    my ($name, $action, %param) = @_;

    return run(['service', init_script_name($name), $action], %param);
}

my sub service_running {
    my ($name) = @_;

    my $rc = service_cmd($name, 'status', noerr => 1, outfunc => sub { }, errfunc => sub { });
    return $rc == 0;
}

sub start_service {
    my ($name) = @_;

    service_cmd($name, 'start');
}

sub stop_service {
    my ($name) = @_;

    service_cmd($name, 'stop');
}

sub restart_service {
    my ($name, $use_hup) = @_;

    if ($use_hup) {
        # LSB init scripts aren't guaranteed to support 'reload', fall back
        # to a full restart if it fails (mirroring systemd's reload-or-restart).
        eval { service_cmd($name, 'reload'); };
        return if !$@;
    }

    service_cmd($name, 'restart');
}

# Whether we were run by the init system itself rather than by a user or another
# service. Unlike systemd, init scripts run the daemon from their own shell, so
# they mark that in the environment: PVE daemons' init scripts have to
# 'export PVE_INIT_SCRIPT=1' before running '<daemon> start|stop|restart',
# otherwise these would ask the init system to do it, i.e. run the init script
# again. The marker is consumed, so the daemon's own children don't inherit it.
sub started_by_init {
    return 1 if getppid() == 1;
    return 1 if delete($ENV{PVE_INIT_SCRIPT});
    return 0;
}

sub reload_service {
    my ($name) = @_;

    service_cmd($name, 'reload');
}

sub try_reload_or_restart_service {
    my (@names) = @_;

    for my $name (@names) {
        restart_service($name, 1) if service_running($name);
    }
}

# update-rc.d drives both sysv-rc (insserv) and OpenRC on Devuan. 'defaults'
# first, since 'enable' only toggles links that already exist. There's no
# equivalent of systemd's --runtime, so $opts{runtime} is applied persistently.
sub enable_service {
    my ($name, %opts) = @_;

    my $script = init_script_name($name);
    run(['update-rc.d', $script, 'defaults']);
    run(['update-rc.d', $script, 'enable']);
}

sub disable_service {
    my ($name, %opts) = @_;

    run(['update-rc.d', init_script_name($name), 'disable']);
}

my sub lsb_header_field {
    my ($script, $field) = @_;

    my $content = eval { file_get_contents($script) } // '';
    return $1 if $content =~ m/^### BEGIN INIT INFO\n(?:#.*\n)*?#\s*\Q$field\E:\s*(.*?)\s*$/m;
    return undef;
}

my sub service_enabled {
    my ($script) = @_;

    return 1 if glob("$RC_DIR_GLOB/S[0-9][0-9]$script");
    return 1 if grep { -l "$_/$script" || -e "$_/$script" } glob($OPENRC_RUNLEVEL_GLOB);
    return 0;
}

# See PVE::InitSystem::Systemd::service_status for the returned hash. The type
# and result of the last run aren't known for init scripts and stay undef.
sub service_status {
    my ($name) = @_;

    my $script = init_script_name($name);
    my $path = "$INITD_DIR/$script";

    if (!-x $path) {
        return {
            description => undef,
            load_state => 'not-found',
            unit_state => undef,
            active_state => 'inactive',
            sub_state => 'dead',
            type => undef,
            result => undef,
        };
    }

    my $rc = service_cmd($name, 'status', noerr => 1, outfunc => sub { }, errfunc => sub { });
    my ($active_state, $sub_state) = ($lsb_status_states->{$rc} // ['unknown', 'unknown'])->@*;

    return {
        description => lsb_header_field($path, 'Short-Description')
            // lsb_header_field($path, 'Description') // $script,
        load_state => 'loaded',
        unit_state => service_enabled($script) ? 'enabled' : 'disabled',
        active_state => $active_state,
        sub_state => $sub_state,
        type => undef,
        result => undef,
    };
}

# Init scripts have no generic way to report their main PID, so this checks
# the pid file the script declares (PIDFILE=..., as most Debian scripts do and
# OpenRC's pidfile=...), then the conventional locations.
sub service_main_pid {
    my ($name) = @_;

    my $script = init_script_name($name);
    my $content = eval { file_get_contents("$INITD_DIR/$script") } // '';
    my @declared = $content =~ m/^\s*(?:PIDFILE|pidfile)=["']?(\/[^"'\s\$]+)["']?\s*$/mg;

    for my $pidfile (@declared, "/run/$script.pid", "/run/$script/$script.pid") {
        my $pid = eval { file_get_contents($pidfile) } // next;
        next if $pid !~ m/^\s*(\d+)\s*$/;
        return int($1) if PVE::ProcFSTools::check_process_running($1);
    }

    return 0;
}

# The syslog tag a service's messages are logged under, where it differs from
# the service name (also accepting the systemd unit names callers may pass).
my $log_tag_aliases = {
    ssh => 'sshd',
    'postfix@-' => 'postfix',
};

my $month_numbers = {
    Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4, Jun => 5,
    Jul => 6, Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11,
};

# Parse the timestamp and program tag of an rsyslog line, either in the
# RFC 3339 format (rsyslog's default since Debian 12) or the traditional one.
my sub parse_syslog_line {
    my ($line, $now) = @_;

    if ($line =~ m/^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)\s+\S+\s+([^\s\[:]+)/) {
        my $time = timegm($6, $5, $4, $3, $2 - 1, $1);
        if ($7 ne 'Z') {
            my ($sign, $h, $m) = $7 =~ m/^([+-])(\d\d):(\d\d)$/;
            $time -= ($sign eq '+' ? 1 : -1) * ($h * 3600 + $m * 60);
        }
        return ($time, $8);
    } elsif ($line =~ m/^(\w{3})\s+(\d+) (\d\d):(\d\d):(\d\d)\s+\S+\s+([^\s\[:]+)/) {
        my $mon = $month_numbers->{$1} // return;
        my $year = (localtime($now))[5] + 1900;
        my $time = timelocal($5, $4, $3, $2, $mon, $year);
        # no year in the line, so a date in the future is from last year
        $time = timelocal($5, $4, $3, $2, $mon, $year - 1) if $time > $now + 86400;
        return ($time, $6);
    }

    return;
}

# Parse a 'YYYY-MM-DD[ HH:MM[:SS]]' local time, as accepted by journalctl
# --since/--until (see SYSTEMD_DATETIME_FORMAT in the API schemas).
my sub parse_datetime {
    my ($str) = @_;

    die "unable to parse date-time '$str'\n"
        if $str !~ m/^(\d{4})-(\d\d)-(\d\d)(?:[ T](\d\d):(\d\d)(?::(\d\d))?)?$/;

    return timelocal($6 // 0, $5 // 0, $4 // 0, $3, $2 - 1, $1);
}

# See PVE::InitSystem::Systemd::dump_syslog. Reads the rsyslog files instead of
# the journal; $service matches the program tag (e.g. 'pveproxy[1234]:', or
# 'postfix/smtpd[42]:' for 'postfix').
sub dump_syslog {
    my ($start, $limit, $since, $until, $service) = @_;

    my $since_time = defined($since) && length($since) ? parse_datetime($since) : undef;
    my $until_time = defined($until) && length($until) ? parse_datetime($until) : undef;

    my $tag;
    if ($service) {
        $tag = init_script_name($service);
        $tag = $log_tag_aliases->{$tag} // $tag;
    }

    my $now = time();
    my $filter = sub {
        my ($line) = @_;

        return 1 if !defined($since_time) && !defined($until_time) && !defined($tag);

        my ($time, $prog) = parse_syslog_line($line, $now);
        return 0 if !defined($time);
        return 0 if defined($since_time) && $time < $since_time;
        return 0 if defined($until_time) && $time > $until_time;
        return 0 if defined($tag) && $prog ne $tag && $prog !~ m/^\Q$tag\E\//;
        return 1;
    };

    my $state = { start => $start // 0, limit => $limit || 50, final => 0 };
    for my $file (@$SYSLOG_FILES) {
        open(my $fh, '<', $file) or next;
        PVE::Tools::dump_logfile_by_filehandle($fh, $filter, $state);
        close($fh);
    }

    my ($count, $lines) = ($state->{count} // 0, $state->{lines} // []);

    # HACK: ExtJS store.guaranteeRange() does not like empty array
    # so we add a line
    if (!$count) {
        $count++;
        push @$lines, { n => $count, t => "no content" };
    }

    return ($count, $lines);
}

# Note that the description is accepted (and required, as in the systemd
# backend) but unused here - only for API compatibility.
sub enter_systemd_scope {
    my ($unit, $description, %extra) = @_;
    die "missing description\n" if !defined($description);

    $unit .= '.scope';

    # Validate everything before touching the cgroup tree, so that a rejected
    # property leaves neither a stray scope nor the caller moved into it.
    my $quota = delete $extra{CPUQuota};
    my $weight = delete $extra{CPUWeight};
    my $slice = delete $extra{Slice} // SCOPE_PARENT_SLICE;
    slice_dirs($slice);    # validate

    delete $extra{$_} for qw(KillMode After Before SendSIGKILL TimeoutStopUSec timeout);

    if (%extra) {
        die "don't know how to apply " . join(', ', sort keys %extra)
            . " for an LSBService resource scope\n";
    }

    my $path = setup_slice($slice) . "/$unit";
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

# See PVE::InitSystem::Systemd::set_scope_properties. Like enter_systemd_scope,
# only CPUQuota and CPUWeight, written to the scope's cgroup v2 interface files;
# undef resets to the kernel's defaults (no limit, weight 100), which are
# systemd's defaults too.
sub set_scope_properties {
    my ($unit, %props) = @_;

    for my $key (sort keys %props) {
        die "don't know how to apply $key for an LSBService resource scope\n"
            if $key ne 'CPUQuota' && $key ne 'CPUWeight';
    }

    my $path = find_scope_path($unit) // die "resource scope '$unit' not found\n";

    if (exists($props{CPUQuota})) {
        my $quota = $props{CPUQuota};
        my $period = 100_000; # 100ms, as in enter_systemd_scope
        my $max = defined($quota) ? int($quota * $period / 100) : 'max';
        PVE::ProcFSTools::write_proc_entry("$path/cpu.max", "$max $period");
    }

    if (exists($props{CPUWeight})) {
        PVE::ProcFSTools::write_proc_entry("$path/cpu.weight", $props{CPUWeight} // 100);
    }

    return;
}

sub wait_for_unit_removed($;$) {
    my ($unit, $timeout) = @_;

    my $path = find_scope_path($unit) // return 1;

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

    my $path = find_scope_path($unit) // return 0;

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
