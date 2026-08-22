#!/bin/bash
# In-container build driver for Checkmk 2.4.0 on arm64.
#
# Runs inside cmk-arm-build:2.4.0-trixie, started by ../run.sh. Every stage is
# marked in state/, so a run that dies at hour six resumes where it stopped.
#
#   build.sh                      run every stage
#   build.sh --only fetch-src,unpack-src
#   build.sh --force patch        re-run one stage even if marked done
#   build.sh --list               show stages and their state
#
# Differences from the 2.3 recipe, all forced by upstream changes:
#   * no pipenv/Pipfile — the venv is created by Bazel (rules_uv) and is a build
#     dependency of `make deb` via doc/plugin-api, hence its own stage,
#   * the frontend is no longer shipped prebuilt in the tarball, so npm has to
#     build packages/cmk-frontend{,-vue}/dist before `make deb` can tar it,
#   * the Rust agent binaries are no longer shipped prebuilt either; they are
#     built from source for aarch64-musl (patch 0009),
#   * .bazelrc/.bazeliskrc/.bazelversion are all restored (see below), and our
#     own Bazel settings go into /etc/ci.bazelrc.

# The recipe directory (this file + patches/ + files/) is bind-mounted read-only
# from the git worktree. It is mounted as a *directory*: bind-mounting individual
# files pins the inode, so an edit on the host would never become visible inside
# a running container.
RECIPE=/opt/build-mk/recipe
PATCHDIR="$RECIPE/patches"
source /opt/build-mk/lib/build-common.sh

VERSION="${CMK_VERSION:-2.4.0p35}"
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
# sha256 of OUR repackaged tarball, pinned by patch 0100. Identical to 2.3: the
# inputs and the tar flags are the same, so the bytes are the same.
SNAP7_TARBALL_SHA256="${SNAP7_TARBALL_SHA256:-aa675dfc77a057d99f08254a14217eb1728bde663324c2e622fd1b17f88bf12e}"

# Upstream tarballs whose URL in the tree cannot be used, seeded into the distdir
# where Bazel matches them by name and sha256 before attempting any download.
# Format: filename|sha256|url   (sha256 must match the pin in the tree)
#
#  * patch-2.7.6 is fetched from ftpmirror.gnu.org, a redirector that regularly
#    lands on a broken mirror ("GET returned 502 Bad Gateway"); ftp.gnu.org is
#    stable. Pinned in MODULE.bazel.
#  * heirloom-mailx's only public URL is ftp.nl.debian.org, whose certificate no
#    longer matches the hostname, so Bazel refuses it with
#    "SSLHandshakeException: No subject alternative DNS name matching
#    ftp.nl.debian.org found". archive.debian.org serves the identical tarball.
#  * jaeger's arm64 release asset — the URL works, but patch 0101 has to pin its
#    sha256 anyway, so seeding it costs nothing and saves 59 MB per cold build.
#    (2.4 fixed xmlsec1's dead URL, so unlike 2.3 it needs no seed.)
EXTRA_SEEDS=(
	"patch-2.7.6.tar.gz|8cf86e00ad3aaa6d26aca30640e86b0e3e1f395ed99f189b06d4c9f74bc58a4e|https://ftp.gnu.org/gnu/patch/patch-2.7.6.tar.gz"
	"heirloom-mailx_12.5.orig.tar.gz|015ba4209135867f37a0245d22235a392b8bbed956913286b887c2e2a9a421ad|https://archive.debian.org/debian/pool/main/h/heirloom-mailx/heirloom-mailx_12.5.orig.tar.gz"
	"jaeger-2.18.0-linux-arm64.tar.gz|a4c245e1e928ce16e89ae995cecf6cda748d24a8fff6e7ca84758552563a04e5|https://github.com/jaegertracing/jaeger/releases/download/v2.18.0/jaeger-2.18.0-linux-arm64.tar.gz"
)

DEBFULLNAME="${DEBFULLNAME:-Checkmk ARM64 build}"
DEBEMAIL="${DEBEMAIL:-nobody@example.invalid}"

# `make dist` builds the release tarball with `tar ... * .werks`, and a shell
# glob does not match dotfiles — so every dotfile in the repository *root* is
# missing from the tarball while dotfiles in subdirectories survive. Three of
# them are load-bearing and are restored verbatim; the rest are lint/editor
# config. See restore_tarball_omissions().
#
# files/bazel{rc,iskrc,version} are byte-for-byte copies from the v2.4.0p35 tag.
# Do not hand-write them: .bazeliskrc needs its BAZELISK_BASE_URL line as well
# as USE_BAZEL_VERSION, or bazelisk reads "aspect/2025.11.0" as a fork on
# github.com/aspect/bazel and 404s.
TARBALL_OMISSIONS=(.bazelversion .bazeliskrc .bazelrc)

# Webpack (cmk-frontend) and vite (cmk-frontend-vue) both die at node's default
# heap on a tree this size.
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=4096}"

# Everything Bazel-related lives in /etc/ci.bazelrc instead (see bazelrc.local):
# `make .venv` calls bare `bazel`, which never sees BAZEL_EXTRA_ARGS.
export BAZEL_EXTRA_ARGS="${BAZEL_EXTRA_ARGS:-}"

STAGES=(fetch-src unpack-src fetch-donor-deb seed-distdir seed-perl-modules patch
	donor-artifacts venv frontend build-deb collect)

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
	seed_extras
	seed_snap7
}

seed_snap7() {
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
		log "  NOTE: pin this sha in build.sh and patch 0100"
	elif [ "$sha" != "$SNAP7_TARBALL_SHA256" ]; then
		die "snap7 repack sha changed: got $sha want $SNAP7_TARBALL_SHA256"
	fi
}

seed_extras() {
	local entry name sha url
	for entry in "${EXTRA_SEEDS[@]}"; do
		IFS='|' read -r name sha url <<<"$entry"
		fetch "$url" "$DISTDIR/$name" "$sha"
	done
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

# Two sets of prebuilt payloads that the release tarball does not carry and that
# cannot be produced here:
#
#   * agents/windows/* — the Windows agent is built on a Windows node. The
#     donor's copy is *merged* into the tree's rather than replacing it, which
#     is what the 2.3 recipe (and every recipe before it) did: the two sets are
#     not the same. Only the tarball has check_mk.yml and the standalone .exe
#     agents, and only the Cloud deb has the .msi, python-3.cab,
#     windows_files_hashes.txt, check_mk.user.yml and unsign-msi.patch that
#     artifacts.make lists as required build inputs.
#   * agents/check-mk-agent{-$VER-1.noarch.rpm,_$VER-1_all.deb} — the *x86-64*
#     Linux agent packages, i.e. what the site's agent download page serves and
#     what the bakery hands out for x86 hosts. artifacts.make groups them with
#     agents/linux/* under SOURCE_BUILT_LINUX_AGENTS, "created ... by an
#     upstream job or while creating the source package", but the tarball ships
#     neither. Both rules that would produce them — the root Makefile's
#     `$(SOURCE_BUILT_LINUX_AGENTS): $(MAKE) -C agents $@` and the identical one
#     in omd/packages/check_mk/check_mk.make — declare no prerequisites, so a
#     file that is already in place is left alone and only a missing one is
#     built here. Built here is the wrong answer: agents/Makefile names them
#     _all/noarch unconditionally while filling them with this host's
#     cmk-agent-ctl and mk-sql, which patch 0009 compiles for aarch64 — an
#     "architecture-independent" package that runs on no x86 host at all.
#
# Both are architecture-independent from this package's point of view: they are
# shipped for deployment to other hosts and never run on the server.
do_donor_artifacts() {
	local work="$BUILD_ROOT/tmp/donor"
	rm -rf "$work"
	mkdir -p "$work"

	(cd "$work" && ar x "$DONOR_DEB" && tar -I zstd -xf data.tar.zst)

	local share="$work/opt/omd/versions/${VERSION}.cce/share/check_mk/agents"
	[ -d "$share/windows" ] || die "windows agents not found at $share/windows"

	local wdir="$SRC/agents/windows"
	mkdir -p "$wdir"
	cp -a "$share/windows"/. "$wdir"/

	local f
	for f in check_mk_agent.msi python-3.cab windows_files_hashes.txt \
		check_mk.user.yml unsign-msi.patch robotmk_ext.exe mk-sql.exe; do
		[ -s "$wdir/$f" ] || die "artifacts.make requires agents/windows/$f, which the donor did not provide"
	done

	# Copied individually rather than by glob, so a renamed or missing artifact
	# is an error in this stage and not an empty agent download page four hours
	# later. Unlike 2.5 there is no aarch64 pair to sit beside them — that
	# arrived upstream with werk #19275 — so agents/linux/cmk-agent-ctl, which
	# patch 0009 builds for aarch64, is deliberately left as it is: it is what an
	# arm64 monitored host gets.
	#
	# `install`, not `cp -a`: check_mk.make's intermediate install lists these
	# two as prerequisites, and the donor's mtimes are older than any stamp a
	# previous build-deb left behind — so preserving them would let a *resumed*
	# build keep the agent packages it had already baked in.
	local p
	for p in "check-mk-agent-${VERSION}-1.noarch.rpm" \
		"check-mk-agent_${VERSION}-1_all.deb"; do
		[ -s "$share/$p" ] ||
			die "the donor package has no $p — the x86-64 Linux agent packages cannot be lifted"
		install -m 644 "$share/$p" "$SRC/agents/$p"
	done

	rm -rf "$work"
	log "  windows agents: $(ls "$wdir" | tr '\n' ' ')"
	log "  agent packages: $(cd "$SRC/agents" && ls check-mk-agent[-_]"$VERSION"* | tr '\n' ' ')"
}

# Put back the files the release tarball drops but the build needs. These are
# not patches — .bazelrc is a verbatim copy of the one in the v2.4.0p35 tag.
#
# Without .bazelversion/.bazeliskrc bazelisk installs the newest Bazel, and
# without .bazelrc the build loses --@//:filesystem_layout=lsb (every omd
# package then fails its `select()` with "Please build with lsb or fhs
# filesystem layout"), the --flag_alias that turns packages.make's
# --cmk_version into a real flag, and the local module registry.
restore_tarball_omissions() {
	local f
	for f in "${TARBALL_OMISSIONS[@]}"; do
		[ -f "$SRC/$f" ] && continue
		install -m 644 "$RECIPE/files/${f#.}" "$SRC/$f"
		log "  restored $f from the recipe"
	done

	# `make dist` also passes --exclude=.gitignore, which drops the 86 empty
	# .gitignore files that hold otherwise-empty skel directories in git. The
	# directories themselves survive, so the make-based packages do not care —
	# but @stunnel//:skel is a genrule that declares this file as an output
	# (genrules cannot output directories) and fails with "declared output ...
	# was not created by genrule". pnp4nagios has the same construction but
	# touches its own placeholders, and both packages delete them again from the
	# installed skel, so re-creating this one is invisible in the package.
	for f in omd/packages/stunnel/skel/etc/stunnel/conf.d/.gitignore; do
		[ -e "$SRC/$f" ] && continue
		mkdir -p "$(dirname "$SRC/$f")"
		: >"$SRC/$f"
		log "  restored $f (empty placeholder, as upstream)"
	done
}

# Installed on every invocation rather than baked into the image, so editing
# bazelrc.local on the host takes effect on the next run. /etc/ci.bazelrc is the
# last try-import in .bazelrc, which is what makes it win.
install_bazelrc() {
	install -m 644 "$RECIPE/bazelrc.local" /etc/ci.bazelrc
	: >/etc/bazel-downloader-none.cfg
}

# omd/packages/apache-omd/BUILD reads HTPASSWD_BIN and APACHE_MODULE_DIR out of
# `/opt/<DISTRO>.mk` ("which get's copied when we build the build images" — and
# upstream's install-development.sh does exactly that for Ubuntu). Without it the
# genrule fails with "grep: /opt/*.mk: No such file or directory".
#
# Taken from the source tree rather than vendored in the recipe, and named by the
# same omd/distro call that omd.make itself uses, so it cannot drift from the
# package being built.
install_distro_mk() {
	local info name version from
	info=$("$SRC/omd/distro") || die "omd/distro could not identify this distribution"
	read -r name version <<<"$info"
	from="$SRC/omd/distros/${name}_${version}.mk"
	[ -f "$from" ] || die "Checkmk $VERSION has no distro definition for $name $version"
	if ! cmp -s "$from" "/opt/${name}_${version}.mk"; then
		# Exactly one file, because the BUILD file globs /opt/*.mk.
		rm -f /opt/*.mk
		install -m 644 "$from" "/opt/${name}_${version}.mk"
		log "  installed /opt/${name}_${version}.mk"
	fi
}

# The venv is a real build dependency: check_mk.make runs
# `make -C doc/plugin-api html`, which goes through scripts/run-uvenv, which
# runs `make .venv`, which has Bazel resolve requirements_all_lock.txt with uv
# and create .venv. Given its own stage so that a failure here is not mistaken
# for a packaging failure two hours in.
do_venv() {
	cd "$SRC"
	make .venv
	log "  venv python: $(.venv/bin/python --version)"
}

# packages/cmk-frontend/dist and packages/cmk-frontend-vue/dist are NOT in the
# release tarball (they are gitignored build output), but check_mk.make tars
# both into share/check_mk/web/htdocs unconditionally. Upstream builds them in
# the root Makefile's `dist` target, which is the step that *produces* the
# tarball — so from a tarball they have to be built here.
do_frontend() {
	cd "$SRC"
	packages/cmk-frontend/run --clean --build
	packages/cmk-frontend-vue/run --clean --build
	local d
	for d in packages/cmk-frontend/dist packages/cmk-frontend-vue/dist; do
		[ -d "$d" ] || die "$d was not produced"
		log "  $d ($(du -sh "$d" | cut -f1))"
	done
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
# The --preserve-envvar lines matter: debuild sanitises the environment, and
# upstream's target preserves neither our rustup location nor NODE_OPTIONS.
do_build_deb() {
	local phases=(build-arch binary-arch)
	[ "${CMK_FULL_CLEAN:-}" = 1 ] && phases=(clean "${phases[@]}")

	cd "$SRC/omd"
	make debian/changelog debian/control \
		DEBFULLNAME="$DEBFULLNAME" DEBEMAIL="$DEBEMAIL"

	DEBFULLNAME="$DEBFULLNAME" DEBEMAIL="$DEBEMAIL" debuild \
		--preserve-envvar="BAZEL_*" \
		--preserve-envvar="MAKE" \
		--preserve-envvar="RUSTUP_HOME" \
		--preserve-envvar="CARGO_HOME" \
		--preserve-envvar="NODE_OPTIONS" \
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
require_cmds curl tar 7z ar zstd patch make gcc g++-14 node npm bazel rustc cargo \
	python3 dpkg-deb debuild rpmbuild git

log "Checkmk $VERSION — arm64 / trixie"
log "src=$SRC"

install_bazelrc
log "installed /etc/ci.bazelrc"

wanted() {
	[ -z "$ONLY" ] && return 0
	case ",$ONLY," in *",$1,"*) return 0 ;; esac
	return 1
}

for s in "${STAGES[@]}"; do
	wanted "$s" || continue
	# Cheap, idempotent and needed by every stage from `venv` onwards; doing it
	# here rather than inside one stage means a resumed run still gets it.
	if [ -d "$SRC" ]; then
		restore_tarball_omissions
		install_distro_mk
	fi
	stage "$s" "do_${s//-/_}"
done

log "all requested stages complete"
