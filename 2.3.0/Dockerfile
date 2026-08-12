# Builder image for Checkmk 2.3.0 on arm64/Debian bookworm.
#
# Derived from the 2.2.0 image in this repo (the only known-good recipe), with
# the toolchain raised to what v2.3.0p49's defines.make actually demands:
#   NODEJS_VERSION := 22   NPM_VERSION := 10   (hard-checked by the root
#                                               Makefile's .ran-npm target)
#   .bazelversion  := 6.5.0                    (hence bazelisk, not a pinned binary)
#   GCC_VERSION    := 14.2.0                   (bookworm ships 12 — see the symlinks)
#   RUST           := 1.90                     (bookworm ships 1.63 — hence rustup)
#
# The distro is NOT configured here. omd/omd.make derives DISTRO/DISTRO_CODE
# from /etc/debian_version via omd/distro, so the base image alone decides that
# the output is a `_0.bookworm_arm64.deb`. Flo's `ENV DISTRO=... DISTRO_CODE=...`
# was always dead code and is deliberately absent.
#
# Nothing about the build itself is baked in: no patches, no build script, no
# ENTRYPOINT. Those are bind-mounted from the git worktree by run.sh so that
# editing a patch does not cost an image rebuild.
FROM arm64v8/debian:bookworm-slim

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8 PATH="/opt/bin:${PATH}"
RUN mkdir -p /usr/share/man/man1

RUN apt-get update \
    && apt-get install -y \
    alien \
    apache2 \
    apache2-dev \
    apt-utils \
    aptitude \
    autoconf \
    autotools-dev \
    bear \
    binutils \
    build-essential \
    cargo \
    chrpath \
    clang-15 \
    clang-format-15 \
    clang-tidy-15 \
    clang-tools-15 \
    clangd-15 \
    cppcheck \
    clang-tidy \
    cmake \
    curl \
    debhelper \
    dialog \
    direnv \
    devscripts \
    dnsutils \
    doxygen \
    dpkg-dev \
    enchant-2 \
    fakeroot \
    figlet \
    flex \
    freetds-bin \
    freetds-dev \
    g++ \
    gawk \
    gcc \
    gdebi \
    gettext \
    git \
    git-buildpackage \
    graphviz \
    gtk-doc-tools \
    iputils-ping \
    ksh \
    libc6-dev \
    libclang-15-dev \
    libclang-common-15-dev \
    libclang1-15 \
    libcurl4-openssl-dev \
    libenchant-2-2 \
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
    libmcrypt-dev \
    libmariadb-dev-compat \
    libmariadb-dev \
    libncurses5-dev \
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
    lldb \
    lld \
    lsb-release \
    make \
    mono-complete \
    mono-xbuild \
    musl-tools \
    nullmailer \
    openssh-client \
    openssl \
    patch \
    patchelf \
    php-common \
    pngcrush \
    p7zip-full \
    rpcbind \
    rpm \
    rrdtool \
    rsync \
    shellcheck \
    smbclient \
    software-properties-common \
    strace \
    sudo \
    tar \
    texinfo \
    tk-dev \
    uuid-dev \
    vim \
    valgrind \
    wget \
    xmlsec1 \
    zlib1g-dev \
    zstd \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*

# --- Node 22 -----------------------------------------------------------------
# The root Makefile's .ran-npm target greps `node --version` for ^v22. and
# `npm --version` for ^10., and fails the build otherwise. bookworm has 18.
RUN echo "Package: nodejs" >>/etc/apt/preferences.d/preferences \
    && echo "Pin: origin deb.nodesource.com" >>/etc/apt/preferences.d/preferences \
    && echo "Pin-Priority: 1001" >>/etc/apt/preferences.d/preferences
RUN apt-get update && apt-get remove -y nodejs libnode-dev libnode72 || true
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get update -y && apt-get install -y nodejs \
    && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
RUN node --version | grep -q '^v22\.' && npm --version | grep -q '^10\.'

# --- CMake -------------------------------------------------------------------
# bookworm has 3.25; rules_foreign_cc is happier on something recent.
RUN apt-get update && apt-get remove -y cmake && rm -rf /var/lib/apt/lists/* \
    && cd /tmp \
    && wget -q https://github.com/Kitware/CMake/releases/download/v3.31.0/cmake-3.31.0-linux-aarch64.sh \
    && chmod 755 cmake-3.31.0-linux-aarch64.sh \
    && ./cmake-3.31.0-linux-aarch64.sh --skip-license --prefix=/usr \
    && rm -f cmake-3.31.0-linux-aarch64.sh

# --- Python bootstrap --------------------------------------------------------
# Only the build tooling — the site's Python 3.12 is compiled from source by
# omd/packages/Python.
#
# Deliberately NOT installing the distro `pipenv` (2022.12.19): defines.make
# pins PIPENV_VERSION := 2023.11.15 and install-pipenv.sh pip-installs exactly
# that into /usr/local/bin. Having the older apt one on PATH as well only
# creates ambiguity about which the build picks up.
#
# Dropping EXTERNALLY-MANAGED is what lets install-pipenv.sh's plain
# `pip3 install` work on bookworm (PEP 668). This is a throwaway build
# container, and it removes the need for the upstream recipe's
# --break-system-packages patch entirely.
RUN apt-get update && apt-get install -y \
    python3 \
    libpython3.11 \
    libpython3-dev \
    python3-dev \
    python3-pip \
    python3-venv \
    python3-setuptools \
    python3-sphinx \
    libbz2-dev \
    liblzma-dev \
    libgdbm-dev \
    libnss3-dev \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/lib/python3.11/EXTERNALLY-MANAGED
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# --- Python 3.12 for the build host ------------------------------------------
# The root Makefile's .venv target runs `pipenv sync --python 3.12` and hard
# fails on bookworm ("Warning: Python 3.12 was not found on your system"),
# because Debian 12 ships 3.11. Upstream solves this the same way, via
# buildscripts/.../install-python.sh, which compiles CPython into
# /opt/Python-$PYTHON_VERSION — we keep that layout so install-pipenv.sh's
# fallback path lines up.
#
# Unlike upstream we skip --enable-optimizations/--with-lto and the custom
# OpenSSL: this interpreter only drives pipenv and the build scripts. The
# Python that actually ships inside the package is built separately by
# omd/packages/Python with the full flags. PGO+LTO here would add ~20 minutes
# on 4 cores for no benefit.
ARG PYTHON_BUILD_VERSION=3.12.13
RUN set -eux; \
    cd /tmp; \
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
        -O "https://www.python.org/ftp/python/${PYTHON_BUILD_VERSION}/Python-${PYTHON_BUILD_VERSION}.tgz"; \
    tar xf "Python-${PYTHON_BUILD_VERSION}.tgz"; \
    cd "Python-${PYTHON_BUILD_VERSION}"; \
    LDFLAGS="-Wl,--rpath,/opt/Python-${PYTHON_BUILD_VERSION}/lib" \
        ./configure \
        --prefix="/opt/Python-${PYTHON_BUILD_VERSION}" \
        --with-ensurepip=install \
        --enable-shared; \
    make -j"$(nproc)"; \
    make install; \
    cd /tmp; rm -rf "Python-${PYTHON_BUILD_VERSION}" "Python-${PYTHON_BUILD_VERSION}.tgz"; \
    ln -sf "/opt/Python-${PYTHON_BUILD_VERSION}/bin/python3.12" /usr/local/bin/python3.12; \
    ln -sf "/opt/Python-${PYTHON_BUILD_VERSION}/bin/pip3.12" /usr/local/bin/pip3.12; \
    python3.12 --version; \
    python3.12 -c 'import ssl, ctypes, sqlite3, lzma, bz2; print("stdlib ok:", ssl.OPENSSL_VERSION)'

# --- pipenv ------------------------------------------------------------------
# Versions pinned by defines.make (PIPENV_VERSION / VIRTUALENV_VERSION).
# Baked into the image rather than left to the build's install-pipenv.sh stage:
# that script installs into the container's writable layer, which disappears
# whenever the container is recreated, while the stage marker on the bind mount
# survives — so the build would skip the stage and then fail with
# "pipenv: command not found".
RUN pip3 install --no-cache-dir pipenv==2023.11.15 virtualenv==20.25.0 \
    && pipenv --version

# --- GCC 14 aliases ----------------------------------------------------------
# defines.make names 14.2.0 and several packages invoke `g++-14` by name, but
# bookworm's newest is 12. The 2.2 recipe solved this the same way. gcc-12
# builds Checkmk 2.3 fine; only the *name* is missing.
RUN for v in 13 14; do \
        for t in gcc g++ cpp gcc-ar gcc-nm gcc-ranlib gcov; do \
            ln -sf "/usr/bin/$t" "/usr/bin/$t-$v"; \
        done; \
    done \
    && g++-14 --version && gcc-14 --version

# --- Bazel via bazelisk ------------------------------------------------------
# bazelisk reads .bazelversion (6.5.0 for 2.3) and .bazeliskrc, instead of us
# guessing a version. Its download cache lands in /root/.cache/bazelisk, which
# run.sh bind-mounts, so it survives container recreation.
RUN curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
        -o /usr/local/bin/bazel \
        https://github.com/bazelbuild/bazelisk/releases/download/v1.25.0/bazelisk-linux-arm64 \
    && chmod 755 /usr/local/bin/bazel \
    && test -s /usr/local/bin/bazel

# --- Rust --------------------------------------------------------------------
# bookworm ships 1.63; defines.make/install-rust-cargo.sh want 1.90 for the
# agent controller. Installed under /opt so the /root bind mount cannot mask it.
ENV RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo
ENV PATH="/opt/rust/cargo/bin:${PATH}"
RUN apt-get update && apt-get remove -y cargo rustc || true; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && sh /tmp/rustup-init.sh -y --no-modify-path --default-toolchain 1.90 \
    && rm -f /tmp/rustup-init.sh \
    && rustup target add aarch64-unknown-linux-musl \
    && rustc --version && cargo --version

# ENV alone is not enough: run.sh execs `bash -l`, and /etc/profile resets PATH
# to the distro default, which would hide cargo/rustc from the build.
RUN printf '%s\n' \
    'export RUSTUP_HOME=/opt/rust/rustup' \
    'export CARGO_HOME=/opt/rust/cargo' \
    'export PATH=/opt/rust/cargo/bin:/usr/local/bin:$PATH' \
    >/etc/profile.d/00-cmk-toolchain.sh

# Sanity checks for the things the aarch64 patches depend on existing.
RUN test -f /usr/share/misc/config.guess \
    && test -f /usr/share/misc/config.sub \
    && test -e /usr/lib/aarch64-linux-gnu/libc.so.6 \
    && test -d /usr/lib/gcc/aarch64-linux-gnu/12

RUN mkdir -p /opt/build-mk/{debs,patches,distdir,state,logs}
WORKDIR /opt/build-mk
