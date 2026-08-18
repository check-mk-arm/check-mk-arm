#!/bin/bash
# In-container build driver for Checkmk 2.5.0 on arm64.
#
# Runs inside cmk-arm-build:2.5.0-trixie, started by ../run.sh. Every stage is
# marked in state/, so a run that dies at hour six resumes where it stopped.
#
#   build.sh                      run every stage
#   build.sh --only fetch-src,unpack-src
#   build.sh --force patch        re-run one stage even if marked done
#   build.sh --list               show stages and their state
#
# Differences from the 2.4 recipe, all forced by upstream changes:
#   * the package is a Bazel target. `omd/Makefile` and `omd/debian/rules` are
#     gone; `bazel build //omd:deb_community` produces the .deb through
#     rules_pkg. No debuild, no incremental-install workarounds, and none of the
#     0300-series idempotency patches 2.4 needed,
#   * no `venv` and no `frontend` stage: rules_uv creates the venv and
#     aspect_rules_js/webpack build packages/cmk-frontend{,-vue} inside Bazel,
#   * "Raw" is called "community" from 2.5 on — in the edition flag, the target
#     name, the tarball name and the package name,
#   * agents/linux/{cmk-agent-ctl*,mk-sql} are no longer in the tarball either,
#     so they are lifted from the donor package alongside the Windows agents,
#   * snap7 is fetched from SourceForge by a repository rule that unpacks the
#     .7z itself, so the local repackaging 2.4 did is gone.
#
# The recipe directory (this file + patches/ + files/) is bind-mounted read-only
# from the git worktree. It is mounted as a *directory*: bind-mounting individual
# files pins the inode, so an edit on the host would never become visible inside
# a running container.
RECIPE=/opt/build-mk/recipe
PATCHDIR="$RECIPE/patches"
source /opt/build-mk/lib/build-common.sh

VERSION="${CMK_VERSION:-2.5.0p11}"
EDITION=community
SRC="$BUILD_ROOT/check-mk-${EDITION}-${VERSION}"
STATE="$BUILD_ROOT/state"
TIMINGS="$LOGDIR/timings-${VERSION}.tsv"

# 2.5 dropped the edition short code from the source tarball's name (2.4 was
# check-mk-raw-<ver>.cre.tar.gz).
SRC_TARBALL="$BUILD_ROOT/check-mk-${EDITION}-${VERSION}.tar.gz"
SRC_URL="https://download.checkmk.com/checkmk/${VERSION}/check-mk-${EDITION}-${VERSION}.tar.gz"

# The Windows agent cannot be built on Linux/arm64 and the Linux agent
# controller is a musl cross-build we have no toolchain for, so both are lifted
# out of the amd64 Ultimate edition package — what 2.4 and earlier called Cloud.
# Extraction is arch-independent; only installation would care.
DONOR_EDITION=ultimate
DONOR_DEB="$BUILD_ROOT/check-mk-${DONOR_EDITION}-${VERSION}_0.noble_amd64.deb"
DONOR_URL="https://download.checkmk.com/checkmk/${VERSION}/check-mk-${DONOR_EDITION}-${VERSION}_0.noble_amd64.deb"

# Upstream tarballs whose URL in the tree cannot be used, seeded into the distdir
# where Bazel matches them by name and sha256 before attempting any download.
# Format: filename|sha256|url   (sha256 must match the pin in the tree)
#
#  * patch-2.7.6 is fetched from ftpmirror.gnu.org, a redirector that regularly
#    lands on a broken mirror ("GET returned 502 Bad Gateway"); ftp.gnu.org is
#    stable. Pinned in bazel/thirdparty/modules/patch/2.7.6.cmk.1/source.json.
#  * jaeger's arm64 release asset — the URL works, but patch 0010 has to pin its
#    sha256 anyway, so seeding it costs nothing and saves 59 MB per cold build.
#    (2.5 repointed heirloom-mailx at anduin.linuxfromscratch.org, which works,
#    so unlike 2.3/2.4 it needs no seed.)
EXTRA_SEEDS=(
	"patch-2.7.6.tar.gz|8cf86e00ad3aaa6d26aca30640e86b0e3e1f395ed99f189b06d4c9f74bc58a4e|https://ftp.gnu.org/gnu/patch/patch-2.7.6.tar.gz"
	"jaeger-2.18.0-linux-arm64.tar.gz|a4c245e1e928ce16e89ae995cecf6cda748d24a8fff6e7ca84758552563a04e5|https://github.com/jaegertracing/jaeger/releases/download/v2.18.0/jaeger-2.18.0-linux-arm64.tar.gz"
)

# `make dist` builds the release tarball with `tar ... * .werks`, and a shell
# glob does not match dotfiles — so every dotfile in the repository *root* is
# missing from the tarball while dotfiles in subdirectories survive. Eight of
# them are load-bearing and are restored verbatim from files/; the rest are
# lint/editor config. See restore_tarball_omissions().
#
# files/* are byte-for-byte copies from the v2.5.0p11 tag. Do not hand-write
# them: .bazeliskrc needs its BAZELISK_BASE_URL line as well as
# USE_BAZEL_VERSION, or bazelisk reads "aspect/2025.51.5" as a fork on
# github.com/aspect/bazel and 404s.
TARBALL_OMISSIONS=(
	.bazelversion
	.bazeliskrc
	.bazelrc
	.bazelignore
	.npmrc
	.clang-tidy
	.prettierignore
	.cargo/config.toml
)

# Everything Bazel-related lives in /etc/ci.bazelrc instead (see bazelrc.local).
export BAZEL_EXTRA_ARGS="${BAZEL_EXTRA_ARGS:-}"

STAGES=(fetch-src unpack-src fetch-donor-deb seed-distdir seed-perl-modules patch
	donor-artifacts repin-crates build-deb collect)

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

do_seed_distdir() {
	local entry name sha url
	for entry in "${EXTRA_SEEDS[@]}"; do
		IFS='|' read -r name sha url <<<"$entry"
		fetch "$url" "$DISTDIR/$name" "$sha"
	done
}

# ~85 CPAN tarballs are pinned at exact versions, but many of the public URLs
# point at www.cpan.org/modules/by-module/, which only serves each
# distribution's *current* release — so every pinned older version 404s. Rather
# than patch 85 URLs, resolve them against MetaCPAN/BackPAN once and drop them
# in the distdir, which Bazel checks (by name and sha256) before any download.
#
# 2.5 moved the list out of omd/packages/perl-modules into the local Bazel
# registry under bazel/thirdparty; the dict format is unchanged.
do_seed_perl_modules() {
	python3 /opt/build-mk/lib/seed-perl-modules.py \
		"$SRC/bazel/thirdparty/modules/perl-modules/0.0.1.cmk.5/src/extensions.bzl" \
		"$DISTDIR"
}

do_patch() {
	apply_patches "$SRC" "$PATCHDIR"
}

# Two sets of prebuilt agent payloads that the release tarball no longer carries
# and that cannot be produced here:
#
#   * agents/windows/* — the Windows agent is built on a Windows node. The
#     tarball ships check_mk_agent.exe and friends but not the .msi, the cab,
#     the hashes file, check_mk.user.yml or unsign-msi.patch, all of which
#     //agents/windows:agents lists as required inputs.
#   * agents/linux/* — cmk-agent-ctl and mk-sql are static musl binaries for
#     *monitored hosts*, x86_64 and (new in 2.5) aarch64. agents/Makefile builds
#     them through Bazel's musl toolchains, which only run on an x86_64 exec
#     platform. //agents:agents-linux lists all five by name, so they have to
#     exist. Taking them from the donor gives byte-identical payloads to the
#     official build rather than a second-source rebuild.
#
# Both are architecture-independent from this package's point of view: they are
# shipped for deployment to other hosts and never run on the server.
do_donor_artifacts() {
	local work="$BUILD_ROOT/tmp/donor"
	rm -rf "$work"
	mkdir -p "$work"

	(cd "$work" && ar x "$DONOR_DEB" && tar -I zstd -xf data.tar.zst)

	local share="$work/opt/omd/versions/${VERSION}.${DONOR_EDITION}/share/check_mk/agents"
	[ -d "$share/windows" ] || die "windows agents not found at $share/windows"
	[ -d "$share/linux" ] || die "linux agents not found at $share/linux"

	mkdir -p "$SRC/agents/windows" "$SRC/agents/linux"
	cp -a "$share/windows"/. "$SRC/agents/windows"/
	cp -a "$share/linux"/. "$SRC/agents/linux"/

	local f
	for f in check_mk_agent.msi python-3.cab windows_files_hashes.txt \
		check_mk.user.yml unsign-msi.patch robotmk_ext.exe mk-sql.exe; do
		[ -s "$SRC/agents/windows/$f" ] ||
			die "//agents/windows:agents requires agents/windows/$f, which the donor did not provide"
	done
	for f in cmk-agent-ctl cmk-agent-ctl.gz cmk-agent-ctl-aarch64 \
		cmk-agent-ctl-aarch64.gz mk-sql; do
		[ -s "$SRC/agents/linux/$f" ] ||
			die "//agents:agents-linux requires agents/linux/$f, which the donor did not provide"
	done

	rm -rf "$work"
	log "  windows: $(ls "$SRC/agents/windows" | tr '\n' ' ')"
	log "  linux:   $(ls "$SRC/agents/linux" | tr '\n' ' ')"
}

# crate_universe pins its resolution per target triple, and patch 0013 adds
# aarch64-unknown-linux-gnu to @site_crates (check-cert and check-http are part
# of the package). The checked-in site.Cargo.lock.bazel was generated for
# x86_64 alone, so Bazel refuses it with a digest mismatch until it is
# regenerated. CARGO_BAZEL_REPIN re-splices it from the unchanged Cargo.lock —
# no dependency is resolved differently, only the per-platform select() tables
# gain an aarch64 column.
#
# Done as its own stage, and not as a permanent --repo_env, because the variable
# is part of the repository rule's cache key: leaving it set would re-pin on
# every build.
do_repin_crates() {
	cd "$SRC"
	CARGO_BAZEL_REPIN=true bazel fetch @site_crates//... ||
		die "re-pinning @site_crates failed"
	log "  site.Cargo.lock.bazel re-pinned for aarch64"
}

# `bazel build //omd:deb_community`. The version and edition come in as build
# flags (--cmk_version/--cmk_edition are flag_aliases defined in .bazelrc); the
# distro comes from /etc/ci.bazelrc. The .deb lands in bazel-bin/omd/.
do_build_deb() {
	cd "$SRC"
	bazel build \
		--cmk_version="$VERSION" \
		--cmk_edition="$EDITION" \
		$BAZEL_EXTRA_ARGS \
		"//omd:deb_${EDITION}"
}

do_collect() {
	mkdir -p "$BUILD_ROOT/debs"
	local found=0 f
	shopt -s nullglob
	for f in "$SRC"/bazel-bin/omd/check-mk-${EDITION}-${VERSION}*.deb; do
		# bazel-bin is a symlink into the read-only output tree.
		install -m 644 "$f" "$BUILD_ROOT/debs/"
		found=1
	done
	shopt -u nullglob
	[ "$found" = 1 ] || die "no check-mk-${EDITION}-${VERSION}*.deb produced"

	(
		cd "$BUILD_ROOT/debs"
		for f in check-mk-${EDITION}-${VERSION}*.deb; do
			sha256sum "$f" >"$f.sha256"
			log "  $f  $(du -h "$f" | cut -f1)"
			dpkg-deb -I "$f" | grep -E '^ (Package|Version|Architecture|Installed-Size):' | sed 's/^/    /'
		done
	)
}

# ------------------------------------------------------------------ setup ---

# Put back the files the release tarball drops but the build needs. These are
# not patches — each is a verbatim copy of the file in the v2.5.0p11 tag.
#
# Without .bazelversion/.bazeliskrc bazelisk installs the newest Bazel, and
# without .bazelrc the build loses --@cmk//distro (every omd package then fails
# its select() with "Please build with lsb or fhs filesystem layout"), the
# --flag_alias definitions that turn --cmk_version/--cmk_edition into real
# flags, the local module registry under bazel/thirdparty and the
# --workspace_status_command. .bazelignore keeps Bazel out of bazel/cmk (a
# local_path_override module) and bazel/thirdparty; .npmrc and .cargo/config.toml
# are named directly by bazel/module/js.MODULE.bazel and
# bazel/module/rust/host.MODULE.bazel; .clang-tidy and .prettierignore are named
# by the root BUILD's exports_files, which fails to load if a listed file is
# absent.
restore_tarball_omissions() {
	local f
	for f in "${TARBALL_OMISSIONS[@]}"; do
		[ -f "$SRC/$f" ] && continue
		mkdir -p "$(dirname "$SRC/$f")"
		# files/ is flat: .cargo/config.toml is stored as cargo_config.toml.
		install -m 644 "$RECIPE/files/$(echo "${f#.}" | tr '/' '_')" "$SRC/$f"
		log "  restored $f from the recipe"
	done
}

# Installed on every invocation rather than baked into the image, so editing
# bazelrc.local on the host takes effect on the next run. /etc/ci.bazelrc is the
# last try-import in .bazelrc that the tarball can supply, which is what makes
# it win.
install_bazelrc() {
	install -m 644 "$RECIPE/bazelrc.local" /etc/ci.bazelrc

	# On a runner every build is cold, so the disk cache can only ever be
	# written, never read — 12 GB of duplicated action outputs on top of the
	# 20 GB output base. Disk is the binding constraint in CI (~46 GB free
	# against ~36 GB used with the cache on), so switch it off there. An empty
	# path is how Bazel disables it; both the plain and the :linux form are
	# needed for the same reason bazelrc.local sets both.
	if [ "${CI:-}" = true ]; then
		printf '%s\n' \
			'' \
			'# appended by build.sh because CI=true' \
			'common --disk_cache=' \
			'common:linux --disk_cache=' \
			>>/etc/ci.bazelrc
	fi

	: >/etc/bazel-downloader-none.cfg
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
require_cmds curl tar ar zstd patch make gcc g++-14 bazel python3 dpkg-deb git \
	cmake pkg-config perl

log "Checkmk $VERSION ($EDITION) — arm64 / trixie"
log "src=$SRC"

install_bazelrc
log "installed /etc/ci.bazelrc${CI:+ (CI=$CI — Bazel disk cache off)}"

wanted() {
	[ -z "$ONLY" ] && return 0
	case ",$ONLY," in *",$1,"*) return 0 ;; esac
	return 1
}

for s in "${STAGES[@]}"; do
	wanted "$s" || continue
	# Cheap, idempotent and needed by every stage from `patch` onwards; doing it
	# here rather than inside one stage means a resumed run still gets it.
	[ -d "$SRC" ] && restore_tarball_omissions
	stage "$s" "do_${s//-/_}"
done

log "all requested stages complete"
