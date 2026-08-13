#!/bin/bash
# Shared helpers for the arm64 Checkmk builds.
#
# Sourced by <version>/build.sh — not runnable on its own. Everything here is
# deliberately version-agnostic; anything that differs between 2.3 and 2.4
# belongs in the per-version build.sh.

set -Eeuo pipefail

BUILD_ROOT="${BUILD_ROOT:-/opt/build-mk}"
LOGDIR="$BUILD_ROOT/logs"
DISTDIR="$BUILD_ROOT/distdir"
PATCHDIR="${PATCHDIR:-$BUILD_ROOT/patches}"

# ---------------------------------------------------------------- output -----

log() { printf '%s | %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\n!!! %s\n' "$*" >&2; exit 1; }

fmt_dur() { # seconds -> "1h 02m 03s"
	local s=$1
	printf '%dh %02dm %02ds' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
}

# Send everything to a timestamped log as well as the terminal, and always
# report where that log is — a build that dies at hour six is useless if the
# output only lived in a detached exec.
start_logging() {
	mkdir -p "$LOGDIR"
	# The PID matters: two runs started in the same second would otherwise share
	# a log file, and anything watching for the completion marker would see the
	# first run's and think the second had finished too.
	LOG="$LOGDIR/build-${VERSION}-$(date +%Y%m%d-%H%M%S)-$$.log"
	exec > >(tee -a "$LOG") 2>&1
	trap 'rc=$?; log "EXIT rc=$rc after $(fmt_dur $SECONDS) — log: $LOG"; exit $rc' EXIT
	log "logging to $LOG"
}

require_cmds() {
	local missing=()
	for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
	[ ${#missing[@]} -eq 0 ] || die "missing commands in the build image: ${missing[*]}"
}

# ---------------------------------------------------------------- stages -----

# Stage markers make a multi-hour build resumable: a failure at 90% costs the
# remaining 10%, not the whole run. FORCE_STAGE=<name> (or =all) re-runs one.
stage() { # stage <name> <cmd...>
	local name="$1"
	shift
	local marker="$STATE/$name.done"

	if [ -f "$marker" ] && [ "${FORCE_STAGE:-}" != "$name" ] && [ "${FORCE_STAGE:-}" != all ]; then
		log "SKIP  $name  (done $(date -r "$marker" '+%F %T'))"
		return 0
	fi

	log "===>  $name"
	local t0=$SECONDS
	"$@"
	local dt=$((SECONDS - t0))

	printf '%s\t%s\t%d\t%s\t%s\n' \
		"$VERSION" "$name" "$dt" \
		"$(df --output=avail -h "$BUILD_ROOT" | tail -1 | tr -d ' ')" \
		"$(du -sh /root/.cache 2>/dev/null | cut -f1 || echo -)" \
		>>"$TIMINGS"

	date >"$marker"
	log "<===  $name ok ($(fmt_dur $dt))"
}

# ---------------------------------------------------------------- patches ----

# The single most important fix over the upstream recipe. Flo's loop globbed
# patches/*.patch, sent patch's output to /dev/null and merely *echoed* on
# failure — so roughly six patches silently did nothing. Here:
#
#   * a `series` file drives the order (a glob sorts alphabetically, which is
#     what made his two Pipfile patches collide),
#   * each patch is dry-run immediately before it is applied — not all up front,
#     because a later patch may legitimately depend on an earlier one,
#   * the first failure aborts and prints patch's own hunk diagnostics, which is
#     exactly the information needed to re-cut the patch,
#   * no -N and no -R: an already-applied patch is an error, never a silent
#     reverse-apply.
apply_patches() { # apply_patches <src-dir> <patch-dir>
	local src="$1" pdir="$2"
	local series="$pdir/series" applied="$src/.arm-patches-applied"
	local n=0 skipped=0 out p

	[ -d "$src" ] || die "source tree missing: $src"
	[ -f "$series" ] || die "no series file at $series"
	touch "$applied"

	while IFS= read -r p || [ -n "$p" ]; do
		case "$p" in '' | '#'*) continue ;; esac
		[ -f "$pdir/$p" ] || die "series references a patch that does not exist: $p"

		# Tracking per patch rather than with a single marker means adding a
		# patch mid-build applies just that one, instead of forcing a full
		# reset (and the hours of rebuilding that implies).
		if grep -qxF "$p" "$applied"; then
			skipped=$((skipped + 1))
			continue
		fi

		if ! out=$(patch -d "$src" -p0 -l --force --dry-run <"$pdir/$p" 2>&1); then
			log "PATCH FAILED (dry-run): $p"
			printf '%s\n' "$out" | sed 's/^/      | /' >&2
			die "aborting before any damage: $p does not apply to $src"
		fi

		patch -d "$src" -p0 -l --force --no-backup-if-mismatch <"$pdir/$p" >/dev/null ||
			die "$p passed dry-run but failed to apply — tree may be inconsistent"

		printf '%s\n' "$p" >>"$applied"
		n=$((n + 1))
		log "  patch ok: $p"
	done <"$series"

	log "applied $n patches ($skipped already applied) from $series"
}

# ---------------------------------------------------------------- fetching ---

# Resumable download with an optional sha256 gate. Checkmk's tarballs are
# 100-350 MB; re-fetching them on every debug iteration is the difference
# between a 30-second loop and a 10-minute one.
fetch() { # fetch <url> <dest> [sha256]
	local url="$1" dest="$2" want="${3:-}"

	if [ -f "$dest" ]; then
		if [ -n "$want" ]; then
			local have
			have=$(sha256sum "$dest" | cut -d' ' -f1)
			if [ "$have" = "$want" ]; then
				log "  have $(basename "$dest") (sha ok)"
				return 0
			fi
			log "  $(basename "$dest") sha mismatch, re-fetching"
			rm -f "$dest"
		else
			log "  have $(basename "$dest")"
			return 0
		fi
	fi

	log "  fetching $(basename "$dest")"
	curl -fSL --retry 3 --retry-delay 5 -C - -o "$dest.part" "$url" ||
		die "download failed: $url"
	mv "$dest.part" "$dest"

	if [ -n "$want" ]; then
		local have
		have=$(sha256sum "$dest" | cut -d' ' -f1)
		[ "$have" = "$want" ] || die "sha256 mismatch for $dest: got $have want $want"
	fi
}

# Untar into a scratch dir and rename into place, so an interrupted unpack can
# never leave a half-tree that the patch stage would then happily corrupt.
unpack_atomic() { # unpack_atomic <tarball> <final-dir>
	local tarball="$1" final="$2"
	local tmp="${final}.unpacking"

	rm -rf "$tmp"
	mkdir -p "$tmp"
	tar xzf "$tarball" -C "$tmp"

	local inner
	inner=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
	[ -n "$inner" ] || die "tarball $tarball did not contain a top-level directory"

	rm -rf "$final"
	mv "$inner" "$final"
	rm -rf "$tmp"
}
