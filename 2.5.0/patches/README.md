# Checkmk 2.5.0 aarch64 patch set

Applied in the order given by `series`. `lib/build-common.sh` dry-runs each
patch immediately before applying it and aborts on the first failure, so a
patch that stops applying against a newer patch level is loud, not silent.

Numbering carries intent:

| Range       | Meaning                                              | Upstreamable?          |
| ----------- | ---------------------------------------------------- | ---------------------- |
| `0001-0099` | aarch64 architecture fixes                           | yes — offer to Checkmk |
| `0100-0199` | reachability of downloads (internal mirrors)         | no                     |
| `0300-0399` | build-host conveniences: building from the release tarball rather than a git checkout | partly |

Verified against `check-mk-community-2.5.0p11.tar.gz`, sha256
`26268c0337803f5cb1726900faca3726fe78187b656b1ee381c0682c2a6b3c5d`.

## What changed between 2.4 and 2.5

Enough that this is a re-derivation rather than a port. Three upstream changes
account for almost all of it:

- **The package is a Bazel target.** `omd/Makefile`, `omd/packages/*/*.make`
  and `omd/debian/rules` are gone; `//omd:deb_community` is a `rules_pkg`
  `pkg_deb`. That deletes the entire 2.4 `0300`-series — the idempotent-install
  patches existed only because this recipe skipped `debuild`'s `clean` phase to
  keep retries cheap, and there is no `debuild` any more.
- **Third-party packages moved into a local Bazel registry** under
  `bazel/thirdparty/modules/<name>/<version>/`, in Bazel Central Registry
  layout. Patching one of them means patching `overlay/BUILD.bazel` *and*
  re-pinning its `sha256-` integrity in the module's `source.json`, which the
  patches below do together.
- **The Raw edition is called Community.** It changes the source tarball's name
  (and drops the `.cre` infix), the edition flag, the Bazel target, the package
  name and the `<version>.<edition>` install directory.

## The patches

| Patch | What / why | Droppable when |
| ----- | ---------- | -------------- |
| `0001-python-sysconfigdata-aarch64` | CPython names its sysconfig module after the host triplet, and the hardcoded `_sysconfigdata__linux_x86_64-linux-gnu.py` appears twice: in `BUILD.Python.bazel`'s postfix script, which seds the OMD prefix into it, and in `omd/packages/Python/BUILD`'s `string_replace` filepattern, which does the same for the version directory. | upstream derives the name from the triplet |
| `0002-cc-toolchain-aarch64` | `bazel/toolchains/cc/gcc/local/BUILD` defines exactly one non-hermetic toolchain, `linux_x86_64` — `cpu = "k8"`, x86-64 multiarch include directories, x86-64 exec/target constraints. (The hermetic bootlin toolchain beside it is x86-64 only as well, but nothing selects it unless you ask for `//bazel/platforms:x86_64-linux-gcc-hermetic`.) On aarch64 resolution therefore falls through to Bazel's auto-detected local toolchain, which builds but without `cxx_flags = ["-std=c++20"]`, so livestatus and neb fail to compile. Adds a `linux_aarch64` twin. Registered via `--extra_toolchains` in `bazelrc.local`, not `register_toolchains`, so `MODULE.bazel.lock` is unaffected. | upstream ships an aarch64 toolchain |
| `0003-net-snmp-perl-archlib-aarch64` | `INSTALLARCHLIB` hardcodes `x86_64-linux-gnu-thread-multi`; perl's real `archname` here is `aarch64-linux-gnu-thread-multi`. | upstream uses `$Config{archname}` |
| `0004-snap7-aarch64-build-profile` | Two aarch64 problems in one package. `snap7_repository.bzl` downloads `7z<ver>-linux-x64.tar.xz` to unpack snap7's `.7z`, and that binary does not run on arm64 — it now picks the archive by `repository_ctx.os.arch`. And snap7 1.4.2 ships one makefile per architecture with no aarch64 among them (i386, x86_64, arm_v6, arm_v7, mips), so the rule derives `build/unix/aarch64_linux.mk` from upstream's `arm_v6_linux.mk`, which is the derivation Checkmk's own commented-out `snap7-repackage` target documented. `BUILD.snap7.bazel` selects the profile on the target CPU. 2.4 did the repackaging on the host and fed it to Bazel through `--distdir`; 2.5 fetches the `.7z` from SourceForge directly, so that whole stage is gone. | snap7 ships an aarch64 profile upstream |
| `0005-perl-modules-tar-no-same-owner` | The build runs as root in a container, so `tar` tries to restore the uid/gid recorded inside CPAN tarballs and fails. Now lives in the local registry at `bazel/thirdparty/modules/perl-modules/…/src/lib/BuildHelper.pm` (a `local_path` module, so no integrity to re-pin). | build stops running as root |
| `0006-system-libs-aarch64-multiarch` | `@glib` and `@libxml2` overlay the distro's own libraries and reference them through the *Debian multiarch* directory — `lib/x86_64-linux-gnu/libglib-2.0.so`, `.../glib-2.0/include/glibconfig.h`, `lib/x86_64-linux-gnu/libxml2.so`. Those paths do not exist on arm64. `rrdtool` has the same problem in a `-I` copt. Note the select is on `@cmk//filesystem_layout`, i.e. on the *distro*, not on the CPU — which is why it cannot be right for both architectures as written. | upstream selects on the target CPU (or uses pkg-config) |
| `0007-python-interpreter-aarch64` | `bazel/module/py.MODULE.bazel` pins six CPython patch levels that rules_python 1.4.1 does not know (3.13.14 for the build, 3.8–3.12 for the agent-plugin tests). Each resolves only because of a `single_version_platform_override` that supplies a URL and sha256 for `x86_64-unknown-linux-gnu` alone, so on aarch64 there is no interpreter and the pip extension fails outright with *"Unable to find interpreter for pip hub 'agent_plugins_requirements_3_9'"* — during module evaluation, so it does not matter that those five are test-only. Adds the matching aarch64 override from each python-build-standalone release. | rules_python knows these versions, or upstream overrides all platforms |
| `0008-pkgconfig-aarch64-multiarch` | Fourteen build files put `/usr/lib/x86_64-linux-gnu/pkgconfig` into a `PKG_CONFIG_PATH` action env. That looks inert — `PKG_CONFIG_PATH` normally only *prepends* to pkg-config's compiled-in path, which on Debian arm64 already contains the aarch64 multiarch directory — but rules_foreign_cc bootstraps and uses **its own** pkg-config, whose built-in path has no Debian multiarch entry at all. `PKG_CONFIG_PATH` is therefore the only search path there is, and msitools fails at configure with *"No package 'gobject-2.0' found"*. Five of the fourteen are registry overlays, so their `source.json` integrity is re-pinned in the same patch. | upstream selects on the target CPU |
| `0009-deb-architecture-arm64` | `omd/BUILD` hardcodes `architecture = "amd64"` twice: once in `pkg_name_info`, which builds the filename, and once in `pkg_deb`, which writes the control field. Replaced by a `select()` on the target CPU, so the package is named and declared `arm64`. | upstream derives it from the target platform |
| `0010-jaeger-linux-arm64` | The `@jaeger` `http_file` fetches `jaeger-2.18.0-linux-amd64.tar.gz` and `omd/packages/jaeger/BUILD` untars a path containing `-linux-amd64`. jaeger is in the community edition's dependency list. The upstream release does publish `jaeger-2.18.0-linux-arm64.tar.gz`; both the filename and the sha256 are repointed at it. | upstream selects the asset per architecture |
| `0011-nagios-build-triplet` | nagios 3.5.1 (2013) ships a `config.guess` from 2006, which predates aarch64: *"configure: error: cannot guess build type"*. 2.4 solved this by copying the host's `config.guess` in through `http_archive`'s `patch_cmds`; the registry's `source.json` has no equivalent, so instead `--build=aarch64-unknown-linux-gnu` is added to `configure_options`, which skips `config.guess` altogether. Its `config.sub`, which canonicalises what we pass, is new enough to know aarch64. | nagios ships a config.guess newer than 2013 |
| `0012-pnp4nagios-build-triplet` | Same, for pnp4nagios 0.6.26 and its 2008 `config.guess`. | as above |
| `0013-rust-crates-aarch64-platform` | `@site_crates` — the crate_universe repository behind `check-cert` and `check-http`, both of which are in the package — declares `supported_platform_triples = ["x86_64-unknown-linux-gnu"]`, so its generated `select()` tables have no aarch64 column and the crates would build without their dependencies. Adding the triple invalidates the checked-in `site.Cargo.lock.bazel`; the `repin-crates` build stage regenerates it from the unchanged `Cargo.lock`, so no dependency resolves differently. | upstream lists both host triples |
| `0300-workspace-status-from-tarball` | `.bazelrc` sets `--workspace_status_command=bazel/tools/workspace_status.sh`, and that script runs `git rev-parse HEAD` under `set -e`, which exits 128 when building from the release tarball rather than a checkout. The tarball ships a `COMMIT` file with the real hash (upstream's own `//omd:hash_file_pkg` consumes the same value), so prefer that and keep git as the fallback. The commit timestamp falls back to `SOURCE_DATE_EPOCH`. | upstream uses the shipped COMMIT file |

## Verified benign, deliberately not patched

`bazel/toolchains/cc/gcc/bootlin/` and `@gcc-linux-x86_64` are x86-64 only, and
`omd/packages/cpp-libs/BUILD` selects them — but only under
`//bazel/platforms:is_hermetic`, which nothing turns on for this build. The
`cpp_libs_usr` repository used instead discovers its libraries with
`g++ -print-file-name`, which is architecture-agnostic.

`bazel/rules/pkg_rpm_from_tar.bzl` and `pkg_cma_from_tar.bzl` hardcode
`x86_64`/`.x86_64.rpm` in their output names, but only `//omd:deb_community` is
built here.

`MODULE.bazel`'s taplo and OpenTelemetry-collector-builder downloads are
`linux_amd64`/`x86_64`, but neither is reachable from `//omd:deb_community` —
they are lint tooling and a cloud-edition component.

`bazel/module/rust/tools.MODULE.bazel` also supports only `x86_64-unknown-linux-gnu`,
but `@tools_crates` exists solely for `//tests/packaging/package_validator`,
which the `//omd:validate_deb_community` test uses. We validate the package with
`ci/verify-deb.sh` instead.

## Dead upstream URLs (fixed by seeding the distdir, not by patching)

Rather than patch each URL — which would rot again — `build.sh` downloads them
once into Bazel's `--distdir`, where they are matched by name and verified
against the sha256 the tree already pins.

| Tarball | Why the tree's URL fails | Seeded from |
| --- | --- | --- |
| ~85 CPAN modules | `www.cpan.org/modules/by-module/` only serves each distribution's *current* release, so every pinned older version 404s | MetaCPAN release index, BackPAN for deleted releases |
| `patch-2.7.6` | `ftpmirror.gnu.org` is a redirector that regularly lands on a mirror returning 502 | `ftp.gnu.org` |
| `jaeger-2.18.0-linux-arm64` | the URL works; seeded only because patch `0010` has to pin the sha256 anyway and it saves 59 MB per cold build | GitHub release |

## Things the tarball omits (restored by build.sh, not patched)

`make dist` builds the release tarball with `tar ... * .werks`, and a shell glob
does not match dotfiles — so **every dotfile in the repository root is missing**
while dotfiles in subdirectories survive. In 2.5 eight of them are load-bearing,
against three in 2.4, because more of the build's configuration moved into the
root:

- **`.bazelversion`** (`8.5.0`) and **`.bazeliskrc`**
  (`USE_BAZEL_VERSION=aspect/2025.51.5`, and note the base URL moved to
  `aspect-cli-legacy`) — without them bazelisk installs the newest Bazel, which
  is not the one the shipped `MODULE.bazel.lock` was written by. The release does
  publish `bazel-2025.51.5-linux-arm64`.
- **`.bazelrc`** — losing it costs `--@cmk//distro` (without which every omd
  package fails its `select()` with *"Please build with lsb or fhs filesystem
  layout"*), the `--flag_alias` definitions behind `--cmk_version` and
  `--cmk_edition`, the `--registry=file:///%workspace%/bazel/thirdparty` local
  registry that every third-party module resolves through, and
  `--workspace_status_command`.
- **`.bazelignore`** — keeps Bazel out of `bazel/cmk` (a `local_path_override`
  module) and `bazel/thirdparty` (the registry). `npm_translate_lock` also names
  it directly as `verify_node_modules_ignored`.
- **`.npmrc`** and **`.cargo/config.toml`** — named by
  `bazel/module/js.MODULE.bazel` and `bazel/module/rust/host.MODULE.bazel`.
- **`.clang-tidy`** and **`.prettierignore`** — named by the root `BUILD`'s
  `exports_files`, which fails to load when a listed file is absent, whether or
  not anything depends on it.

All eight are byte-for-byte copies from the `v2.5.0p11` tag, kept in `../files/`
(with `/` flattened to `_`, so `.cargo/config.toml` is stored as
`cargo_config.toml`).

Our own Bazel settings are *not* merged into that copy. They go into
`/etc/ci.bazelrc`, which upstream's `.bazelrc` try-imports near its end. See
`../bazelrc.local`.

## Prebuilt payloads the tarball omits (lifted from the donor package)

Three sets, all handled by `build.sh`'s `donor-artifacts` stage:

- **`agents/windows/`** — the `.msi`, `python-3.cab`, `windows_files_hashes.txt`,
  `check_mk.user.yml` and `unsign-msi.patch`, all of which
  `//agents/windows:agents` lists as required inputs. The Windows agent is built
  on a Windows node; this is what every ARM recipe has always done.
- **`agents/linux/`** — new in 2.5. `cmk-agent-ctl`, `cmk-agent-ctl.gz`,
  `cmk-agent-ctl-aarch64`, `cmk-agent-ctl-aarch64.gz` and `mk-sql`, named
  individually by `//agents:agents-linux`. These are static musl binaries *for
  monitored hosts*; `agents/Makefile` builds them through Bazel's musl
  toolchains, which resolve only on an x86-64 exec platform. Taking them from
  the donor gives byte-identical payloads to the official build.
- **`agents/check-mk-agent-<ver>-1.noarch.rpm`** and
  **`agents/check-mk-agent_<ver>-1_all.deb`** — the x86-64 Linux agent packages,
  i.e. what the site's agent download page serves and what the bakery starts
  from. `artifacts.make` puts them in `SOURCE_BUILT_LINUX_AGENTS` beside
  `agents/linux/*`, "created … by an upstream job or while creating the source
  package", but unlike the **aarch64** pair — `…-1.aarch64.rpm` and
  `…_arm64.deb`, new in 2.5 with werk #19275 — they are *not* in the tarball.
  `agents/BUILD` globs all four with `allow_empty = True`, so their absence is
  silent: the package builds, installs, and simply cannot deploy a DEB or RPM
  agent to anything but arm64. Building them here is not an alternative —
  `agents/Makefile` names them `_all`/`noarch` unconditionally, so on this host
  it would produce an "architecture-independent" package wrapped around an
  aarch64 `cmk-agent-ctl`. `ci/verify-deb.sh` now checks both the presence of
  all four and the architecture of the controller inside the `_all.deb`.
