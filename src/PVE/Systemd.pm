package PVE::Systemd;

# NOTE: the init-manager-specific subs below (systemd_call, enter_systemd_scope,
# wait_for_unit_removed, is_unit_active, get_timezone, set_timezone,
# list_timezones) are kept here only for API compatibility - they delegate
# to PVE::InitSystem or its backend, which is where the actual implementation
# lives. New code should call PVE::InitSystem directly.

use strict;
use warnings;

use IO::Socket::UNIX;
use POSIX qw(EINTR);
use Socket qw(SOCK_DGRAM);

use PVE::File qw(file_set_contents file_get_contents);
use PVE::InitSystem;
use PVE::Tools qw(trim);

sub escape_unit {
    my ($val, $is_path) = @_;

    # NOTE: this is not complete, but enough for our needs. normally all
    # characters which are not alpha-numerical, '.' or '_' would need escaping
    $val =~ s/\-/\\x2d/g;

    if ($is_path) {
        $val =~ s/^\///g;
        $val =~ s/\/$//g;
    }
    $val =~ s/\//-/g;

    return $val;
}

sub unescape_unit {
    my ($val) = @_;

    $val =~ s/-/\//g;
    $val =~ s/\\x([a-fA-F0-9]{2})/chr(hex($1))/eg;

    return $val;
}

# Talks to systemd's manager over D-Bus, see PVE::InitSystem::Systemd. Kept for
# callers needing systemd features beyond PVE::InitSystem's interface, e.g.
# qemu-server changing properties of a running VM's scope. Only available with
# the systemd backend, there's no systemd to talk to otherwise.
sub systemd_call($;$) {
    my $backend = $PVE::InitSystem::Backend::MODULE;
    die "systemd_call is not available with the init-system backend '$backend'\n"
        if $backend ne 'PVE::InitSystem::Systemd';

    # '&' to pass @_ as is, despite the backend sub's ($;$) prototype
    return &PVE::InitSystem::Systemd::systemd_call(@_);
}

# Polling the job status instead doesn't work because this doesn't give us the
# distinction between success and failure.
#
# Note that the description is mandatory for security reasons.
sub enter_systemd_scope {
    return PVE::InitSystem::enter_systemd_scope(@_);
}

sub wait_for_unit_removed($;$) {
    return PVE::InitSystem::wait_for_unit_removed(@_);
}

sub is_unit_active($;$) {
    return PVE::InitSystem::is_unit_active(@_);
}

sub read_ini {
    my ($filename) = @_;

    my $content = file_get_contents($filename);
    my @lines = split /\n/, $content;

    my $result = {};
    my $section;

    foreach my $line (@lines) {
        $line = trim($line);
        if ($line =~ m/^\[([^\]]+)\]/) {
            $section = $1;
            if (!defined($result->{$section})) {
                $result->{$section} = {};
            }
        } elsif ($line =~ m/^(.*?)=(.*)$/) {
            my ($key, $val) = ($1, $2);
            if (!$section) {
                warn "key value pair found without section, skipping\n";
                next;
            }

            if ($result->{$section}->{$key}) {
                # make duplicate properties to arrays to keep the order
                my $prop = $result->{$section}->{$key};
                if (ref($prop) eq 'ARRAY') {
                    push @$prop, $val;
                } else {
                    $result->{$section}->{$key} = [$prop, $val];
                }
            } else {
                $result->{$section}->{$key} = $val;
            }
        }
        # ignore everything else
    }

    return $result;
}

sub write_ini {
    my ($ini, $filename) = @_;

    my $content = "";

    foreach my $sname (sort keys %$ini) {
        my $section = $ini->{$sname};

        $content .= "[$sname]\n";

        foreach my $pname (sort keys %$section) {
            my $prop = $section->{$pname};

            if (!ref($prop)) {
                $content .= "$pname=$prop\n";
            } elsif (ref($prop) eq 'ARRAY') {
                foreach my $val (@$prop) {
                    $content .= "$pname=$val\n";
                }
            } else {
                die "invalid property '$pname'\n";
            }
        }
        $content .= "\n";
    }

    file_set_contents($filename, $content);
}

sub get_timezone {
    return PVE::InitSystem::get_timezone(@_);
}

sub set_timezone {
    return PVE::InitSystem::set_timezone(@_);
}

sub list_timezones {
    return PVE::InitSystem::list_timezones(@_);
}

=head3 notify()

This is a pure Perl reimplementation of systemd's C<sd_notify()> mechanism as defined in
C<systemd/sd-daemon.h>, based on the example implementations in C<man 3 sd_notify>. Does not return
a value, but dies upon error.

=cut

sub notify {
    my ($message) = @_;

    # nothing to do if there is no socket
    my $socket_path = $ENV{NOTIFY_SOCKET} or return;

    die "notify systemd invalid socket path '$socket_path'\n" if $socket_path !~ m|^[/@]|;
    die "notify systemd called without a message\n" if !$message;

    # might be an abstract socket
    $socket_path =~ s/^@/\0/;

    my $socket = IO::Socket::UNIX->new(
        Type => SOCK_DGRAM(),
        Peer => $socket_path,
    ) or die "notify systemd: unable to connect to socket $socket_path - $IO::Socket::errstr\n";

    # we won't be reading from the socket
    $socket->shutdown(SHUT_RD);

    my $res;
    while (1) {
        $res = $socket->send($message);
        if ($res) {
            die "notify systemd: protocol error writing to socket '$socket_path'\n"
                if $res < length($message);
            last;
        } else {
            next if $! == EINTR;
            die "notify systemd: sending to '$socket_path' failed - $!\n";
        }
    }

    close($socket);

    return;
}

1;
