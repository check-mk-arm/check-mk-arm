# Checkmk 2.4.0 aarch64 patch set

Applied in the order given by `series`. `lib/build-common.sh` dry-runs each
patch immediately before applying it and aborts on the first failure, so a
patch that stops applying against a newer patch level is loud, not silent.

Numbering carries intent:

| Range       | Meaning                                              | Upstreamable?          |
| ----------- | ---------------------------------------------------- | ---------------------- |
| `0001-0099` | aarch64 architecture fixes                           | yes — offer to Checkmk |
| `0100-0199` | reachability of downloads (internal mirrors)         | no                     |
| `0300-0399` | build-host conveniences: building from the release tarball rather than a git checkout, and as root | partly |

This set was derived from the 2.3 one by checking every patch against the real
v2.4.0p35 tree, then sweeping the tree for x86-only paths, unreachable hosts and
`*_http.bzl` entries with no public URL. Verified against
`check-mk-raw-2.4.0p35.cre.tar.gz`, sha256
`c6f4a0be7656bbf6eeb48db6ed52604a9c0fa38225fe55cd22fe25d3758c418d`.

## The patches

| Patch | What / why | Droppable when |
| ----- | ---------- | -------------- |
| `0001-python-sysconfigdata-aarch64` | CPython names its sysconfig module after the host triplet. 2.4 dropped `Python.make`, but the hardcoded `_sysconfigdata__linux_x86_64-linux-gnu.py` survives in `BUILD.Python.bazel`'s postfix script **and** in `omd/packages/packages.make`, which seds the OMD prefix into it after the Bazel tree is unpacked. | upstream derives the name from the triplet |
| `0002-bazel-pathhash-aarch64` | `scripts/run-bazel.sh` (renamed from `run-bazel-build.sh` in 2.4) fingerprints the toolchain via four x86-only paths. On aarch64 all four hash to nothing and `create_build_environment_variables.py` raises *"All provided 'pathhash' items result in emtpy hashes"*. Repointed at the aarch64 libc, the gcc dir and `/usr/bin/gcc`. | upstream picks paths per architecture |
| `0003-cc-toolchain-aarch64` | New in 2.4: `MODULE.bazel` does `register_toolchains("//bazel/toolchains/cc:linux_gcc14")`, and both toolchains in that file are `cpu = "k8"` with `exec/target_compatible_with = ["@platforms//cpu:x86_64"]`. On aarch64 resolution therefore falls through to Bazel's auto-detected local toolchain — which builds, but without `CXX_FLAGS = ["-std=c++20"]`, so livestatus/neb fail to compile. Adds a `linux_gcc14_aarch64` entry (trixie's native gcc-14, `/usr/lib/gcc/aarch64-linux-gnu/14/include`) and makes `cpu` and the platform constraint per-toolchain instead of hardcoded. Registered via `--extra_toolchains` in `bazelrc.local`, not `register_toolchains`, so `MODULE.bazel.lock` is unaffected. | upstream ships an aarch64 toolchain |
| `0004-net-snmp-perl-archlib-aarch64` | `INSTALLARCHLIB` hardcodes `x86_64-linux-gnu-thread-multi`; perl's real `archname` here is `aarch64-linux-gnu-thread-multi`. | upstream uses `$Config{archname}` |
| `0005-snap7-aarch64-build-profile` | snap7 ships one makefile per architecture and the BUILD file asks for `x86_64_linux.mk`. `aarch64_linux.mk` is generated from upstream's `arm_v6_linux.mk` by the `seed-distdir` build stage. | snap7 ships an aarch64 profile upstream |
| `0006-omd-drop-navicli-x86-only` | `navicli` installs prebuilt x86-only EMC binaries. There is no aarch64 build, so the package is dropped entirely. | EMC ships aarch64 binaries (unlikely) |
| `0007-perl-modules-tar-no-same-owner` | The build runs as root in a container, so `tar` tries to restore the uid/gid recorded inside CPAN tarballs and fails. | build stops running as root |
| `0008-system-libs-aarch64-multiarch` | New in 2.4: `@glib` and `@libxml2` are `new_local_repository(path = "/usr")` wrappers whose BUILD files reference the system libraries through the *Debian multiarch* directory — `lib/x86_64-linux-gnu/libglib-2.0.so`, `.../glib-2.0/include/glibconfig.h`, `lib/x86_64-linux-gnu/libxml2.so`. Those paths simply do not exist on arm64. `rrdtool` has the same problem in a `-I` copt. | upstream selects on the target CPU (or uses pkg-config) |
| `0009-rust-agents-host-architecture` | New in 2.4: `agents/linux/{cmk-agent-ctl,mk-sql}` are no longer shipped prebuilt in the release tarball, so `agents/Makefile` builds them — and it installs them from `target/x86_64-unknown-linux-musl/release/`, while `packages/host/{cmk-agent-ctl,mk-sql}/run` force `CARGO_BUILD_TARGET=x86_64-unknown-linux-musl`. Rewritten in terms of `uname -m`, which is correct on both architectures. The same patch makes those two scripts survive outside a git checkout: `REPO_DIR="$(git rev-parse --show-toplevel)"` under `set -e` aborts the build from a tarball. `rust-toolchain.toml`'s target list is fixed up to match. | upstream derives the target from the host |
| `0010-python-interpreter-aarch64` | New in 2.4: `MODULE.bazel` asks `rules_python` for CPython **3.12.11**, which rules_python 0.37.0 does not know about — the only reason it resolves at all is a `single_version_platform_override` that supplies a URL and sha256 for `x86_64-unknown-linux-gnu` alone. On aarch64 there is no interpreter to register. Adds the matching `aarch64-unknown-linux-gnu` override from the same python-build-standalone release (`20250604`). This is the one patch that touches `MODULE.bazel`, hence `--lockfile_mode=update` in `bazelrc.local`. | rules_python is new enough to know 3.12.11, or upstream overrides all platforms |
| `0011-pkgconfig-aarch64-multiarch` | Fourteen `BUILD.*.bazel` files put `/usr/lib/x86_64-linux-gnu/pkgconfig` into a `PKG_CONFIG_PATH` action env. That looks inert — `PKG_CONFIG_PATH` normally only *prepends* to pkg-config's compiled-in path, which on Debian arm64 already contains the aarch64 multiarch directory — but rules_foreign_cc bootstraps and uses **its own** pkg-config, whose built-in path has no Debian multiarch entry at all. `PKG_CONFIG_PATH` is therefore the only search path there is, and msitools fails at configure with *"No package 'gobject-2.0' found"*. Repointed at the aarch64 directory. | upstream selects on the target CPU |
| `0012-strip-skip-foreign-arch-binaries` | `omd/strip_binaries` runs `/usr/bin/strip` over the whole packaged tree, and Debian's binutils is built for the native target only — so the prebuilt **x86-64** robotmk binaries kill the last step of the build with *"Unable to recognise the format of the input file"*. The script already parses the ELF header, so it now also reads `e_machine` and skips anything that is not the host's architecture. A no-op on x86-64 hosts, and it means the next prebuilt foreign payload upstream adds will not break the arm64 build. | upstream checks the machine, or ships a multiarch strip |
| `0100-snap7-repackaged-tarball-sha` | snap7 1.4.2 is published only as `.7z`, so Checkmk serves a repackaged tarball from `artifacts.lan.tribe29.com`, which is unreachable externally. `seed-distdir` reproduces that repackaging locally — following the recipe preserved in `snap7.make`'s commented-out `snap7-repackage` target — and feeds it to Bazel via `--distdir`. Only the checksum differs. | snap7 publishes a `.tar.gz`, or Checkmk mirrors it publicly |
| `0101-jaeger-linux-arm64` | `jaeger_http.bzl` fetches `jaeger-2.18.0-linux-amd64.tar.gz` and `omd/packages/jaeger/BUILD` untars a path containing `-linux-amd64`. jaeger is in `PACKAGES` for the raw edition. The upstream release does publish `jaeger-2.18.0-linux-arm64.tar.gz`; both the filename and the sha256 are repointed at it. | upstream selects the asset per architecture |
| `0110-nagios-modern-config-guess` | nagios 3.5.1 (2013) ships autotools helpers that predate aarch64: *"configure: error: cannot guess build type"*. `http_archive`'s `patch_cmds` copy in the host's current `config.guess`/`config.sub`, including the second pair under `tap/`. | nagios ships a config.guess newer than 2013 |
| `0111-pnp4nagios-modern-config-guess` | Same for pnp4nagios 0.6.26. | as above |
| `0300-check_mk-idempotent-check-rename` | The legacy-check `.py`-stripping rename finds nothing on a second run, and `xargs -n2 mv` without `-r` then runs `mv` with no arguments and fails. 2.4 already restricts the `find` to `*.py` (the other half of the 2.3 patch), so only `-r` is left. | upstream adds `-r` |
| `0301-omd-commit-from-tarball` | The install step runs `git rev-parse HEAD`, which exits 128 when building from the release tarball rather than a checkout. The tarball ships a `COMMIT` file with the real hash, so prefer that and keep git as the fallback. | upstream uses the shipped COMMIT file |
| `0302-python-toolchain-allow-root` | New in 2.4: `rules_python` refuses the hermetic interpreter outright when the build runs as root — *"The current user is root, please run as non-root when using the hermetic Python interpreter"* — which upstream never hits because their CI builds as an unprivileged user. `ignore_root_user_error = True` is the documented escape hatch. Ordered after `0010`, which edits the same `python.toolchain()` call. | the build stops running as root |
| `0303-omd-skel-permissions-no-non-free` | The `skel.permissions` aggregation does an unconditional `cd ../../non-free/packages`, and `make dist` builds the tarball with `--exclude non-free` — so the directory does not exist in any released source archive and the step dies with *"No such file or directory"*. The loop is guarded, and the following Bazel call is given an explicit `cd $(REPO_PATH)` instead of relying on being left inside a non-free directory. | upstream guards it |
| `0304-check_mk-idempotent-lib-symlink` | `ln -sf python3/cmk .../lib/check_mk` is not repeatable: the second time round the destination already exists *as a symlink to that directory*, so `ln` dereferences it and creates `lib/python3/cmk/cmk -> python3/cmk` inside it. A later `grep -R` over the tree then dies on the dangling link. `-sfn` replaces the link instead. | upstream uses `-sfn`, or stops re-running install |
| `0305-idempotent-resumed-install` | Two more steps that only fail on a *resumed* build. `rabbitmq.make` calls `$(RM)` (i.e. `rm -f`) on `lib/rabbitmq` before re-extracting its tarball, which cannot remove the directory the previous run left. And `omd/Makefile`'s `ln -sf $(OMD_VERSION) versions/default` has the same dereference footgun as `0304` — there the consequence would be a self-referential directory shipped inside the version tree. | as above |
| `0306-bom-fallback-valid-json` | `omd/Makefile`'s `$(BOM)` rule exists precisely so that a missing bill of materials does not fail the build ("just create an empty one instead of failing the build") — but it `touch`es a zero-byte file, and `//omd:generate_bom_csv` then feeds it to `json.load()` and reads `bom_info["components"]`. The fallback now writes `{"components": []}`, which is what the consumer needs. Upstream never notices: their CI always supplies a real BOM. | upstream's fallback writes valid JSON |
| `0307-binreplace-any-build-root` | The build-time absolute path baked into `libcrypto.so.3` is stripped out with the regex `/home/.*?/openssl.build_tmpdir/openssl/`, which assumes the build runs under `/home`. Ours runs under `/root/.cache/bazel`, so nothing matched and the declared output was never created. Replaced with a NUL-bounded character class, which is host-agnostic *and* safer than upstream's `.*?`: it cannot run past the string's null terminator into unrelated bytes. Both the Bazel action and the `packages.make` copy of the same command are fixed. | upstream anchors on the sandbox root it is given |

## Carried over from 2.3 but no longer needed

Each of these was checked against the v2.4.0p35 tree:

- **`0003-protobuf-static-link-latomic`** — `omd/packages/protobuf` is now a
  `bazel_dep(name = "protobuf", version = "29.3")`; the hand-rolled
  `protoc-static` link line that needed `-latomic` is gone.
- **`0101-python3-modules-public-pypi`** — `static_variables.bzl` and its
  `INTERNAL_PYPI_MIRROR` no longer exist. `python3-modules` now pip-installs with
  `--no-binary=:all:` from the default index, which also removes any
  missing-aarch64-wheel concern for the shipped modules.
- **`defines.make` PyPI mirror / `USE_EXTERNAL_PIPENV_MIRROR`** — the whole
  pipenv path is gone; there is no such variable in 2.4.
- **`xmlsec1` distdir seed** — 2.4 fetches xmlsec1 from the project's GitHub
  release, which works.
- **webpack `NODE_OPTIONS` cap** — done as an environment variable in the
  `frontend` build stage instead of a patch to a Makefile that no longer has the
  target.
- **stunnel `config.guess`** — 2.4 bumped stunnel 5.63 → 5.78 (2024), whose own
  autotools helpers already know aarch64.

## Verified benign, deliberately not patched

`omd/packages/apache-omd/BUILD` branches on `uname -m` and falls back to
`APACHE_MODULE_DIR`; on Debian both that and `APACHE_MODULE_DIR_64` are
`/usr/lib/apache2/modules`, so the non-x86_64 branch is correct.

`MODULE.bazel`'s shellcheck / shfmt / taplo / ocb downloads are all
`linux_amd64`, but none of them is reachable from a raw-edition `make deb` — they
are lint tooling and the (cloud-only) OpenTelemetry collector builder.

## Dead upstream URLs (fixed by seeding the distdir, not by patching)

Rather than patch each URL — which would rot again — `build.sh` downloads them
once into Bazel's `--distdir`, where they are matched by name and verified
against the sha256 the tree already pins.

| Tarball | Why the tree's URL fails | Seeded from |
| --- | --- | --- |
| ~84 CPAN modules | `www.cpan.org/modules/by-module/` only serves each distribution's *current* release, so every pinned older version 404s | MetaCPAN release index, BackPAN for deleted releases |
| `snap7-1.4.2` | no public URL at all; upstream ships only `.7z` since 1.4.2 | repackaged locally from SourceForge |
| `patch-2.7.6` | `ftpmirror.gnu.org` is a redirector that regularly lands on a mirror returning 502 | `ftp.gnu.org` |
| `heirloom-mailx_12.5` | `ftp.nl.debian.org` presents a certificate that does not match the hostname, so Bazel refuses the connection | `archive.debian.org` |
| `jaeger-2.18.0-linux-arm64` | the URL works; seeded only because patch `0101` has to pin the sha256 anyway and it saves 59 MB per cold build | GitHub release |

## Things the tarball omits (restored by build.sh, not patched)

`make dist` builds the release tarball with `tar ... * .werks`, and a shell glob
does not match dotfiles — so **every dotfile in the repository root is missing**
while dotfiles in subdirectories survive. Three of them are load-bearing:

- **`.bazelversion`** (`7.5.0`) and **`.bazeliskrc`**
  (`USE_BAZEL_VERSION=aspect/2025.11.0`) — without them bazelisk installs the
  newest Bazel, which is not the one the shipped `MODULE.bazel.lock` was written
  by. The aspect-cli release publishes `bazel-2025.11.0-linux-arm64`.
- **`.bazelrc`** — restored verbatim from the `v2.4.0p35` tag as
  `files/bazelrc`. Losing it costs, among other things,
  `--@//:filesystem_layout=lsb` (without which every omd package fails its
  `select()` with *"Please build with lsb or fhs filesystem layout"*), the
  `--flag_alias=cmk_version` that makes `packages.make`'s `--cmk_version` a real
  flag, and `--registry=file://%workspace%/bazel/registry`.

Our own Bazel settings are *not* merged into that copy. They go into
`/etc/ci.bazelrc`, which upstream's `.bazelrc` try-imports as its very last line
— the only rc file that can override the settings above it. See
`../bazelrc.local`.

## Prebuilt payloads the tarball omits (lifted from the donor package)

Two sets, both handled by `build.sh`'s `donor-artifacts` stage:

- **`agents/windows/`** — the `.msi`, `python-3.cab`, `windows_files_hashes.txt`,
  `check_mk.user.yml` and `unsign-msi.patch` that `artifacts.make` lists as
  required build inputs. The Windows agent is built on a Windows node; this is
  what every ARM recipe has always done. The donor's copy is *merged* into the
  tree's rather than replacing it: only the tarball has `check_mk.yml` and the
  standalone `.exe` agents.
- **`agents/check-mk-agent-<ver>-1.noarch.rpm`** and
  **`agents/check-mk-agent_<ver>-1_all.deb`** — the x86-64 Linux agent packages,
  i.e. what the site's agent download page serves and what the bakery starts
  from. `artifacts.make` puts them in `SOURCE_BUILT_LINUX_AGENTS` beside
  `agents/linux/*`, "created … by an upstream job or while creating the source
  package", but the tarball ships neither. The two rules that would produce them
  — the root `Makefile`'s `$(SOURCE_BUILT_LINUX_AGENTS): $(MAKE) -C agents $@`
  and the identical one in `omd/packages/check_mk/check_mk.make` — declare **no
  prerequisites**, so dropping the files in before the build is enough to stop
  them being built. That matters because building them here is silently wrong:
  `agents/Makefile` names them `_all`/`noarch` unconditionally while filling
  them from `$(AGENT_CTL_GZ)` and `$(MK_SQL)`, which patch 0009 compiles for the
  host — so this host produces an "architecture-independent" agent package
  wrapped around **aarch64** binaries, which runs on no x86 host.

  2.4 has no aarch64 pair to sit beside them; `…-1.aarch64.rpm` and
  `…_arm64.deb` arrive upstream in 2.5 with werk #19275. `agents/linux/cmk-agent-ctl`
  therefore stays aarch64 as patch 0009 built it — it is what an arm64 monitored
  host gets — and `ci/verify-deb.sh` checks only that the controller inside the
  `_all.deb` is x86-64.

## Build-environment fixes that are not patches

Three failures were fixed in the builder image or in `../bazelrc.local` rather
than in the tree, because they are properties of *this* build host, not of
Checkmk:

- **Rust is invisible to Bazel actions.** `python3-modules` pip-installs every
  module with `--no-binary=":all:"`, so `bcrypt` and friends are compiled from
  source and need a Rust toolchain — but `.bazelrc` pins the action `PATH` to
  `/usr/bin:/bin` for hermeticity, which hides the rustup installation under
  `/opt` ("error: can't find Rust compiler"). `bazelrc.local` extends the action
  `PATH` and adds `CARGO_HOME`, since the action environment has no `$HOME`.
  Upstream's build images instead symlink tools into `/usr/bin`.
- **`ninja` was missing.** numpy builds through meson-python, which — finding no
  `ninja` — pip-installs the `ninja` *sdist*, which pulls the PyPI `cmake` sdist,
  which bootstraps by downloading a tarball and fails. The distro `ninja-build`
  package cuts that chain at the first link.
- **The system `cmake` is unusable inside these actions, on trixie only.**
  `build-python3-modules.bzl` puts Checkmk's bundled OpenSSL 3.0.21 first on
  `LD_LIBRARY_PATH`, and trixie's `libcurl` needs `OPENSSL_3.2/3.3` symbols that
  3.0.21 does not export — so any system binary linking libcurl dies with
  *"version `OPENSSL_3.2.0' not found"*. That is what made pillow's build fall
  back to the PyPI `cmake` sdist. The image therefore installs Kitware's own
  aarch64 binary, which is statically linked (no libcurl, no libssl, not even
  libstdc++), *over* `/usr/bin/cmake` — over, rather than earlier on `PATH`,
  because `PATH` is part of every Bazel action's cache key. Upstream never sees
  this: they build on Ubuntu, whose system OpenSSL is 3.0.x and so compatible.

## Patches that only matter to a resumable build

`0300`, `0304` and `0305` all fix the same class of bug: an install step that
works once and fails the second time. They exist because this recipe deliberately
omits `debuild`'s `clean` phase so a failed build can be resumed cheaply (see
`build.sh`), while upstream's builds always start from an empty tree and so never
execute these steps twice. Set `CMK_FULL_CLEAN=1` to build the upstream way.

## Build steps that replace patches

Two things the 2.3 recipe got for free are build stages here, because the
tarball no longer contains their output:

- **`frontend`** — `packages/cmk-frontend/dist` and
  `packages/cmk-frontend-vue/dist` are gitignored build output that
  `check_mk.make` nevertheless tars into `share/check_mk/web/htdocs`. Upstream
  builds them in the root Makefile's `dist` target, i.e. while *creating* the
  tarball.
- **`venv`** — `check_mk.make` runs `make -C doc/plugin-api html`, which goes
  through `scripts/run-uvenv`, which runs `make .venv`, which has Bazel resolve
  `requirements_all_lock.txt` with `uv`. It is a genuine build dependency and
  gets its own stage so that a failure there is not mistaken for a packaging
  failure hours in.
