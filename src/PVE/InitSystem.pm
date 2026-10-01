package PVE::InitSystem;

# Backend-agnostic facade for init-system specific operations: service
# control, resource scopes used to confine VM/CT processes, and timezone
# management.
#
# The concrete backend (currently only PVE::InitSystem::Systemd) is selected
# right here, by aliasing its subs into this package's namespace. This is the
# single place a build-time mechanism - e.g. a Debian build profile switching
# between PVE::InitSystem::Systemd and a future PVE::InitSystem::SysVInit -
# needs to touch. Callers must go through this module and must not reference
# a backend module directly, so that they keep working unchanged no matter
# which backend was selected at build time.

use strict;
use warnings;

use PVE::InitSystem::Systemd;

my $backend = 'PVE::InitSystem::Systemd';

my @interface = qw(
    enter_systemd_scope
    wait_for_unit_removed
    is_unit_active
    start_service
    stop_service
    restart_service
    get_timezone
    set_timezone
    list_timezones
);

for my $sym (@interface) {
    no strict 'refs';
    *{$sym} = \&{"${backend}::${sym}"};
}

1;
