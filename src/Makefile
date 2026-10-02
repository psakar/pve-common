
PREFIX=/usr
BINDIR=$(PREFIX)/bin
MANDIR=$(PREFIX)/share/man
DOCDIR=$(PREFIX)/share/doc
MAN1DIR=$(MANDIR)/man1/
PERLDIR=$(PREFIX)/share/perl5

# Which init-system backend PVE::InitSystem is built against. Can be
# overridden on the command line, e.g. by debian/rules depending on which
# Debian build profile is active (see debian/control's
# pkg.pve-common.sysvinit profile).
PVE_INIT_SYSTEM ?= systemd

ifeq ($(PVE_INIT_SYSTEM),systemd)
INIT_SYSTEM_BACKEND = Systemd
else ifeq ($(PVE_INIT_SYSTEM),sysvinit)
INIT_SYSTEM_BACKEND = LSBService
else
$(error unsupported PVE_INIT_SYSTEM '$(PVE_INIT_SYSTEM)' (expected 'systemd' or 'sysvinit'))
endif

LIB_SOURCES = \
	AtomicFile.pm \
	CGroup.pm \
	CLIFormatter.pm \
	CLIHandler.pm \
	CalendarEvent.pm \
	Certificate.pm \
	Cmd.pm \
	CpuSet.pm \
	Daemon.pm \
	Exception.pm \
	File.pm \
	Format.pm \
	INotify.pm \
	IPRoute2.pm \
	InitSystem.pm \
	InitSystem/Backend.pm \
	InitSystem/$(INIT_SYSTEM_BACKEND).pm \
	JSONSchema.pm \
	Job/Registry.pm \
	LDAP.pm \
	Network.pm \
	Network/Interfaces.pm \
	OTP.pm \
	PBSClient.pm \
	PTY.pm \
	ParseUtils.pm \
	ProcFSTools.pm \
	RESTEnvironment.pm \
	RESTHandler.pm \
	SafeSyslog.pm \
	Seccomp.pm \
	SectionConfig.pm \
	SysFSTools.pm \
	Syscall.pm \
	Systemd.pm \
	Ticket.pm \
	Tools.pm \
	UPID.pm \

all: PVE/InitSystem/Backend.pm

# Generated from the template according to PVE_INIT_SYSTEM/INIT_SYSTEM_BACKEND
# above. FORCE is needed since the content depends on a variable, not just on
# the mtime of the .in file - without it, switching PVE_INIT_SYSTEM between
# invocations would silently keep a stale Backend.pm from a previous build.
PVE/InitSystem/Backend.pm: PVE/InitSystem/Backend.pm.in FORCE
	sed -e 's/@INIT_SYSTEM_BACKEND@/$(INIT_SYSTEM_BACKEND)/' $< > $@

.PHONY: FORCE
FORCE:

install: $(addprefix PVE/,$(LIB_SOURCES))
	install -d -m 0755 $(DESTDIR)$(PERLDIR)/PVE
	install -d -m 0755 $(DESTDIR)$(PERLDIR)/PVE/InitSystem
	install -d -m 0755 $(DESTDIR)$(PERLDIR)/PVE/Job
	install -d -m 0755 $(DESTDIR)$(PERLDIR)/PVE/Network
	for i in $(LIB_SOURCES); do install -D -m 0644 PVE/$$i $(DESTDIR)$(PERLDIR)/PVE/$$i; done

.PHONY: check check-pod check-syntax
check: check-pod check-syntax

check-pod: $(addprefix PVE/,$(LIB_SOURCES))
	podchecker -nowarnings $^ || [ $$? -eq 2 ]

check-syntax: $(addprefix check-syntax-PVE/,$(LIB_SOURCES))

check-syntax-PVE/%: PVE/InitSystem/Backend.pm
	perl -I. -wc PVE/$*


.PHONY: clean
clean:
	rm -rf *~
	rm -f PVE/InitSystem/Backend.pm

.PHONY: distclean
distclean: clean

