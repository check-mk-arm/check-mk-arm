#!/bin/bash
# Host-side driver for the arm64 Checkmk builds.
#
# The build itself runs entirely inside a container; nothing is installed on the
# host. The container is long-lived and the source tree, caches and outputs are
# all bind-mounted from $CMK_DATA (default /data/checkmk), which is what makes
# the debug loop fast: edit a patch on the host, re-run in the container, no
# image rebuild and no re-download.
#
#   ./run.sh image           build the builder image
#   ./run.sh up              start the long-lived build container
#   ./run.sh build           run the build (attached)
#   ./run.sh build -d        run the build detached, then ./run.sh logs
#   ./run.sh sh              interactive shell in the build container
#   ./run.sh logs            follow the newest build log
#   ./run.sh reset-src       drop the source tree, keep tarballs and caches
#   ./run.sh watch           disk/memory watchdog (run in a second window)
#   ./run.sh down            stop and remove the container
#   ./run.sh status          where everything is and how big it has got

set -Eeuo pipefail

VERSION="${CMK_VERSION:-2.4.0p35}"
MINOR="${VERSION%%p*}"

case "$MINOR" in
2.3.0) DISTRO=bookworm ;;
2.4.0) DISTRO=trixie ;;
*) echo "unknown Checkmk minor '$MINOR' — teach run.sh its distro" >&2; exit 1 ;;
esac

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Everything the build reads or writes lives under $DATA. It is a variable so a
# CI runner, which has no /data, can point it at its own scratch space
# (CMK_DATA=$RUNNER_TEMP/cmk) without any other change.
DATA="${CMK_DATA:-/data/checkmk}"
WORK="$DATA/work/$VERSION"
HOMEDIR="$DATA/home/$VERSION"
IMAGE="cmk-arm-build:${MINOR}-${DISTRO}"
CONTAINER="cmk-build-${VERSION}"

# Leave a core spare so the host stays responsive, and cap memory so an OOM
# kills the build rather than sshd — this host has 23 GB and no swap. The
# GitHub arm64 runner has 4 vCPU and only 16 GB, so CI lowers MEMORY to 13g;
# peak measured RSS is 5.3 GiB, so the ceiling is a guard rail, not a budget.
CPUS="${CPUS:-3.5}"
MEMORY="${MEMORY:-18g}"

# Abort thresholds for `watch`, in KiB. Overridable because they assume / and
# $DATA are separate filesystems, which is true on the build box and false on a
# runner (where `watch` is not used at all).
MIN_DATA_KB="${MIN_DATA_KB:-$((10 * 1024 * 1024))}"
MIN_ROOT_KB="${MIN_ROOT_KB:-$((5 * 1024 * 1024))}"

die() { echo "!!! $*" >&2; exit 1; }

ensure_dirs() {
	mkdir -p "$WORK"/{distdir,state,tmp,debs,logs} "$HOMEDIR"
}

cmd_image() {
	[ -d "$REPO/$MINOR" ] || die "no builder directory $REPO/$MINOR"
	docker build -t "$IMAGE" "$REPO/$MINOR"
	docker builder prune -af >/dev/null 2>&1 || true
	echo "built $IMAGE"
}

cmd_up() {
	ensure_dirs
	# Docker silently creates a *directory* for a bind-mount source that does
	# not exist, which then shadows the real file once it is written. Fail
	# loudly instead.
	for f in "$REPO/$MINOR/build.sh" "$REPO/lib/build-common.sh"; do
		[ -f "$f" ] || die "$f must exist before starting the container"
	done
	[ -d "$REPO/$MINOR/patches" ] || die "$REPO/$MINOR/patches must exist"

	if docker inspect "$CONTAINER" >/dev/null 2>&1; then
		docker start "$CONTAINER" >/dev/null
		echo "$CONTAINER already existed — started"
		return 0
	fi

	# patches/, build.sh and lib/ are mounted read-only straight from the git
	# worktree, so editing them on the host takes effect immediately.
	#
	# The --add-host lines point Checkmk's internal mirrors at localhost. Those
	# hosts resolve publicly but blackhole traffic, so every probe otherwise
	# burns a full connect timeout. Several upstream targets already fall back
	# to the public registry when the probe *fails* (the root Makefile's npm
	# block does exactly this) — making it fail instantly turns a multi-minute
	# stall into a no-op and removes the need to patch some of them at all.
	# --init matters: the entrypoint is `sleep infinity`, which never calls
	# wait(), so an orphaned child becomes a permanent zombie. Bazel restarts
	# its own server when the version changes and then blocks trying to kill the
	# old one — "Attempted to kill stale server process using SIGKILL, but it
	# did not die". tini as PID 1 reaps orphans and the problem disappears.
	docker run -d --name "$CONTAINER" --hostname cmk-build --init \
		--cpus "$CPUS" --memory "$MEMORY" --memory-swap "$MEMORY" \
		--add-host artifacts.lan.tribe29.com:127.0.0.1 \
		--add-host devpi.lan.tribe29.com:127.0.0.1 \
		--add-host bazel-registry.lan.checkmk.net:127.0.0.1 \
		-v "$WORK":/opt/build-mk \
		-v "$HOMEDIR":/root \
		-v "$WORK/tmp":/tmp \
		-v "$REPO/$MINOR":/opt/build-mk/recipe:ro \
		-v "$REPO/lib":/opt/build-mk/lib:ro \
		--entrypoint sleep \
		"$IMAGE" infinity >/dev/null
	echo "started $CONTAINER from $IMAGE"
}

cmd_build() {
	local flags=()
	if [ "${1:-}" = "-d" ]; then
		flags=(-d)
		shift
	elif [ -t 0 ]; then
		flags=(-it)
	fi
	docker exec "${flags[@]}" "$CONTAINER" \
		bash -lc "CMK_VERSION=$VERSION /opt/build-mk/recipe/build.sh $*"
	[ "${flags[0]:-}" = "-d" ] && echo "detached — follow with: $0 logs"
	return 0
}

cmd_sh() { docker exec -it "$CONTAINER" bash -l; }

cmd_logs() {
	local newest
	newest=$(ls -t "$WORK/logs"/build-*.log 2>/dev/null | head -1) ||
		die "no build logs yet in $WORK/logs"
	[ -n "$newest" ] || die "no build logs yet in $WORK/logs"
	echo "--- $newest"
	tail -f "$newest"
}

cmd_reset_src() {
	echo "removing the source tree and its downstream stage markers"
	echo "keeping: source tarball, donor deb, distdir/, /root caches"
	# Must run inside the container: the tree is written by root there, so a
	# host-side rm as an unprivileged user fails on every file.
	docker exec "$CONTAINER" bash -lc "
		rm -rf /opt/build-mk/check-mk-raw-${VERSION}.cre \
		       /opt/build-mk/check-mk-raw-${VERSION}.cre.unpacking
		rm -f /opt/build-mk/state/{unpack-src,patch,windows-artifacts,venv,frontend,build-deb,collect}.done
	" || die "reset failed — is the container running? ($0 up)"
	echo "done"
}

cmd_down() {
	docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
	echo "removed $CONTAINER"
}

cmd_status() {
	echo "version   $VERSION ($DISTRO)"
	echo "image     $IMAGE"
	echo "container $CONTAINER $(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo '(absent)')"
	echo
	# / and $DATA are one filesystem on a runner; drop the duplicate row.
	{ df -h / "$DATA" 2>/dev/null || df -h /; } | awk 'NR == 1 || !seen[$0]++' | sed 's/^/  /'
	echo
	for d in "$WORK" "$WORK/distdir" "$WORK/debs" "$HOMEDIR/.cache"; do
		[ -e "$d" ] && printf '  %-52s %s\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
	done
	echo
	[ -f "$WORK/logs/timings-$VERSION.tsv" ] && {
		echo "  stage timings:"
		awk -F'\t' '{printf "    %-20s %8ds  free=%-6s cache=%s\n", $2, $3, $4, $5}' \
			"$WORK/logs/timings-$VERSION.tsv"
	}
	ls -1 "$WORK/state"/*.done 2>/dev/null | sed 's|.*/|  done: |;s|\.done$||' || true
}

# Sampled resource log. Doubles as the peak-RSS record needed to spec CI later,
# and hard-stops the build before either filesystem fills.
cmd_watch() {
	ensure_dirs
	echo "watching — abort at <10 GiB on /data or <5 GiB on /"
	while :; do
		local root_kb data_kb
		root_kb=$(df --output=avail -k / | tail -1)
		data_kb=$(df --output=avail -k "$DATA" | tail -1)

		printf '%s root=%dG data=%dG cache=%s tree=%s%s\n' \
			"$(date +%FT%T)" $((root_kb / 1048576)) $((data_kb / 1048576)) \
			"$(du -sh "$HOMEDIR/.cache" 2>/dev/null | cut -f1 || echo -)" \
			"$(du -sh "$WORK/check-mk-raw-${VERSION}.cre" 2>/dev/null | cut -f1 || echo -)" \
			"$(docker stats --no-stream --format ' mem={{.MemUsage}} cpu={{.CPUPerc}}' "$CONTAINER" 2>/dev/null || true)"

		if [ "$data_kb" -lt "$MIN_DATA_KB" ] || [ "$root_kb" -lt "$MIN_ROOT_KB" ]; then
			echo "!!! LOW DISK — stopping $CONTAINER"
			docker stop "$CONTAINER" || true
			break
		fi
		sleep 120
	done 2>&1 | tee -a "$WORK/logs/resources.log"
}

case "${1:-}" in
image) shift; cmd_image "$@" ;;
up) shift; cmd_up "$@" ;;
build) shift; cmd_build "$@" ;;
sh) shift; cmd_sh "$@" ;;
logs) shift; cmd_logs "$@" ;;
reset-src) shift; cmd_reset_src "$@" ;;
down) shift; cmd_down "$@" ;;
status) shift; cmd_status "$@" ;;
watch) shift; cmd_watch "$@" ;;
*)
	awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
	exit 1
	;;
esac
