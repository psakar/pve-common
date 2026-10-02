#!/usr/bin/perl

# Tests for the service-state and system-log parts of the PVE::InitSystem
# backends. Commands are mocked, so these don't need the respective init system
# to be running. The Systemd backend is skipped if Net::DBus isn't available
# (it isn't a build dependency of the lsbservice variant).

use v5.36;

use lib '../src';

use File::Path qw(make_path remove_tree);
use Test::MockModule;
use Test::More;

use PVE::File qw(file_set_contents);
use PVE::InitSystem::LSBService;

my $test_dir = "/tmp/test-initsystem-$$";
make_path($test_dir);
END { remove_tree($test_dir) if defined($test_dir) }

# Mock the backend's run(): record commands, feed output lines, return an exit code.
my sub mock_run($module, $handler) {
    my $calls = [];
    my $mock = Test::MockModule->new($module);
    $mock->redefine(
        run => sub ($cmd, %param) {
            push @$calls, [@$cmd];
            my ($rc, @lines) = $handler->($cmd);
            if (my $outfunc = $param{outfunc}) {
                $outfunc->($_) for @lines;
            }
            die "command '@$cmd' failed: exit code $rc\n" if $rc && !$param{noerr};
            return $rc;
        },
    );
    return ($mock, $calls);
}

# --- LSBService: service control -------------------------------------------

{
    my $running = { ssh => 1 };
    my ($mock, $calls) = mock_run(
        'PVE::InitSystem::LSBService',
        sub ($cmd) {
            return ($running->{ $cmd->[1] } ? 0 : 3) if $cmd->[2] && $cmd->[2] eq 'status';
            return 0;
        },
    );

    PVE::InitSystem::LSBService::start_service('sshd.service');
    is_deeply($calls->[-1], ['service', 'ssh', 'start'], 'start: alias and .service suffix resolved');

    PVE::InitSystem::LSBService::reload_service('syslog');
    is_deeply($calls->[-1], ['service', 'rsyslog', 'reload'], 'reload: syslog maps to rsyslog');

    @$calls = ();
    PVE::InitSystem::LSBService::try_reload_or_restart_service('sshd', 'pveproxy.service');
    is_deeply(
        $calls,
        [['service', 'ssh', 'status'], ['service', 'ssh', 'reload'], ['service', 'pveproxy', 'status']],
        'try_reload_or_restart: only reloads running services',
    );

    @$calls = ();
    PVE::InitSystem::LSBService::enable_service('pveproxy', runtime => 1);
    is_deeply(
        $calls,
        [['update-rc.d', 'pveproxy', 'defaults'], ['update-rc.d', 'pveproxy', 'enable']],
        'enable_service: update-rc.d defaults + enable',
    );

    PVE::InitSystem::LSBService::disable_service('pveproxy.service');
    is_deeply($calls->[-1], ['update-rc.d', 'pveproxy', 'disable'], 'disable_service: update-rc.d disable');
}

# --- started_by_init -------------------------------------------------------

{
    local $ENV{PVE_INIT_SCRIPT};
    ok(!PVE::InitSystem::LSBService::started_by_init(), 'started_by_init: not without marker');
    $ENV{PVE_INIT_SCRIPT} = 1;
    ok(PVE::InitSystem::LSBService::started_by_init(), 'started_by_init: marker set by init script');
    ok(!exists($ENV{PVE_INIT_SCRIPT}), 'started_by_init: marker is consumed');
    ok(!PVE::InitSystem::LSBService::started_by_init(), 'started_by_init: only once');
}

# --- LSBService: service_status --------------------------------------------

{
    local $PVE::InitSystem::LSBService::INITD_DIR = "$test_dir/init.d";
    local $PVE::InitSystem::LSBService::RC_DIR_GLOB = "$test_dir/rc[2345].d";
    local $PVE::InitSystem::LSBService::OPENRC_RUNLEVEL_GLOB = "$test_dir/runlevels/*";
    make_path("$test_dir/init.d", "$test_dir/rc2.d", "$test_dir/runlevels/default");

    my $script = "#!/bin/sh\n### BEGIN INIT INFO\n# Provides: %s\n"
        . "# Required-Start: \$remote_fs\n# Short-Description: %s\n### END INIT INFO\n";
    for my $svc (qw(foo bar baz)) {
        file_set_contents("$test_dir/init.d/$svc", sprintf($script, $svc, "The $svc daemon"));
        chmod(0755, "$test_dir/init.d/$svc");
    }
    symlink("../init.d/foo", "$test_dir/rc2.d/S02foo"); # sysv-rc enabled
    symlink("/etc/init.d/bar", "$test_dir/runlevels/default/bar"); # OpenRC enabled

    my $status_rc = { foo => 0, bar => 3, baz => 1 };
    my ($mock, $calls) = mock_run('PVE::InitSystem::LSBService', sub ($cmd) { $status_rc->{ $cmd->[1] } });

    my $st = PVE::InitSystem::LSBService::service_status('foo.service');
    is($st->{description}, 'The foo daemon', 'status: description from LSB header');
    is($st->{load_state}, 'loaded', 'status: existing script is loaded');
    is($st->{unit_state}, 'enabled', 'status: enabled via rc2.d start link');
    is($st->{active_state}, 'active', 'status: exit 0 is active');
    is($st->{sub_state}, 'running', 'status: exit 0 is running');

    $st = PVE::InitSystem::LSBService::service_status('bar');
    is($st->{unit_state}, 'enabled', 'status: enabled via OpenRC runlevel');
    is($st->{active_state}, 'inactive', 'status: exit 3 is inactive');
    is($st->{sub_state}, 'dead', 'status: exit 3 is dead');

    $st = PVE::InitSystem::LSBService::service_status('baz');
    is($st->{unit_state}, 'disabled', 'status: no start link or runlevel is disabled');
    is($st->{active_state}, 'failed', 'status: exit 1 is failed');

    my $calls_before = scalar(@$calls);
    $st = PVE::InitSystem::LSBService::service_status('missing');
    is($st->{load_state}, 'not-found', 'status: missing script is not-found');
    is($st->{description}, undef, 'status: missing script has no description');
    is(scalar(@$calls), $calls_before, 'status: missing script is not run');
}

# --- LSBService: scope placement (fake cgroupfs) ---------------------------

{
    my $cg = "$test_dir/cgroup";
    my $cgroup_mock = Test::MockModule->new('PVE::CGroup');
    $cgroup_mock->redefine(cgroup_mode => sub { 2 }, cgroupv2_base_path => sub { $cg });
    # cgroupfs interface files exist already, write_proc_entry doesn't create them
    my $procfs_mock = Test::MockModule->new('PVE::ProcFSTools');
    $procfs_mock->redefine(write_proc_entry => sub ($file, $data) { file_set_contents($file, $data) });

    # cgroupfs creates the interface files itself; pre-create what's read
    for my $dir ('', '/pve.slice', '/qemu.slice', '/pve.slice/pve-test.slice') {
        make_path("$cg$dir");
        file_set_contents("$cg$dir/cgroup.controllers", "cpu io memory pids\n");
    }

    PVE::InitSystem::LSBService::enter_systemd_scope('100', 'VM', Slice => 'qemu.slice', CPUQuota => 150);
    ok(-d "$cg/qemu.slice/100.scope", 'scope: created in the given slice, like systemd');
    is(PVE::File::file_get_contents("$cg/qemu.slice/100.scope/cpu.max"), '150000 100000', 'scope: CPUQuota');
    is(PVE::File::file_get_contents("$cg/qemu.slice/100.scope/cgroup.procs"), "$$", 'scope: caller moved in');
    is(PVE::File::file_get_contents("$cg/qemu.slice/cgroup.subtree_control"), '+cpu +io +memory +pids',
        'scope: controllers delegated to the slice');

    PVE::InitSystem::LSBService::enter_systemd_scope('200', 'CT');
    ok(-d "$cg/pve.slice/200.scope", 'scope: pve.slice without Slice property');

    PVE::InitSystem::LSBService::enter_systemd_scope('300', 'test', Slice => 'pve-test.slice');
    ok(-d "$cg/pve.slice/pve-test.slice/300.scope", 'scope: dash in slice name nests it');
    is(PVE::File::file_get_contents("$cg/pve.slice/pve-test.slice/cgroup.subtree_control"), '+cpu +io +memory +pids',
        'scope: controllers delegated through nested slices');

    for my $bad ('qemu', '-x.slice', 'a--b.slice', '../x.slice') {
        eval { PVE::InitSystem::LSBService::enter_systemd_scope('400', 'bad', Slice => $bad) };
        like($@, qr/invalid slice name/, "scope: invalid slice name '$bad' rejected");
    }
    ok(!glob("$cg/*/400.scope") && !-d "$cg/400.scope", 'scope: rejected slice created nothing');

    file_set_contents("$cg/qemu.slice/100.scope/cgroup.events", "populated 1\nfrozen 0\n");
    file_set_contents("$cg/pve.slice/pve-test.slice/300.scope/cgroup.events", "populated 0\nfrozen 0\n");
    ok(PVE::InitSystem::LSBService::is_unit_active('100.scope'), 'scope: found by name in qemu.slice, active');
    ok(!PVE::InitSystem::LSBService::is_unit_active('300.scope'), 'scope: found in nested slice, inactive');
    ok(!PVE::InitSystem::LSBService::is_unit_active('999.scope'), 'scope: unknown scope inactive');
    ok(PVE::InitSystem::LSBService::wait_for_unit_removed('999.scope', 1), 'scope: unknown scope counts as removed');

    my $scope = "$cg/qemu.slice/100.scope";
    my sub cat($file) { PVE::File::file_get_contents("$scope/$file") }
    PVE::InitSystem::LSBService::set_scope_properties('100.scope', CPUQuota => 250, CPUWeight => 300);
    is(cat('cpu.max'), '250000 100000', 'set properties: CPUQuota');
    is(cat('cpu.weight'), '300', 'set properties: CPUWeight');
    PVE::InitSystem::LSBService::set_scope_properties('100.scope', CPUQuota => undef);
    is(cat('cpu.max'), 'max 100000', 'set properties: CPUQuota undef removes the limit');
    is(cat('cpu.weight'), '300', 'set properties: properties not passed stay');
    PVE::InitSystem::LSBService::set_scope_properties('100.scope', CPUWeight => undef);
    is(cat('cpu.weight'), '100', 'set properties: CPUWeight undef resets to default');

    eval { PVE::InitSystem::LSBService::set_scope_properties('100.scope', CPUWeight => 50, CPUShares => 10) };
    like($@, qr/don't know how to apply CPUShares/, 'set properties: CPUShares rejected');
    is(cat('cpu.weight'), '100', 'set properties: nothing written when rejecting');
    eval { PVE::InitSystem::LSBService::set_scope_properties('999.scope', CPUWeight => 50) };
    like($@, qr/resource scope '999.scope' not found/, 'set properties: unknown scope');

    is(PVE::InitSystem::LSBService::stop_scope('999.scope'), undef, 'stop_scope: unknown scope is fine');
    is(PVE::InitSystem::LSBService::reset_failed('100.scope'), undef, 'reset_failed: nothing to do');
}

# --- LSBService: dump_syslog -----------------------------------------------

{
    my $old = "$test_dir/syslog.1";
    my $cur = "$test_dir/syslog";
    local $PVE::InitSystem::LSBService::SYSLOG_FILES = [$old, "$test_dir/missing", $cur];

    file_set_contents(
        $old,
        "2026-10-01T23:59:00.000001+01:00 host pveproxy[100]: old proxy line\n"
            . "2026-10-02T00:30:00.000001+01:00 host sshd[200]: Accepted publickey\n",
    );
    file_set_contents(
        $cur,
        "2026-10-02T01:00:00.000001+01:00 host pvedaemon[300]: daemon line\n"
            . "2026-10-02T02:00:00.000001+01:00 host postfix/smtpd[400]: connect from x\n"
            . "2026-10-02T01:45:00.000001Z host pveproxy[101]: utc proxy line\n"
            . "Oct  2 03:00:00 host pveproxy[102]: traditional format line\n",
    );

    my ($count, $lines) = PVE::InitSystem::LSBService::dump_syslog(0, 50);
    is($count, 6, 'syslog: all lines of all existing files counted');
    like($lines->[0]->{t}, qr/old proxy line/, 'syslog: rotated file comes first');
    is($lines->[5]->{n}, 6, 'syslog: lines are numbered across files');

    ($count, $lines) = PVE::InitSystem::LSBService::dump_syslog(1, 2);
    is($count, 6, 'syslog paging: count is the full match count');
    is_deeply([map { $_->{n} } @$lines], [2, 3], 'syslog paging: start/limit applied');

    ($count, $lines) = PVE::InitSystem::LSBService::dump_syslog(0, 50, undef, undef, 'pveproxy');
    is_deeply(
        [map { ($_->{t} =~ m/: (.*)$/)[0] } @$lines],
        ['old proxy line', 'utc proxy line', 'traditional format line'],
        'syslog: filter by service tag, all timestamp formats parsed',
    );

    ($count, $lines) = PVE::InitSystem::LSBService::dump_syslog(0, 50, undef, undef, 'ssh');
    like($lines->[0]->{t}, qr/Accepted publickey/, 'syslog: ssh service matches the sshd tag');
    is($count, 1, 'syslog: only the sshd line');

    ($count, $lines) = PVE::InitSystem::LSBService::dump_syslog(0, 50, undef, undef, 'postfix@-');
    like($lines->[0]->{t}, qr/postfix\/smtpd/, 'syslog: postfix matches postfix/* sub-programs');

    # TZ=UTC-1 (see Makefile), so local time is UTC+1
    ($count, $lines) =
        PVE::InitSystem::LSBService::dump_syslog(0, 50, '2026-10-02 00:30', '2026-10-02 02:30');
    is_deeply(
        [map { ($_->{t} =~ m/: (.*)$/)[0] } @$lines],
        ['Accepted publickey', 'daemon line', 'connect from x'],
        'syslog: since/until in local time, inclusive',
    );

    ($count, $lines) = PVE::InitSystem::LSBService::dump_syslog(0, 50, undef, undef, 'nonexistent');
    is_deeply([$count, $lines], [1, [{ n => 1, t => 'no content' }]], 'syslog: no match gives "no content"');

    eval { PVE::InitSystem::LSBService::dump_syslog(0, 50, 'yesterday') };
    like($@, qr/unable to parse date-time 'yesterday'/, 'syslog: invalid since is rejected');
}

# --- Systemd ---------------------------------------------------------------

SKIP: {
    skip 'Net::DBus not available, skipping systemd backend tests', 10
        if !eval { require PVE::InitSystem::Systemd; 1 };

    my $show_output = [
        'Type=oneshot', 'Result=success', 'LoadState=loaded', 'ActiveState=inactive',
        'SubState=dead', 'UnitFileState=enabled', 'Description=PVE guests',
        'ExecStart={ path=/usr/bin/pvesh ; argv[]=/usr/bin/pvesh --nooutput }', 'MainPID=0',
    ];
    my ($mock, $calls) = mock_run(
        'PVE::InitSystem::Systemd',
        sub ($cmd) {
            return (0, @$show_output) if $cmd->[1] eq 'show' && @$cmd == 3;
            return (0, '4242') if $cmd->[1] eq 'show';
            return (0, 'Oct 02 01:00:00 host pvedaemon[300]: line') if $cmd->[0] eq 'journalctl';
            return 0;
        },
    );

    is_deeply(
        PVE::InitSystem::Systemd::service_status('pve-guests'),
        {
            description => 'PVE guests',
            load_state => 'loaded',
            unit_state => 'enabled',
            active_state => 'inactive',
            sub_state => 'dead',
            type => 'oneshot',
            result => 'success',
        },
        'systemd status: systemctl show properties mapped',
    );
    is_deeply($calls->[-1], ['systemctl', 'show', 'pve-guests'], 'systemd status: command');

    is(PVE::InitSystem::Systemd::service_main_pid('ceph-osd@1'), 4242, 'systemd main pid');

    PVE::InitSystem::Systemd::try_reload_or_restart_service('pvedaemon.service', 'pveproxy.service');
    is_deeply(
        $calls->[-1],
        ['systemctl', 'try-reload-or-restart', 'pvedaemon.service', 'pveproxy.service'],
        'systemd try-reload-or-restart: one call for all services',
    );

    PVE::InitSystem::Systemd::disable_service('ceph-osd@1', runtime => 1);
    is_deeply($calls->[-1], ['systemctl', 'disable', '--runtime', 'ceph-osd@1'], 'systemd disable --runtime');

    PVE::InitSystem::Systemd::stop_scope('100.scope', timeout => 5, kill => 0);
    is_deeply($calls->[-1], ['systemctl', 'stop', '100.scope'], 'systemd stop_scope: unit\'s own kill settings apply');

    @$calls = ();
    PVE::InitSystem::Systemd::reset_failed('pve-dbus-vmstate@100.service', '100.scope');
    is_deeply(
        $calls,
        [['systemctl', 'reset-failed', 'pve-dbus-vmstate@100.service'], ['systemctl', 'reset-failed', '100.scope']],
        'systemd reset_failed: each unit',
    );

    PVE::InitSystem::Systemd::enable_service('ceph-mon@a');
    is_deeply($calls->[-1], ['systemctl', 'enable', 'ceph-mon@a'], 'systemd enable');

    my ($count, $lines) = PVE::InitSystem::Systemd::dump_syslog(0, 50, '2026-10-02', undef, 'sshd');
    is_deeply(
        $calls->[-1],
        ['journalctl', '-o', 'short', '--no-pager', '--unit', 'ssh', '--since', '2026-10-02'],
        'systemd syslog: journalctl with unit alias',
    );
    is_deeply([$count, $lines->[0]->{n}], [1, 1], 'systemd syslog: lines collected');
}

# --- Systemd: set_scope_properties ------------------------------------------

SKIP: {
    skip 'Net::DBus not available, skipping systemd set_scope_properties tests', 4
        if !eval { require PVE::InitSystem::Systemd; 1 };

    my @set_calls;
    my $mock = Test::MockModule->new('PVE::InitSystem::Systemd');
    $mock->redefine(
        systemd_call => sub ($code, $timeout = undef) {
            my $if = bless {}, 'FakeSystemdManager';
            no strict 'refs';
            *{'FakeSystemdManager::SetUnitProperties'} = sub ($self, @args) { push @set_calls, [@args] };
            return $code->($if, undef, sub { });
        },
    );
    my sub props($call) {
        return { map { $_->[0] => $_->[1]->value() } $call->[2]->@* };
    }

    PVE::InitSystem::Systemd::set_scope_properties('100.scope', CPUQuota => 150, CPUWeight => 300);
    is($set_calls[-1]->[0], '100.scope', 'systemd set properties: unit');
    is($set_calls[-1]->[1]->value(), 1, 'systemd set properties: runtime only');
    is_deeply(props($set_calls[-1]), { CPUQuotaPerSecUSec => 1_500_000, CPUWeight => 300 },
        'systemd set properties: CPUQuota as CPUQuotaPerSecUSec, CPUWeight');

    PVE::InitSystem::Systemd::set_scope_properties('100.scope', CPUQuota => undef, CPUShares => undef);
    is_deeply(props($set_calls[-1]), { CPUQuotaPerSecUSec => -1, CPUShares => -1 },
        'systemd set properties: undef resets (-1, i.e. infinity)');
}

# --- PVE::Systemd compatibility wrappers pass their arguments on -------------

{
    require PVE::Systemd;

    # replace the facade's sub, so this checks what the compiled wrapper passes
    for my $sub (qw(wait_for_unit_removed is_unit_active enter_systemd_scope)) {
        my @args;
        no strict 'refs';
        no warnings 'redefine';
        local *{"PVE::InitSystem::$sub"} = sub { @args = @_; return 1 };
        &{"PVE::Systemd::$sub"}('100.scope', 20);
        is_deeply(\@args, ['100.scope', 20], "PVE::Systemd::$sub passes its arguments on");
    }
}

# --- PVE::Systemd::systemd_call compatibility wrapper ------------------------

SKIP: {
    skip 'Net::DBus not available, skipping systemd_call tests', 3
        if !eval { require PVE::InitSystem::Systemd; 1 };

    require PVE::Systemd;

    my @args;
    my $mock = Test::MockModule->new('PVE::InitSystem::Systemd');
    $mock->redefine(systemd_call => sub { @args = @_; return 'result' });

    my $code = sub { };
    {
        local $PVE::InitSystem::Backend::MODULE = 'PVE::InitSystem::Systemd';
        is(PVE::Systemd::systemd_call($code, 5), 'result', 'systemd_call: delegates to backend');
        is_deeply(\@args, [$code, 5], 'systemd_call: passes code and timeout');
    }
    {
        local $PVE::InitSystem::Backend::MODULE = 'PVE::InitSystem::LSBService';
        eval { PVE::Systemd::systemd_call($code) };
        like($@, qr/not available with the init-system backend 'PVE::InitSystem::LSBService'/,
            'systemd_call: clear error without systemd backend');
    }
}

done_testing();
