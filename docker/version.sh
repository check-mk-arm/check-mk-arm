# Derives the Docker image tags for a build. Sourced (not executed) by CI, so it
# only sets variables and must not exit the shell on its own.
#
# Sets:
#   IMAGE_NAME     check-mk-raw-pi
#   CMK_VERSION    Checkmk version taken from the .deb filename (e.g. 2.3.0p49)
#   DISTRO_CODE    distro the .deb was built for (e.g. bookworm)
#   IMAGE_VERSION  primary tag
#   IMAGE_TAG      $IMAGE_NAME:$IMAGE_VERSION   (kept for backwards compatibility)
#   IMAGE_TAGS     every tag this build should publish

IMAGE_NAME=check-mk-raw-pi

# The .deb is the source of truth: its name encodes both the Checkmk version and
# the distro it was built against.
#   check-mk-raw-2.3.0p49_0.bookworm_arm64.deb
_deb=$(ls check-mk-raw-*_arm64.deb 2>/dev/null | head -1)

# This file is sourced, so it cannot simply `exit`. `return` is the correct verb
# when sourced; the `|| exit 1` fallback covers being run directly.
_fail() {
	echo "version.sh: FATAL $*" >&2
	return 1 2>/dev/null || exit 1
}

if [ -z "${_deb:-}" ]; then
	_fail "no check-mk-raw-*_arm64.deb found in $(pwd)"
	return 1 2>/dev/null || exit 1
else
	_base=${_deb%_arm64.deb}          # check-mk-raw-2.3.0p49_0.bookworm
	CMK_VERSION=${_base%%_*}          # check-mk-raw-2.3.0p49
	CMK_VERSION=${CMK_VERSION#check-mk-raw-}
	DISTRO_CODE=${_base##*.}          # bookworm
	echo "version.sh: deb=$_deb version=$CMK_VERSION distro=$DISTRO_CODE"
fi

# A tagged pipeline must ship the version it claims to ship. Nothing previously
# stopped a pipeline tagged 2.3.0p49 from publishing a 2.2.0p40 package.
if [ -n "${GIT_TAG:-}" ] && [ -n "${CMK_VERSION:-}" ] && [ "$GIT_TAG" != "$CMK_VERSION" ]; then
	echo "version.sh: FATAL git tag '$GIT_TAG' does not match the .deb version '$CMK_VERSION'" >&2
	return 1 2>/dev/null || exit 1
fi

if [ -z "${GIT_TAG:-}" ]; then
	echo "version.sh: no GIT_TAG, using 'latest' as the docker image tag"
	IMAGE_VERSION='latest'
	IMAGE_TAGS="latest"
else
	echo "version.sh: using GIT_TAG as the docker image tag"
	IMAGE_VERSION=$GIT_TAG
	# 2.3.0p49 -> also publish the 2.3.0 series tag. 'latest' is deliberately
	# NOT added here; only the newest supported line should claim it, which is
	# a decision for the pipeline, not for a tag.
	IMAGE_TAGS="$IMAGE_VERSION ${IMAGE_VERSION%%p*}"
fi

IMAGE_TAG=$IMAGE_NAME:$IMAGE_VERSION
