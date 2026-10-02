#!/usr/bin/perl -T

# The LSBService backend also runs in the API daemons, which use taint checks
# (perl -T). What it reads from the system itself - scope paths found via
# glob(), PIDs from cgroup.procs, instance marker names - must be untainted
# before it's used to change the system, or that dies there with "Insecure
# dependency in ..." (e.g. the rmdir of a VM's leftover scope on VM start).
# Callers' arguments come untainted (PVE::RESTHandler untaints validated API
# parameters), as they do here.

use v5.36;

use lib '../src';

use File::Path qw(make_path remove_tree);
use POSIX ();
use Test::MockModule;
use Test::More;

use PVE::File qw(file_get_contents file_set_contents);
use PVE::InitSystem::LSBService;

$ENV{PATH} = '/usr/sbin:/usr/bin:/sbin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

my $test_dir = "/tmp/test-initsystem-taint-$$";
make_path($test_dir);
END { remove_tree($test_dir) if defined($test_dir) }

# A child process to signal, sleeping until it gets one.
my sub spawn_sleeper() {
    my $pid = fork() // die "fork failed - $!\n";
    if (!$pid) {
        sleep(60);
        POSIX::_exit(0);
    }
    return $pid;
}

# Signal number the child was terminated with, waiting at most 5 seconds.
my sub terminated_by($pid) {
    for (1 .. 50) {
        return $? & 127 if waitpid($pid, POSIX::WNOHANG()) == $pid;
        select(undef, undef, undef, 0.1);
    }
    kill('KILL', $pid);
    waitpid($pid, 0);
    return undef;
}

# --- scopes (fake cgroupfs) -------------------------------------------------

{
    my $cg = "$test_dir/cgroup";
    my $cgroup_mock = Test::MockModule->new('PVE::CGroup');
    $cgroup_mock->redefine(cgroup_mode => sub { 2 }, cgroupv2_base_path => sub { $cg });

    for my $scope (qw(100 101 102 103 104)) {
        make_path("$cg/qemu.slice/$scope.scope");
    }

    # an emptied scope gets removed: on a real cgroupfs, rmdir() removes it with
    # its interface files, here it just fails - but mustn't die
    file_set_contents("$cg/qemu.slice/100.scope/cgroup.events", "populated 0\nfrozen 0\n");
    my $removed = eval { PVE::InitSystem::LSBService::wait_for_unit_removed('100.scope', 1) };
    is($@, '', 'wait_for_unit_removed: rmdir of the found scope works under -T');
    ok($removed, 'wait_for_unit_removed: emptied scope counts as removed');

    file_set_contents("$cg/qemu.slice/101.scope/cpu.max", "");
    file_set_contents("$cg/qemu.slice/101.scope/cpu.weight", "");
    eval { PVE::InitSystem::LSBService::set_scope_properties('101.scope', CPUQuota => 50, CPUWeight => 200) };
    is($@, '', 'set_scope_properties: writes to the found scope work under -T');
    is(file_get_contents("$cg/qemu.slice/101.scope/cpu.max"), '50000 100000', 'set_scope_properties: CPUQuota');
    is(file_get_contents("$cg/qemu.slice/101.scope/cpu.weight"), '200', 'set_scope_properties: CPUWeight');

    # SIGTERM only: the fake cgroup.procs never empties, so it gives up right away
    my $pid = spawn_sleeper();
    file_set_contents("$cg/qemu.slice/102.scope/cgroup.procs", "$pid\n");
    eval { PVE::InitSystem::LSBService::stop_scope('102.scope', timeout => 0, kill => 0) };
    is($@, '', 'stop_scope: kill of PIDs read from cgroup.procs works under -T');
    is(terminated_by($pid), POSIX::SIGTERM(), 'stop_scope: process got SIGTERM');

    # SIGKILL after the timeout, via kill() as there's no cgroup.kill here
    local $SIG{TERM} = 'IGNORE'; # inherited by the child: needs the SIGKILL
    $pid = spawn_sleeper();
    file_set_contents("$cg/qemu.slice/103.scope/cgroup.procs", "$pid\n");
    eval { PVE::InitSystem::LSBService::stop_scope('103.scope', timeout => 0) };
    is($@, '', 'stop_scope: SIGKILL of PIDs read from cgroup.procs works under -T');
    is(terminated_by($pid), POSIX::SIGKILL(), 'stop_scope: process got SIGKILL');

    # empty scope: removed right away
    file_set_contents("$cg/qemu.slice/104.scope/cgroup.procs", '');
    eval { PVE::InitSystem::LSBService::stop_scope('104.scope') };
    is($@, '', 'stop_scope: rmdir of the found scope works under -T');
}

# --- template service instances ---------------------------------------------

{
    local $PVE::InitSystem::LSBService::INITD_DIR = "$test_dir/init.d";
    local $PVE::InitSystem::LSBService::INSTANCE_ENABLED_DIR = "$test_dir/enabled-instances";
    local $PVE::InitSystem::LSBService::INSTANCE_STARTED_DIR = "$test_dir/started-instances";

    make_path("$test_dir/init.d");
    file_set_contents("$test_dir/init.d/dnsmasq", "#!/bin/sh\nexit 0\n");
    chmod(0755, "$test_dir/init.d/dnsmasq");

    for my $kind (qw(enabled started)) {
        make_path("$test_dir/$kind-instances");
        file_set_contents("$test_dir/$kind-instances/dnsmasq\@$_", '') for qw(zone1 zone2);
    }

    # runs the template's init script for each marker found, for real
    eval { PVE::InitSystem::LSBService::stop_service('dnsmasq@*') };
    is($@, '', 'stop_service: init script runs with instances from marker names under -T');
    ok(!glob("$test_dir/started-instances/*"), 'stop_service: started markers removed');

    eval { PVE::InitSystem::LSBService::disable_service('dnsmasq@') };
    is($@, '', 'disable_service: unlink of marker names found works under -T');
    ok(!glob("$test_dir/enabled-instances/*"), 'disable_service: enabled markers removed');
}

done_testing();
