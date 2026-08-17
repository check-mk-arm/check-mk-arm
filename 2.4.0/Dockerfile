# Builder image for Checkmk 2.4.0 on arm64/Debian trixie.
#
# trixie rather than bookworm because omd/distros/DEBIAN_13.mk is what sets
# DISTRO_CODE = trixie, and that file does not exist on the 2.3.0 branch — the
# base image alone decides which `_0.<code>_arm64.deb` comes out (omd/omd.make
# derives it from /etc/debian_version via omd/distro). It also removes most of
# the 2.3 workarounds: trixie ships gcc-14 natively, so the gcc-13/14 symlink
# hack is gone, and cmake 3.31 and the 7zip package are in the distro.
#
# What v2.4.0p35 actually demands:
#   GCC_VERSION    := 14.2.0     native on trixie
#   CLANG_VERSION  := 19         native on trixie
#   NODEJS_VERSION := 22         trixie has 20 — hence nodesource
#   NPM_VERSION    := 10         package.json has engine-strict npm >=10.9 <11
#   rust           := 1.87       packages/host/rust-toolchain.toml
#   .bazelversion  := 7.5.0      but .bazeliskrc pins aspect/2025.11.0
#
# 2.4 needs no pipenv and no host CPython 3.12: the venv is created by Bazel
# (rules_uv), and the interpreter is the hermetic python-build-standalone one.
# The host python3 only runs scripts/create_build_environment_variables.py.
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
    alien \
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
    debhelper \
    devscripts \
    dnsutils \
    dpkg-dev \
    fakeroot \
    flex \
    freetds-bin \
    freetds-dev \
    g++-14 \
    gawk \
    gcc-14 \
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
    7zip \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*

# --- CMake -------------------------------------------------------------------
# trixie's cmake is 3.31.6 too, but it links the system libcurl and libssl. The
# Bazel actions that build python3-modules put Checkmk's own OpenSSL 3.0.21 first
# on LD_LIBRARY_PATH, and trixie's libcurl needs OPENSSL_3.2/3.3 symbols that
# 3.0.21 does not export — so /usr/bin/cmake dies inside those actions with
# "version `OPENSSL_3.2.0' not found (required by libcurl.so.4)". pillow's build
# backend then falls back to building the PyPI `cmake` sdist, which bootstraps by
# downloading a tarball over TLS and fails. (Upstream never sees this: they build
# on Ubuntu, whose system OpenSSL is 3.0.x and therefore compatible.)
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

# --- Node 22 -----------------------------------------------------------------
# packages/cmk-frontend{,-vue}/package.json declare
#   "engines": { "node": ">=22.0.0 <=23.0.0", "npm": ">=10.9.0 <11.0.0" }
# and their .npmrc sets engine-strict=true, so npm refuses to install under
# trixie's node 20 / npm 9. The nodesource "nodistro" repo is distro-agnostic
# and its node 22 bundles npm 10.9.
RUN curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
        https://deb.nodesource.com/setup_22.x -o /tmp/nodesource.sh \
    && bash /tmp/nodesource.sh \
    && rm -f /tmp/nodesource.sh \
    && apt-get install -y nodejs \
    && apt-get autoremove -y && rm -rf /var/lib/apt/lists/* \
    && node --version | grep -q '^v22\.' \
    && npm --version | grep -q '^10\.'

# --- host Python -------------------------------------------------------------
# Only for scripts/create_build_environment_variables.py and the odd helper.
# The interpreter that ends up in the package is built by omd/packages/Python,
# and the build's own venv uses the hermetic one pinned in MODULE.bazel.
#
# Dropping EXTERNALLY-MANAGED keeps a stray `pip3 install` in some upstream
# helper from failing on PEP 668. This is a throwaway build container.
RUN apt-get update && apt-get install -y \
    python3 \
    python3-dev \
    python3-pip \
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
# aspect/2025.11.0 (the aspect-cli release does publish bazel-2025.11.0-linux-arm64).
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

# --- Rust --------------------------------------------------------------------
# packages/host/rust-toolchain.toml pins 1.87 (install-rust-cargo.sh agrees), and
# agents/Makefile builds cmk-agent-ctl and mk-sql for the musl target — they are
# no longer shipped prebuilt in the 2.4 tarball. Installed under /opt so the
# /root bind mount cannot mask it.
ENV RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo
ENV PATH="/opt/rust/cargo/bin:${PATH}"
RUN curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && sh /tmp/rustup-init.sh -y --no-modify-path --default-toolchain 1.87 \
    && rm -f /tmp/rustup-init.sh \
    && rustup target add aarch64-unknown-linux-musl \
    && rustc --version && cargo --version

# ENV alone is not enough: run.sh execs `bash -l`, and /etc/profile resets PATH
# to the distro default, which would hide cargo/rustc and bazel from the build.
RUN printf '%s\n' \
    'export RUSTUP_HOME=/opt/rust/rustup' \
    'export CARGO_HOME=/opt/rust/cargo' \
    'export PATH=/opt/rust/cargo/bin:/usr/local/bin:$PATH' \
    >/etc/profile.d/00-cmk-toolchain.sh

# Sanity checks for the things the aarch64 patches depend on existing.
RUN test -f /usr/share/misc/config.guess \
    && test -f /usr/share/misc/config.sub \
    && test -e /usr/lib/aarch64-linux-gnu/libc.so \
    && test -d /usr/lib/gcc/aarch64-linux-gnu/14/include \
    && test -e /usr/lib/aarch64-linux-gnu/libglib-2.0.so \
    && test -e /usr/lib/aarch64-linux-gnu/libxml2.so \
    && test -d /usr/lib/aarch64-linux-gnu/glib-2.0/include \
    && command -v 7z \
    && g++-14 --version && gcc-14 --version

RUN mkdir -p /opt/build-mk/{debs,distdir,state,logs}
WORKDIR /opt/build-mk
