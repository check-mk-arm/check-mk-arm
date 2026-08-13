#!/bin/bash
# Post-build acceptance checks for the arm64 package.
#
# These are the checks that were run by hand while getting 2.3 to build; encoding
# them here is what turns "it built" into "it is the package we meant to ship".
# Runs on the host (or the runner), not in the build container — it deliberately
# uses a *clean* Debian image for the install test rather than the builder image,
# because dependency resolution against real bookworm is what has broken before.
#
#   ci/verify-deb.sh [debs-directory]
#
# The directory defaults to the one ./run.sh writes, honouring CMK_DATA and
# CMK_VERSION exactly as run.sh does.

set -Eeuo pipefail

VERSION="${CMK_VERSION:-2.3.0p49}"
MINOR="${VERSION%%p*}"

case "$MINOR" in
2.3.0) DISTRO=bookworm ;;
2.4.0) DISTRO=trixie ;;
*) echo "unknown Checkmk minor '$MINOR' — teach verify-deb.sh its distro" >&2; exit 1 ;;
esac

DATA="${CMK_DATA:-/data/checkmk}"
DEBDIR="${1:-$DATA/work/$VERSION/debs}"
DEB="$DEBDIR/check-mk-raw-${VERSION}_0.${DISTRO}_arm64.deb"
BASE_IMAGE="debian:${DISTRO}-slim"

# The x86-64 binaries that are *supposed* to be in an arm64 package: agent
# payloads shipped for deployment to x86 hosts, which never run on the server.
# Paths are relative to the version directory. A change here is a decision, not
# a formality — anything new in this list must be justified in the README.
EXPECTED_X86=(
	share/check_mk/agents/linux/cmk-agent-ctl
	share/check_mk/agents/linux/mk-sql
	share/check_mk/agents/waitmax
	share/doc/check_mk/treasures/modbus/agents/special/agent_modbus
)

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
check_field Package "check-mk-raw-${VERSION}"
check_field Version "0.${DISTRO}"
check_field Architecture arm64

# ------------------------------------------------------------ ELF sweep ------

# The failure this catches: a server binary that silently got built for, or
# copied in as, x86-64 — which installs fine and then dies at runtime.
step "ELF architecture sweep"
EXTRACT=$(mktemp -d)
dpkg-deb -x "$DEB" "$EXTRACT"

VERDIR="$EXTRACT/opt/omd/versions/${VERSION}.cre"
[ -d "$VERDIR" ] || die "no version directory at opt/omd/versions/${VERSION}.cre"

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

mapfile -t expected < <(printf '%s\n' "${EXPECTED_X86[@]}" | sort)

if [ "${foreign[*]-}" = "${expected[*]}" ]; then
	pass "the only ${#foreign[@]} non-aarch64 ELF binaries are the known agent payloads"
else
	fail "unexpected set of non-aarch64 ELF binaries:"
	diff <(printf '%s\n' "${expected[@]}") <(printf '%s\n' "${foreign[@]-}") |
		sed 's/^/        /' >&2 || true
fi

# Second, independent gate: a bare count would let a genuine server-binary
# regression through if it happened to displace one of the four.
for f in "${foreign[@]-}"; do
	case "$f" in
	*/agents/*) ;;
	*) fail "non-aarch64 binary outside an agents/ path: $f" ;;
	esac
done

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
