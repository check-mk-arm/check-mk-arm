#!/bin/bash
# In-container build driver for Checkmk 2.3.0 on arm64.
#
# Runs inside cmk-arm-build:2.3.0-bookworm, started by ../run.sh. Every stage is
# marked in state/, so a run that dies at hour six resumes where it stopped.
#
#   build.sh                      run every stage
#   build.sh --only fetch-src,unpack-src
#   build.sh --force patch        re-run one stage even if marked done
#   build.sh --list               show stages and their state

# The recipe directory (this file + patches/) is bind-mounted read-only from the
# git worktree. It is mounted as a *directory*: bind-mounting individual files
# pins the inode, so an edit on the host would never become visible inside a
# running container.
PATCHDIR=/opt/build-mk/recipe/patches
source /opt/build-mk/lib/build-common.sh

VERSION="${CMK_VERSION:-2.3.0p49}"
EDITION_SHORT=cre
SRC="$BUILD_ROOT/check-mk-raw-${VERSION}.${EDITION_SHORT}"
STATE="$BUILD_ROOT/state"
TIMINGS="$LOGDIR/timings-${VERSION}.tsv"

SRC_TARBALL="$BUILD_ROOT/check-mk-raw-${VERSION}.${EDITION_SHORT}.tar.gz"
SRC_URL="https://download.checkmk.com/checkmk/${VERSION}/check-mk-raw-${VERSION}.${EDITION_SHORT}.tar.gz"

# The Windows agent cannot be built on Linux/arm64, so we lift the prebuilt
# binaries out of the amd64 Cloud edition package, exactly as the upstream ARM
# recipe has always done. Extraction is arch-independent; only installation
# would care.
DONOR_DEB="$BUILD_ROOT/check-mk-cloud-${VERSION}_0.noble_amd64.deb"
DONOR_URL="https://download.checkmk.com/checkmk/${VERSION}/check-mk-cloud-${VERSION}_0.noble_amd64.deb"

SNAP7_VERSION=1.4.2
SNAP7_7Z="$BUILD_ROOT/snap7-full-${SNAP7_VERSION}.7z"
SNAP7_7Z_URL="https://downloads.sourceforge.net/project/snap7/${SNAP7_VERSION}/snap7-full-${SNAP7_VERSION}.7z"
SNAP7_TARBALL="$DISTDIR/snap7-${SNAP7_VERSION}.tar.gz"
# sha256 of OUR repackaged tarball. Empty on first run: seed-distdir prints the
# value it computed so it can be pinned here and in the snap7 patch.
SNAP7_TARBALL_SHA256="${SNAP7_TARBALL_SHA256:-aa675dfc77a057d99f08254a14217eb1728bde663324c2e622fd1b17f88bf12e}"

DEBFULLNAME="${DEBFULLNAME:-Checkmk ARM64 build}"
DEBEMAIL="${DEBEMAIL:-nobody@example.invalid}"

# Checkmk 2.3 pins Bazel 6.5.0 in .bazelversion, but the release tarball strips
# dotfiles, so bazelisk falls back to "latest" (9.2.0). Bazel 9 enables bzlmod
# unconditionally, ignores WORKSPACE, helpfully writes an empty MODULE.bazel and
# then fails with "No repository visible as '@openssl'". See the git branch for
# the authoritative value.
BAZEL_VERSION="${BAZEL_VERSION:-6.5.0}"

# Checkmk's build_lib.sh hard-exits when the NEXUS_* variables are unset. With
# junk values the mirror fetch simply fails and it falls through to the public
# upstream, which is what we want.
export NEXUS_ARCHIVES_URL="http://127.0.0.1/unused/"
export NEXUS_USERNAME=none
export NEXUS_PASSWORD=none

# Selects the public PyPI in defines.make. Note this does NOT cover the Bazel
# path — omd/packages/python3-modules/BUILD reads INTERNAL_PYPI_MIRROR straight
# out of static_variables.bzl, which is what the 01xx patch fixes.
export USE_EXTERNAL_PIPENV_MIRROR=true

# 3 of 4 cores, and a memory ceiling well under the container's 18 GB so Bazel
# does not race the C++ link jobs into the OOM killer. The disk cache lives in
# /root, which is bind-mounted, so it survives container recreation.
#
# Note the Bazel 6 spelling: --local_ram_resources / --local_cpu_resources.
# The combined `--local_resources=memory=...` form is Bazel 7+ only and 6.5.0
# rejects it outright.
export BAZEL_EXTRA_ARGS="${BAZEL_EXTRA_ARGS:---jobs=3 --local_cpu_resources=3 --local_ram_resources=11000 --disk_cache=/root/.cache/bazel-disk --distdir=$DISTDIR}"

STAGES=(fetch-src unpack-src fetch-donor-deb seed-distdir seed-perl-modules patch
	windows-artifacts venv build-deb collect)

# ------------------------------------------------------------------ stages ---

do_fetch_src() {
	fetch "$SRC_URL" "$SRC_TARBALL"
}

do_unpack_src() {
	unpack_atomic "$SRC_TARBALL" "$SRC"
	log "  unpacked to $SRC ($(du -sh "$SRC" | cut -f1))"
}

do_fetch_donor_deb() {
	fetch "$DONOR_URL" "$DONOR_DEB"
}

# snap7 is the one omd package with no reachable download: snap7_http.bzl lists
# only Checkmk's internal mirror (the SourceForge URL is commented out because
# upstream ships only .7z since 1.4.2). We reproduce the repackaging that their
# own commented-out `snap7-repackage` target documents, adding the aarch64 build
# profile while the tree is open, and hand the result to Bazel via --distdir.
#
# The tar flags are what make the output byte-reproducible, so the sha256 can be
# pinned in a patch instead of recomputed on every build.
do_seed_distdir() {
	if [ -f "$SNAP7_TARBALL" ] && [ -n "$SNAP7_TARBALL_SHA256" ]; then
		local have
		have=$(sha256sum "$SNAP7_TARBALL" | cut -d' ' -f1)
		if [ "$have" = "$SNAP7_TARBALL_SHA256" ]; then
			log "  snap7 tarball present (sha ok)"
			return 0
		fi
	fi

	fetch "$SNAP7_7Z_URL" "$SNAP7_7Z"

	local work="$BUILD_ROOT/tmp/snap7-repack"
	rm -rf "$work"
	mkdir -p "$work"
	7z x -y -o"$work" "$SNAP7_7Z" >/dev/null
	[ -d "$work/snap7-full-${SNAP7_VERSION}" ] ||
		die "unexpected .7z layout: $(ls "$work")"

	# strip_prefix in snap7_http.bzl is "snap7-<version>"
	mv "$work/snap7-full-${SNAP7_VERSION}" "$work/snap7-${SNAP7_VERSION}"

	local unix="$work/snap7-${SNAP7_VERSION}/build/unix"
	[ -f "$unix/arm_v6_linux.mk" ] || die "no arm_v6_linux.mk to derive aarch64 from"
	sed 's/arm_v6/aarch64/g' "$unix/arm_v6_linux.mk" >"$unix/aarch64_linux.mk"
	log "  added build/unix/aarch64_linux.mk"

	mkdir -p "$DISTDIR"
	(
		cd "$work" &&
			tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
				-cf - "snap7-${SNAP7_VERSION}/build" "snap7-${SNAP7_VERSION}/src" \
				"snap7-${SNAP7_VERSION}"/*.txt | gzip -9 -n
	) >"$SNAP7_TARBALL.part"
	mv "$SNAP7_TARBALL.part" "$SNAP7_TARBALL"
	rm -rf "$work"

	local sha
	sha=$(sha256sum "$SNAP7_TARBALL" | cut -d' ' -f1)
	log "  snap7 tarball: $(du -h "$SNAP7_TARBALL" | cut -f1)  sha256=$sha"
	if [ -z "$SNAP7_TARBALL_SHA256" ]; then
		log "  NOTE: pin this sha in build.sh and the snap7 patch"
	elif [ "$sha" != "$SNAP7_TARBALL_SHA256" ]; then
		die "snap7 repack sha changed: got $sha want $SNAP7_TARBALL_SHA256"
	fi
}

# ~250 CPAN tarballs are pinned at exact versions, but many of the public URLs
# point at www.cpan.org/modules/by-module/, which only serves each
# distribution's *current* release — so every pinned older version 404s. Rather
# than patch 250 URLs, resolve them against MetaCPAN/BackPAN once and drop them
# in the distdir, which Bazel checks (by name and sha256) before any download.
do_seed_perl_modules() {
	python3 /opt/build-mk/lib/seed-perl-modules.py \
		"$SRC/omd/packages/perl-modules/perl-modules_http.bzl" "$DISTDIR"
}

do_patch() {
	apply_patches "$SRC" "$PATCHDIR"
}

do_windows_artifacts() {
	local work="$BUILD_ROOT/tmp/donor"
	rm -rf "$work"
	mkdir -p "$work"

	(cd "$work" && ar x "$DONOR_DEB" && tar -I zstd -xf data.tar.zst)

	local wsrc="$work/opt/omd/versions/${VERSION}.cce/share/check_mk/agents/windows"
	[ -d "$wsrc" ] || die "windows agents not found at $wsrc"

	rm -rf "$SRC/agents/windows"
	mv "$wsrc" "$SRC/agents/"

	# artifacts.make on 2.3 lists check_mk_agent_unsigned.msi as a required
	# source-built artifact, but the Cloud deb ships only the signed one.
	# (Upstream dropped this entry in 2.4.)
	local wdir="$SRC/agents/windows"
	if [ ! -f "$wdir/check_mk_agent_unsigned.msi" ] && [ -f "$wdir/check_mk_agent.msi" ]; then
		cp "$wdir/check_mk_agent.msi" "$wdir/check_mk_agent_unsigned.msi"
		log "  synthesised check_mk_agent_unsigned.msi from the signed one"
	fi

	rm -rf "$work"
	log "  windows agents: $(ls "$wdir" | tr '\n' ' ')"
}

# The image already ships the pinned pipenv; this stage only repairs an image
# that does not. Self-healing rather than marker-driven, because pipenv lives in
# the container layer while the stage marker lives on the bind mount.
do_venv() {
	if ! command -v pipenv >/dev/null 2>&1; then
		log "  pipenv missing — running upstream install-pipenv.sh"
		(cd "$SRC" && bash buildscripts/infrastructure/build-nodes/scripts/install-pipenv.sh)
	fi
	log "  pipenv: $(pipenv --version)"
	log "  python3.12: $(python3.12 --version)"
}

# Deliberately NOT `make deb`.
#
# omd/Makefile's deb: target runs `debuild ... -- clean build-arch binary-arch`,
# and its clean: does `rm -rf $(BUILD_HELPER_DIR) $(BUILD_BASE_DIR)
# $(PACKAGE_BUILD_DIR)` — i.e. every retry rebuilds all the non-Bazel packages
# from zero. debian/rules' install: is explicitly written for incremental builds
# ("Keep the package installation directory ... In case a fresh build is
# requested, debuild will be called with clean"), so we simply omit `clean` and
# get cheap retries. Set CMK_FULL_CLEAN=1 for a scratch build.
#
# The added --set-envvar lines matter: debuild sanitises the environment, and
# upstream's target preserves neither USE_EXTERNAL_PIPENV_MIRROR (without which
# defines.make falls back to the unreachable internal devpi mirror) nor our
# rustup location.
# Put back the files the release tarball drops but the build needs. These are
# not patches — they are verbatim restorations of what the git tree has.
restore_tarball_omissions() {
	if [ ! -f "$SRC/.bazelversion" ]; then
		echo "$BAZEL_VERSION" >"$SRC/.bazelversion"
		log "  restored .bazelversion = $BAZEL_VERSION"
	fi
	# Droppings from an accidental Bazel 9 run: 2.3 is WORKSPACE-only and has no
	# MODULE.bazel upstream, so leaving these would keep bzlmod half-enabled.
	if [ -f "$SRC/MODULE.bazel" ] && grep -q "issues/18958" "$SRC/MODULE.bazel" 2>/dev/null; then
		rm -f "$SRC/MODULE.bazel" "$SRC/MODULE.bazel.lock"
		log "  removed auto-generated MODULE.bazel"
	fi
}

do_build_deb() {
	local phases=(build-arch binary-arch)
	[ "${CMK_FULL_CLEAN:-}" = 1 ] && phases=(clean "${phases[@]}")

	restore_tarball_omissions

	cd "$SRC/omd"
	make debian/changelog debian/control \
		DEBFULLNAME="$DEBFULLNAME" DEBEMAIL="$DEBEMAIL"

	DEBFULLNAME="$DEBFULLNAME" DEBEMAIL="$DEBEMAIL" debuild \
		--preserve-envvar="NEXUS_*" \
		--preserve-envvar="BAZEL_*" \
		--preserve-envvar="MAKE" \
		--preserve-envvar="CI" \
		--preserve-envvar="RUSTUP_HOME" \
		--preserve-envvar="CARGO_HOME" \
		--preserve-envvar="USE_EXTERNAL_PIPENV_MIRROR" \
		--preserve-envvar="PIP_BREAK_SYSTEM_PACKAGES" \
		--prepend-path="$CARGO_HOME/bin:/usr/local/bin" \
		--set-envvar EDITION=raw \
		--no-lintian \
		-i\.git -I\.git \
		-i.gitignore -I.gitignore \
		-rfakeroot \
		--no-sign -- "${phases[@]}"
}

do_collect() {
	mkdir -p "$BUILD_ROOT/debs"
	local found=0 f
	shopt -s nullglob
	for f in "$BUILD_ROOT"/check-mk-raw-${VERSION}*.deb "$SRC"/check-mk-raw-${VERSION}*.deb; do
		cp -f "$f" "$BUILD_ROOT/debs/"
		found=1
	done
	shopt -u nullglob
	[ "$found" = 1 ] || die "no check-mk-raw-${VERSION}*.deb produced"

	(
		cd "$BUILD_ROOT/debs"
		for f in check-mk-raw-${VERSION}*.deb; do
			sha256sum "$f" >"$f.sha256"
			log "  $f  $(du -h "$f" | cut -f1)"
			dpkg-deb -I "$f" | grep -E '^ (Package|Version|Architecture|Installed-Size):' | sed 's/^/    /'
		done
	)
}

# -------------------------------------------------------------------- main ---

ONLY=""
while [ $# -gt 0 ]; do
	case "$1" in
	--only)
		ONLY="$2"
		shift 2
		;;
	--force)
		FORCE_STAGE="$2"
		export FORCE_STAGE
		shift 2
		;;
	--list)
		for s in "${STAGES[@]}"; do
			if [ -f "$STATE/$s.done" ]; then
				printf '  %-20s done  %s\n' "$s" "$(date -r "$STATE/$s.done" '+%F %T')"
			else
				printf '  %-20s pending\n' "$s"
			fi
		done
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

mkdir -p "$STATE" "$LOGDIR" "$DISTDIR" "$BUILD_ROOT/tmp" "$BUILD_ROOT/debs"
start_logging
require_cmds curl tar 7z ar zstd patch make gcc g++-14 node npm bazel rustc python3 pip3 dpkg-deb

log "Checkmk $VERSION — arm64 / bookworm"
log "src=$SRC"
log "BAZEL_EXTRA_ARGS=$BAZEL_EXTRA_ARGS"

wanted() {
	[ -z "$ONLY" ] && return 0
	case ",$ONLY," in *",$1,"*) return 0 ;; esac
	return 1
}

for s in "${STAGES[@]}"; do
	wanted "$s" || continue
	stage "$s" "do_${s//-/_}"
done

log "all requested stages complete"
