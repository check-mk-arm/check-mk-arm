#!/bin/bash
# Post-build acceptance checks for the arm64 package.
#
# These are the checks that were run by hand while getting 2.3 to build; encoding
# them here is what turns "it built" into "it is the package we meant to ship".
# Runs on the host (or the runner), not in the build container — it deliberately
# uses a *clean* Debian image for the install test rather than the builder image,
# because dependency resolution against the real target distro is what has broken
# before.
#
#   ci/verify-deb.sh [debs-directory]
#
# The directory defaults to the one ./run.sh writes, honouring CMK_DATA and
# CMK_VERSION exactly as run.sh does.

set -Eeuo pipefail

VERSION="${CMK_VERSION:-2.5.0p11}"
MINOR="${VERSION%%p*}"

# 2.5 renamed the Raw edition to "community", which changes the package name and
# the `<version>.<edition>` directory the package installs into.
case "$MINOR" in
2.2.0) DISTRO=bookworm; EDITION=raw; EDITION_SHORT=cre ;;
2.3.0) DISTRO=bookworm; EDITION=raw; EDITION_SHORT=cre ;;
2.4.0) DISTRO=trixie;   EDITION=raw; EDITION_SHORT=cre ;;
2.5.0) DISTRO=trixie;   EDITION=community; EDITION_SHORT=community ;;
*) echo "unknown Checkmk minor '$MINOR' — teach verify-deb.sh its distro" >&2; exit 1 ;;
esac

DATA="${CMK_DATA:-/data/checkmk}"
DEBDIR="${1:-$DATA/work/$VERSION/debs}"
DEB="$DEBDIR/check-mk-${EDITION}-${VERSION}_0.${DISTRO}_arm64.deb"
BASE_IMAGE="debian:${DISTRO}-slim"

# The x86-64 binaries that are *supposed* to be in an arm64 package: agent
# payloads shipped for deployment to x86 hosts, which never run on the server.
# Paths are relative to the version directory. A change here is a decision, not
# a formality — anything new in this list must be justified in the README.
#
# The list is per-minor because the agent payload differs between releases —
# mk-sql, for one, arrived in 2.3. A minor with no curated list still gets the
# "outside an agents/ path" gate below, which is the one with real teeth; it
# just reports what it found instead of diffing against an expectation nobody
# has established yet.
case "$MINOR" in
2.3.0)
	EXPECTED_X86=(
		share/check_mk/agents/linux/cmk-agent-ctl
		share/check_mk/agents/linux/mk-sql
		share/check_mk/agents/waitmax
		share/doc/check_mk/treasures/modbus/agents/special/agent_modbus
	)
	;;
2.4.0)
	# Two changes from 2.3, both consequences of what the release tarball
	# ships. cmk-agent-ctl and mk-sql are no longer prebuilt in it, so patch
	# 0009 has them compiled here and they come out aarch64. robotmk's
	# linux binaries are prebuilt x86-64 downloads from elabit, installed
	# into the agent payload for deployment to x86 hosts.
	EXPECTED_X86=(
		share/check_mk/agents/plugins/robotmk_agent_plugin
		share/check_mk/agents/robotmk/linux/rcc
		share/check_mk/agents/robotmk/linux/robotmk_scheduler
		share/check_mk/agents/waitmax
		share/doc/check_mk/treasures/modbus/agents/special/agent_modbus
	)
	;;
2.5.0)
	# Four changes from 2.4. mk-oracle arrived as a prebuilt binary shipped
	# in the tarball (Linux and Solaris builds, both x86-64), robotmk gained
	# micromamba, and cmk-agent-ctl and mk-sql are back on the list because
	# 2.5 no longer builds them here at all: they are musl payloads for
	# monitored hosts, lifted from the donor package by build.sh's
	# donor-artifacts stage. The aarch64 agent controller upstream started
	# shipping in 2.5 (werk #19275) comes from the same place and is
	# correctly absent from this list.
	EXPECTED_X86=(
		lib/python3/cmk/plugins/oracle/agents/mk-oracle
		lib/python3/cmk/plugins/oracle/agents/mk-oracle.solaris
		share/check_mk/agents/linux/cmk-agent-ctl
		share/check_mk/agents/linux/mk-sql
		share/check_mk/agents/plugins/robotmk_agent_plugin
		share/check_mk/agents/robotmk/linux/micromamba
		share/check_mk/agents/robotmk/linux/rcc
		share/check_mk/agents/robotmk/linux/robotmk_scheduler
		share/check_mk/agents/waitmax
	)
	;;
*) EXPECTED_X86=() ;;
esac

pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; FAILED=1; }
die() { printf '\n!!! %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

FAILED=0
EXTRACT=""
# The `return 0` is load-bearing: under `set -e` a failing last command in an
# EXIT trap becomes the script's exit status, so a clean run would report 1.
cleanup() {
	[ -n "$EXTRACT" ] && rm -rf "$EXTRACT"
	return 0
}
trap cleanup EXIT

[ -f "$DEB" ] || die "no package at $DEB"
echo "verifying $DEB ($(du -h "$DEB" | cut -f1))"

# ------------------------------------------------------------- checksum ------

step "checksum"
if [ -f "$DEB.sha256" ]; then
	# The .sha256 records a bare filename, so check it from its own directory.
	(cd "$DEBDIR" && sha256sum -c "$(basename "$DEB").sha256" >/dev/null) &&
		pass "sha256 matches $(basename "$DEB").sha256" ||
		fail "sha256 mismatch — the package is corrupt"
else
	fail "no $DEB.sha256 — the release needs it, checkmk_build fetches it"
fi

# ------------------------------------------------------------- metadata ------

step "control metadata"
control=$(dpkg-deb -I "$DEB")
check_field() { # check_field <field> <expected>
	local got
	got=$(sed -n "s/^ $1: //p" <<<"$control")
	[ "$got" = "$2" ] && pass "$1: $got" || fail "$1: got '$got', want '$2'"
}
check_field Package "check-mk-${EDITION}-${VERSION}"
check_field Version "0.${DISTRO}"
check_field Architecture arm64

# ------------------------------------------------------------ ELF sweep ------

# The failure this catches: a server binary that silently got built for, or
# copied in as, x86-64 — which installs fine and then dies at runtime.
step "ELF architecture sweep"
EXTRACT=$(mktemp -d)
dpkg-deb -x "$DEB" "$EXTRACT"

VERDIR="$EXTRACT/opt/omd/versions/${VERSION}.${EDITION_SHORT}"
[ -d "$VERDIR" ] || die "no version directory at opt/omd/versions/${VERSION}.${EDITION_SHORT}"

# file(1) over the whole tree reads only headers and takes well under a minute;
# testing each file from the shell instead costs a minute and a half. Note the
# absent `xargs -P`: parallel file(1) processes share one pipe and their writes
# interleave, splitting lines and inventing "foreign" binaries that are not.
mapfile -t foreign < <(
	find "$EXTRACT" -type f -print0 |
		xargs -0 file -N -F '|' -- |
		awk -F'|' '$2 ~ /^ ELF/ && $2 !~ /ARM aarch64/ { print $1 }' |
		sed "s|^$VERDIR/||" | sort
)

if [ "${#EXPECTED_X86[@]}" -eq 0 ]; then
	pass "found ${#foreign[@]} non-aarch64 ELF binaries (no curated list for $MINOR — recorded, not gated):"
	printf '          %s\n' "${foreign[@]-}"
else
	mapfile -t expected < <(printf '%s\n' "${EXPECTED_X86[@]}" | sort)
	if [ "${foreign[*]-}" = "${expected[*]}" ]; then
		pass "the only ${#foreign[@]} non-aarch64 ELF binaries are the known agent payloads"
	else
		fail "unexpected set of non-aarch64 ELF binaries:"
		diff <(printf '%s\n' "${expected[@]}") <(printf '%s\n' "${foreign[@]-}") |
			sed 's/^/        /' >&2 || true
	fi
fi

# Second, independent gate: a bare count would let a genuine server-binary
# regression through if it happened to displace one of the four.
for f in "${foreign[@]-}"; do
	# An empty array still expands to one empty word here, which would otherwise
	# be reported as a nameless foreign binary — a clean package failing the gate
	# that exists to catch dirty ones.
	[ -n "$f" ] || continue
	case "$f" in
	*/agents/*) ;;
	*) fail "non-aarch64 binary outside an agents/ path: $f" ;;
	esac
done

# ---------------------------------------------------- linux agent packages ----

# The .deb/.rpm the site's agent download page offers, and what the bakery
# builds on. They are payloads for *monitored* hosts, so an arm64 server still
# has to ship the x86-64 ones — a Checkmk server monitors whatever architecture
# you point it at, and dropping them would quietly turn this into an
# arm64-hosts-only server.
#
# The ELF sweep above cannot see any of this: these are archives, so file(1)
# reports them as data and never looks inside. Two distinct failures hide
# behind that, and both have happened:
#
#   * absent — agents/BUILD globs the four names with allow_empty = True, so a
#     package with none of them builds, installs and passes every other check;
#   * present but wrong — agents/Makefile names the packages _all/noarch
#     unconditionally, so if it is left to build them on this host it produces
#     an "architecture-independent" package holding an aarch64 cmk-agent-ctl.
#
# Hence a presence check and, for the x86-64 pair, an architecture check on the
# agent controller inside.
step "linux agent packages"
AGENTDIR="$VERDIR/share/check_mk/agents"
case "$MINOR" in
2.5.0)
	# 2.5 is the first version to ship an aarch64 agent package as well
	# (werk #19275); the tarball carries that pair, build.sh lifts the other.
	EXPECTED_AGENT_PKGS=(
		"check-mk-agent-${VERSION}-1.aarch64.rpm"
		"check-mk-agent-${VERSION}-1.noarch.rpm"
		"check-mk-agent_${VERSION}-1_all.deb"
		"check-mk-agent_${VERSION}-1_arm64.deb"
	)
	;;
*)
	EXPECTED_AGENT_PKGS=(
		"check-mk-agent-${VERSION}-1.noarch.rpm"
		"check-mk-agent_${VERSION}-1_all.deb"
	)
	;;
esac

for p in "${EXPECTED_AGENT_PKGS[@]}"; do
	[ -s "$AGENTDIR/$p" ] && pass "$p present ($(du -h "$AGENTDIR/$p" | cut -f1))" ||
		fail "no $p in share/check_mk/agents — the agent download page cannot serve it"
done

# The controller ships gzipped inside the package and is unpacked by its
# postinst, so this is the binary that actually runs on the monitored host.
ALL_DEB="$AGENTDIR/check-mk-agent_${VERSION}-1_all.deb"
if [ -s "$ALL_DEB" ]; then
	inner=$(mktemp -d)
	if dpkg-deb --fsys-tarfile "$ALL_DEB" |
		tar -xO ./var/lib/cmk-agent/cmk-agent-ctl.gz 2>/dev/null |
		gzip -dc >"$inner/cmk-agent-ctl" 2>/dev/null && [ -s "$inner/cmk-agent-ctl" ]; then
		arch=$(file -b "$inner/cmk-agent-ctl")
		case "$arch" in
		*x86-64*) pass "cmk-agent-ctl inside the _all.deb is x86-64" ;;
		*) fail "cmk-agent-ctl inside the _all.deb is not x86-64: $arch" ;;
		esac
	else
		fail "could not read var/lib/cmk-agent/cmk-agent-ctl.gz out of the _all.deb"
	fi
	rm -rf "$inner"
fi

# --------------------------------------------------------- windows agents ----

# The Windows agent payload is not built here, it is lifted out of an official
# amd64 package. All recipes do that by deleting agents/windows and moving the
# donor's copy into its place, so a donor that failed to download or unpack
# leaves a package that is complete in every other respect and simply has no
# Windows agents. It installs, `omd version` runs, and nobody notices until
# somebody tries to deploy one.
step "windows agent payload"
MSI="$VERDIR/share/check_mk/agents/windows/check_mk_agent.msi"
if [ -s "$MSI" ]; then
	pass "check_mk_agent.msi present ($(du -h "$MSI" | cut -f1))"
else
	fail "no check_mk_agent.msi — the donor deb's agents/windows never made it in"
fi

rm -rf "$EXTRACT"
EXTRACT=""

# ----------------------------------------------------------- install test ----

# Against a clean $BASE_IMAGE, so this exercises real dependency resolution.
step "install smoke test on $BASE_IMAGE"
if docker run --rm -v "$DEB":/tmp/check-mk.deb:ro "$BASE_IMAGE" bash -c '
	set -e
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq /tmp/check-mk.deb
	omd version
'; then
	pass "installs on clean $DISTRO and omd runs"
else
	fail "install smoke test failed"
fi

# ------------------------------------------------------------------ done -----

echo
if [ "$FAILED" = 0 ]; then
	echo "all checks passed"
else
	die "verification failed"
fi
