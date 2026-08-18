# Builder image for Checkmk 2.5.0 on arm64/Debian trixie.
#
# trixie because omd/distros/DEBIAN_13.mk is what sets DISTRO_CODE = trixie and
# the package's `_0.<code>_arm64.deb` suffix follows the `--cmk_distro` flag we
# pass (see bazelrc.local); the runtime image's base has to match, since the
# dependencies are distro-specific (trixie pulls libperl5.40).
#
# 2.5 moved the whole OMD build into Bazel — `omd/Makefile` and `omd/debian/rules`
# are gone and the package comes out of a rules_pkg `pkg_deb` target.

# What v2.5.0p11 demands of the host:
#   GCC_VERSION    := 14.2.0     native on trixie
#   CLANG_VERSION  := 19         native on trixie
#   .bazelversion  := 8.5.0      but .bazeliskrc pins aspect/2025.51.5
#   PYTHON_VERSION := 3.13.14    hermetic, not from the distro
#
# Nothing about the build itself is baked in: no patches, no build script, no
# ENTRYPOINT. Those are bind-mounted from the git worktree by run.sh so that
# editing a patch does not cost an image rebuild.
FROM arm64v8/debian:trixie-slim

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8
RUN mkdir -p /usr/share/man/man1

RUN apt-get update \
    && apt-get install -y \
    apache2 \
    apache2-dev \
    autoconf \
    automake \
    autotools-dev \
    binutils \
    bison \
    build-essential \
    ca-certificates \
    chrpath \
    clang-19 \
    clang-tidy-19 \
    cmake \
    curl \
    dnsutils \
    dpkg-dev \
    flex \
    freetds-bin \
    freetds-dev \
    gawk \
    gettext \
    git \
    graphviz \
    iputils-ping \
    libc6-dev \
    libcurl4-openssl-dev \
    libevent-dev \
    libffi-dev \
    libfreeradius-dev \
    libgd-dev \
    libglib2.0-dev \
    libgnutls28-dev \
    libgsf-1-dev \
    libjpeg-dev \
    libkrb5-dev \
    libldap2-dev \
    libltdl-dev \
    libmariadb-dev \
    libmariadb-dev-compat \
    libmcrypt-dev \
    libncurses-dev \
    libopenblas-dev \
    libpango1.0-dev \
    libpcap-dev \
    libperl-dev \
    libpq-dev \
    libreadline-dev \
    librrd-dev \
    libsasl2-dev \
    libsodium-dev \
    libsqlite3-dev \
    libssl-dev \
    libtool \
    libtool-bin \
    libxml2 \
    libxml2-dev \
    libxmlsec1-dev \
    libxmlsec1-openssl \
    lsb-release \
    make \
    musl-dev \
    musl-tools \
    ninja-build \
    nullmailer \
    openssh-client \
    openssl \
    patch \
    patchelf \
    php-common \
    pkgconf \
    pngcrush \
    rpcbind \
    rpm \
    rrdtool \
    rsync \
    smbclient \
    strace \
    sudo \
    tar \
    texinfo \
    tk-dev \
    unzip \
    uuid-dev \
    vim \
    wget \
    xmlsec1 \
    zip \
    zlib1g-dev \
    zstd \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*

# --- CMake -------------------------------------------------------------------
# @pcap and @osslsigncode go through rules_foreign_cc's `cmake` rule, which uses
# whatever cmake is on the action PATH. trixie's cmake links the system libcurl
# and libssl, and several Bazel actions put Checkmk's own OpenSSL first on
# LD_LIBRARY_PATH — a version skew there makes /usr/bin/cmake die inside those
# actions with "version `OPENSSL_x.y' not found (required by libcurl.so.4)".
#
# Kitware's own binary is statically linked — no libcurl, no libssl, not even
# libstdc++ — so it works whatever LD_LIBRARY_PATH says. Installed *over*
# /usr/bin rather than prepended to PATH on purpose: PATH is part of every Bazel
# action's cache key (see bazelrc.local), so extending it invalidates the cache.
ARG CMAKE_VERSION=3.31.6
RUN set -eux; \
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
        -o /tmp/cmake.tar.gz \
        "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-aarch64.tar.gz"; \
    mkdir -p /opt/cmake; \
    tar xzf /tmp/cmake.tar.gz -C /opt/cmake --strip-components=1; \
    rm -f /tmp/cmake.tar.gz; \
    for t in cmake ctest cpack; do ln -sf "/opt/cmake/bin/$t" "/usr/bin/$t"; done; \
    cmake --version; \
    ! ldd /opt/cmake/bin/cmake | grep -qE 'libcurl|libssl'

# --- host Python -------------------------------------------------------------
# Not used by the build itself — the interpreter that ends up in the package is
# built by omd/packages/Python and Bazel's own tooling uses the hermetic
# python-build-standalone one. This is here for the recipe's own helpers
# (lib/seed-perl-modules.py) and the odd upstream script.
#
# Dropping EXTERNALLY-MANAGED keeps a stray `pip3 install` in some upstream
# helper from failing on PEP 668. This is a throwaway build container.
RUN apt-get update && apt-get install -y \
    python3 \
    python3-dev \
    python3-venv \
    python3-setuptools \
    libbz2-dev \
    liblzma-dev \
    libgdbm-dev \
    libnss3-dev \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/lib/python3.13/EXTERNALLY-MANAGED
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# --- Bazel via bazelisk ------------------------------------------------------
# The release tarball strips the repository's root dotfiles, so build.sh writes
# .bazelversion and .bazeliskrc back before the build; bazelisk then fetches
# aspect/2025.51.5, whose release does publish bazel-2025.51.5-linux-arm64.
# Its download cache lands in /root/.cache/bazelisk, which run.sh bind-mounts,
# so it survives container recreation.
RUN curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
        -o /usr/local/bin/bazel \
        https://github.com/bazelbuild/bazelisk/releases/download/v1.25.0/bazelisk-linux-arm64 \
    && chmod 755 /usr/local/bin/bazel \
    && test -s /usr/local/bin/bazel

# An empty downloader config, so /etc/ci.bazelrc can switch off
# bazel_downloader.cfg's rewrites through bazel-registry.lan.checkmk.net
# without patching the file.
RUN : >/etc/bazel-downloader-none.cfg

# ENV alone would not be enough: run.sh execs `bash -l`, and /etc/profile resets
# PATH to the distro default, which would hide bazel under /usr/local/bin.
RUN printf '%s\n' \
    'export PATH=/usr/local/bin:$PATH' \
    >/etc/profile.d/00-cmk-toolchain.sh

# Sanity checks for the things the aarch64 patches depend on existing.
RUN test -f /usr/share/misc/config.guess \
    && test -f /usr/share/misc/config.sub \
    && test -e /usr/lib/aarch64-linux-gnu/libc.so \
    && test -d /usr/lib/gcc/aarch64-linux-gnu/14/include \
    && test -e /usr/lib/aarch64-linux-gnu/libglib-2.0.so \
    && test -e /usr/lib/aarch64-linux-gnu/libxml2.so \
    && test -d /usr/lib/aarch64-linux-gnu/glib-2.0/include \
    && test -d /usr/lib/aarch64-linux-gnu/pkgconfig \
    && g++-14 --version && gcc-14 --version

RUN mkdir -p /opt/build-mk/{debs,distdir,state,logs}
WORKDIR /opt/build-mk
