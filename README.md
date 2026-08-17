# check-mk-arm

Builds **Checkmk Raw** `.deb` packages for **arm64 / aarch64**.

Checkmk publishes no ARM server packages for any version — every
`check-mk-raw-*.deb` on `download.checkmk.com` is `amd64`, and every
`checkmk/check-mk-raw` Docker Hub tag is a single `linux/amd64` manifest.
Checkmk's position is that ARM server builds are not planned; only the *agent
controller* has gained aarch64 support (werk #19275). So the package has to be
built from source with a small set of architecture patches.

This is a fork of [FloTheSysadmin/check-mk-arm](https://github.com/FloTheSysadmin/check-mk-arm),
which descends from [chrisss404/check-mk-arm](https://github.com/chrisss404/check-mk-arm).
Both stopped at Checkmk 2.2.

| Directory | Checkmk | Build base            | Status                                  |
| --------- | ------- | --------------------- | --------------------------------------- |
| `2.2.0/`  | 2.2.0p47| `debian:bookworm`     | inherited from upstream, minimally fixed to build in CI |
| `2.3.0/`  | 2.3.0p49| `debian:bookworm-slim`| rewritten                               |
| `2.4.0/`  | 2.4.0p35| `debian:trixie-slim`  | ported from `2.3.0/`                    |

The distro is not a preference: `omd/omd.make` derives `DISTRO_CODE` from
`/etc/debian_version`, so the base image alone decides the `_0.<code>_arm64.deb`
suffix — and `omd/distros/DEBIAN_13.mk`, the file that sets `DISTRO_CODE = trixie`,
exists only from the 2.4.0 branch on. 2.3 physically cannot produce a trixie
package, and the runtime image's base distro has to match the package's
(bookworm pulls `libperl5.36`, trixie `libperl5.40`).

Checkmk 2.5+ is out of scope: its Bazel `pkg_deb` hardcodes
`architecture = "amd64"`, there is no `aarch64-linux-gnu` Bazel platform, and the
hermetic GCC/Rust toolchains are x86_64-only.

## Building

Requires an **arm64 host with Docker**. Nothing is installed on the host; the
whole toolchain lives in the build image. Budget several hours for a cold build
and tens of GB of disk.

```bash
./run.sh image      # build the builder image
./run.sh up         # start the long-lived build container
./run.sh build      # run every stage
./run.sh status     # where things are, and how long each stage took
```

`CMK_VERSION` selects what is built; it defaults to the newest supported line.
`run.sh` maps the minor to its distro and to the `<minor>/` recipe directory, so
building 2.3 instead is the same commands with one variable set:

```bash
CMK_VERSION=2.3.0p49 ./run.sh image
CMK_VERSION=2.3.0p49 ./run.sh up
CMK_VERSION=2.3.0p49 ./run.sh build
```

Run `./run.sh watch` in a second terminal: it samples disk and memory every two
minutes and stops the build before either filesystem fills.

The finished package lands in `/data/checkmk/work/<version>/debs/` together with
a `.sha256`.

### Iterating

The source tree, the Bazel cache and all downloads are bind-mounted from
`/data`, and `patches/` plus `build.sh` are mounted read-only straight from this
worktree — so editing a patch takes effect immediately, with no image rebuild
and no re-download.

```bash
./run.sh build --only patch,build-deb   # run selected stages
./run.sh build --force patch            # re-run a stage marked done
./run.sh build --list                   # show stage state
./run.sh reset-src                      # drop the source tree, keep tarballs + caches
./run.sh sh                             # shell inside the build container
```

Stages are marked in `state/`, so a build that dies after five hours resumes
where it stopped rather than starting over.

### Where the build lives

Everything is written under `/data/checkmk`. Set `CMK_DATA` to move it — that is
all CI needs to run the same build on a machine with no `/data`. `MEMORY` and
`CPUS` cap the container; the defaults suit a 23 GB host.

## Continuous integration

[`.github/workflows/build-deb.yml`](.github/workflows/build-deb.yml) runs the
same `./run.sh` on GitHub's free `ubuntu-24.04-arm` runner (4 vCPU, 16 GB,
~46 GB free disk, 6 h job cap). 2.3 needs 4 cores, 5.3 GiB and ~25 GB, which fits
with roughly 2× margin and no caching. 2.4 is the tighter one: ~27 GB (a 17 GB
Bazel cache, a 4.9 GB source tree and a 5 GB builder image) against the ~46 GB the
`Reclaim runner disk` step leaves, and every CI run is cold, so keep an eye on the
350-minute step timeout when a patch level changes enough to rebuild `erlang` and
`python3-modules` from scratch.

| Trigger | Result |
| --- | --- |
| push to `ci/**` | package kept as a workflow artifact |
| `workflow_dispatch` | artifact, for any version you name, and optionally the release |

The build logs are uploaded as an artifact too, on success or failure.

**Releases are made by the build, not the other way round.** Run the workflow by
hand, give it a version, and set `release` to `draft` or `publish`: a build that
passes `ci/verify-deb.sh` then creates a release tagged with the Checkmk version
(`2.3.0p49`) pointing at the commit that built it, carrying the `.deb` and its
`.sha256`. Choose `draft` to look it over before it goes public.

Doing it this way round matters because the build takes hours. Publishing the
release first would leave it empty for all of them, and empty for good if the
build failed. Re-running a version that already has a release replaces its
assets rather than failing at the end of a long build.

The `.sha256` is uploaded beside the `.deb` because `checkmk_build` fetches
`${DEB_URL}.sha256` and pipes it through `sha256sum -c -`.

[`ci/verify-deb.sh`](ci/verify-deb.sh) is what decides a build is acceptable, and
runs locally as well:

- the package matches its own `.sha256`;
- `Architecture: arm64` and the expected `Package`/`Version`;
- **ELF sweep** — every binary in the package is aarch64 except the known x86
  agent payloads, which must also each live under an `agents/` path. The list is
  per-minor, since the payload differs between releases: 2.3 ships prebuilt
  x86 `cmk-agent-ctl` and `mk-sql` in the source tarball, while 2.4 no longer
  does, so those two come out aarch64 there and the prebuilt robotmk binaries
  take their place on the list. A minor without a curated list is held only to
  the `agents/`-path rule and has what it found recorded in the log;
- **Windows agents** — `check_mk_agent.msi` is present and non-empty. The payload
  is lifted from the donor package, so a donor that failed to download would
  otherwise leave a package that is complete in every other respect, installs
  fine, and simply cannot deploy a Windows agent;
- it installs on a clean `debian:<code>-slim` matching the package and
  `omd version` runs — real dependency resolution, which is what has actually
  broken before.

### Checkmk 2.2

[`.github/workflows/build-deb-2.2.yml`](.github/workflows/build-deb-2.2.yml)
builds 2.2 on the same runner. It exists because upgrading to 2.3 expects the
system to be on the *last* patch level of the previous version, so an arm64
`2.2.0p47` (2.2's final release) is the missing step on the way to the 2.3
package. 2.2 is end of life, so this is archival.

| Trigger | Result |
| --- | --- |
| push to `ci-2.2/**` | package kept as a workflow artifact, never a release |
| `workflow_dispatch` | artifact, for any 2.2 patch level, and optionally the release |

The push prefix is deliberately not `ci/**`: that one belongs to the 2.3
workflow, and a shared prefix would start both multi-hour builds on every push.
It also gives you a way to exercise this workflow before it reaches the default
branch, since GitHub only offers the `workflow_dispatch` Run button for files
already on the default branch. A push cannot release — `release` is a dispatch
input, and it is empty on a push.

It does not go through `./run.sh`. The 2.2 image is self-contained — patches are
`COPY`ed in and `build_check_mk.sh` is the `ENTRYPOINT` — so the build is a
single `docker run` and the resumable state machine `run.sh` provides would buy
nothing on a runner, where every run is cold anyway. Only `debs/` is mounted in:
mounting the whole work directory over `/opt/build-mk`, as `run.sh` does for
2.3, would shadow the patches the image put there and the build would silently
apply none of them.

Building `2.2.0p47` at all took five changes to `2.2.0/`. The recipe was
written against an earlier patch level and inherited as-is, and every one of
these failed quietly rather than stopping the build:

- **The donor package.** The Windows agents are lifted out of an official amd64
  package, which was pinned to Ubuntu `mantic` — withdrawn along with 23.10, so
  it 404s for `2.2.0p47`. The script has no `set -e`, so the failed download
  fell through to a `rm -rf agents/windows` that was never followed by the
  replacement: a package with no Windows agents, exiting 0. The donor is now
  the `bookworm` build, and the swap is guarded.
- **The Pipfile lock.** Applying the patches rewrites the `Pipfile`, and the
  top-level `Makefile` has a `Pipfile.lock: Pipfile` rule that would then
  re-resolve every dependency against live PyPI. The recipe carried a vendored
  copy of the lock to win that race; the tarball ships one that matches this
  version, so only its timestamp is touched now.
- **Patches that no longer applied.** Five of the eighteen did not apply to
  p47: two superseded by narrower patches added later, two obsolete (the
  `pymssql` bump is in p47 already), one malformed. The loop echoed the
  failures and carried on, so nothing said so. They are gone, and a patch that
  does not apply is now fatal.
- **Bazel's version pin.** Upstream pins Bazel 5.4.1 in `.bazelversion`, the
  tarball ships no dotfiles, and the image installs 7.4.0 — so `xmlsec1`, whose
  rule declares both a `lib` directory and files inside it, fails analysis with
  an artifact prefix conflict that 5.4.1 tolerated. The redundant declaration is
  dropped rather than the toolchain downgraded; the other four Bazel packages
  build correctly under 7.4.0. See
  [`xmlsec1-drop-duplicate-lib-outputs.patch`](2.2.0/patches/xmlsec1-drop-duplicate-lib-outputs.patch).
- **The Python modules.** Every module is built from source, and pip resolves
  each sdist's build dependencies from PyPI at build time, so a recipe frozen
  in 2023 gets compiled by whatever setuptools and Cython exist today — and two
  of them moved out from under it. `setuptools` 82 removed `pkg_resources`,
  which `grpcio`'s `setup.py` imports; `pymssql` is pinned to a fork whose
  `.pyx` Cython rejects from 3.2 on. Both are fixed by constraining the build
  environments, which is what upstream does in 2.3 as well. See the header of
  [`python3-modules-constrain-build-envs.patch`](2.2.0/patches/python3-modules-constrain-build-envs.patch),
  which also records why the "speed up the build" patch that used to sit beside
  it was dropped rather than repaired.

The sha256 of both upstream inputs — the source tarball and the donor package —
is recorded in the job summary and in the release notes, alongside a link to the
run that produced the package. The build itself is not bit-reproducible (the
container runs `apt-get upgrade`, and the image installs unpinned Debian and
NodeSource packages); what is reproducible is the account of how it was made.

## How it works

1. **fetch-src** — download the official `check-mk-raw-<ver>.cre.tar.gz`.
2. **fetch-donor-deb** — download the amd64 *Cloud* edition package. The Windows
   agent binaries cannot be built on Linux/ARM, so they are lifted from there;
   this is what the upstream ARM recipe has always done.
3. **seed-distdir** — repackage snap7 from its SourceForge `.7z` (upstream ships
   no `.tar.gz` since 1.4.2 and Checkmk's own mirror is unreachable from
   outside), adding an aarch64 build profile, and hand it to Bazel via
   `--distdir`.
4. **patch** — apply `<minor>/patches/` in `series` order. Each patch is dry-run
   immediately before being applied and the first failure aborts the build.
5. **venv** and **frontend** (2.4 only) — have Bazel create the build venv with
   `uv`, and build `packages/cmk-frontend{,-vue}/dist` with npm. Both are inputs
   `make deb` needs and neither is in the release tarball any more.
6. **build-deb** — `debuild` in `omd/`, which compiles everything and produces
   the package.
7. **collect** — copy the package into `debs/` beside a `.sha256`.

See [`2.3.0/patches/README.md`](2.3.0/patches/README.md) and
[`2.4.0/patches/README.md`](2.4.0/patches/README.md) for what each patch does and
when it can be dropped. Patches numbered `0001-0099` are genuine architecture
fixes and are suitable to offer upstream to Checkmk.

### What is different about 2.4

The 2.4 recipe is the 2.3 one carried forward, but upstream moved enough between
the two that half the patch set had to be re-derived rather than re-cut. The
per-patch detail is in [`2.4.0/patches/README.md`](2.4.0/patches/README.md); the
structural differences are:

- **bzlmod.** 2.3 was `WORKSPACE`-only with Bazel 6.5. 2.4 has `MODULE.bazel` and
  a checked-in `MODULE.bazel.lock`, pins Bazel 7.5.0 in `.bazelversion` and then
  overrides it in `.bazeliskrc` with `aspect/2025.11.0`.
- **The tarball's missing dotfiles matter much more.** `make dist` packs the
  tree with `tar ... * .werks`, and a shell glob skips dotfiles — so every
  *root* dotfile is absent from the release tarball. For 2.3 that cost only
  `.bazelversion`. For 2.4 it also costs `.bazelrc`, without which the build
  loses `--@//:filesystem_layout=lsb` and every omd package fails its `select()`.
  All three are restored verbatim from `2.4.0/files/`, and our own Bazel settings
  go into `/etc/ci.bazelrc` — the last `try-import` in upstream's `.bazelrc`, and
  so the only rc file that can override it. See [`2.4.0/bazelrc.local`](2.4.0/bazelrc.local).
- **A C++ toolchain is registered now**, and it is x86-64-constrained. Without a
  patch, resolution falls back to Bazel's auto-detected toolchain, which builds
  but drops `-std=c++20`.
- **The hermetic Python is pinned by URL for x86-64 only**, so aarch64 has no
  interpreter at all until a matching `single_version_platform_override` is added.
- **Two things the tarball used to contain are now build steps**: the frontend
  (`packages/cmk-frontend{,-vue}/dist`, built with npm — node 22 and npm 10.9 are
  enforced by `engine-strict`) and the Rust agent binaries
  (`agents/linux/{cmk-agent-ctl,mk-sql}`, built for `$(uname -m)`-musl).
- **`pipenv` is gone.** The build venv is created by Bazel through `rules_uv`,
  and it is a genuine `make deb` dependency via `doc/plugin-api`, so it gets its
  own stage.
- **New packages**: `erlang` (built from an OTP git commit — the longest single
  package), `rabbitmq` (architecture-independent) and `jaeger` (a prebuilt
  binary, repointed at the arm64 release asset).
- **trixie's OpenSSL is newer than the one Checkmk bundles.** The Bazel actions
  that build `python3-modules` put Checkmk's OpenSSL 3.0.21 first on
  `LD_LIBRARY_PATH`, and trixie's `libcurl` needs `OPENSSL_3.2/3.3` symbols that
  3.0.21 does not export — so *any* system binary linking libcurl is unusable
  inside those actions. That is why the image installs Kitware's statically
  linked `cmake` over `/usr/bin/cmake`. Upstream builds on Ubuntu, whose system
  OpenSSL is 3.0.x, and never sees it.
- **Six of the patches are not architecture fixes at all** — they are the price
  of building from a release tarball rather than a git checkout, as root, with a
  resumable tree. Three of those fix install steps that work once and fail the
  second time; upstream never runs them twice because their builds always start
  clean.

## Consuming the result

[`docker/`](docker/) wraps the package into a runnable image, published to GHCR:

```
docker pull ghcr.io/<owner>/checkmk-community-arm:2.3.0p49
```

[`.github/workflows/docker-image.yml`](.github/workflows/docker-image.yml) is a
`workflow_call` workflow that both build workflows invoke, so 2.2 and 2.3+ share
one image recipe. It runs only on a release run, because it fetches the package
**from the GitHub release** rather than from the build job's artifact — that
exercises the same path a user takes, so a release whose assets are missing or
corrupt fails there rather than in somebody's `docker build`. The `.sha256` is
checked before the package is used. Draft releases work too; the download goes
through `gh`, whose token can see them.

`docker/version.sh` is the single source of truth for the version, the distro
and the tag set, all derived from the `.deb`'s own filename — which is why the
workflow downloads the asset by glob rather than by a name it builds itself.
Passing the release tag in as `GIT_TAG` makes it refuse to publish a package
whose version disagrees with the release being built.

Each build publishes two tags, the patch level and its series (`2.3.0p49` and
`2.3.0`). No `latest`: only the newest supported line could honestly claim it,
and this also builds end-of-life 2.2 and, on demand, older patch levels. Note
that the series tag has the same hazard in miniature — rebuilding an older patch
level moves `2.3.0` backwards.

The base distro must match the one the package was built for, since the
dependencies are distro-specific (bookworm pulls `libperl5.36`, trixie
`libperl5.40`); it is the `DISTRO_CODE` build arg, read out of the `.deb` name.

`docker/` comes from
[`checkmk_build`](https://github.com/check-mk-arm/checkmk_build) and is a
verbatim copy of it — that repository's GitLab ancestry is no longer tracked.
Changes belong here now.

## Caveats

- Community-built and **not supported or endorsed by Checkmk**. Do not report
  problems with these packages to Checkmk.
- The bundled **Windows agent binaries are x86-64** by construction. They are
  shipped for deployment to Windows hosts and never run on the server.
- **`navicli`** (EMC storage) is dropped — prebuilt x86-only binaries with no
  aarch64 equivalent.

## Measured build cost (4x Neoverse-N1, 23 GB RAM, no swap)

### Checkmk 2.3.0p49

| | Cold | Warm (fresh source tree, populated Bazel cache) |
| --- | --- | --- |
| Wall clock | ~2 h 45 m of compute across the debugging run | **19 minutes** |
| Peak container RSS | 5.3 GiB | 5.3 GiB |
| Bazel cache | 8.5 GB | 8.5 GB (reused) |
| Source tree after build | 6.0 GB | 6.0 GB |
| distdir | 12 MB | 12 MB |
| Builder image | 8.0 GB | — |
| Output package | 195 MB | 194 MB |

The single most expensive item is `grpcio`, which has no aarch64 wheel and takes
~35 minutes to compile — twice, because Bazel builds python3-modules in both the
target and exec configurations.

### Checkmk 2.4.0p35

| | Cold | Warm (fresh source tree, populated Bazel cache) |
| --- | --- | --- |
| Wall clock | ~4 h 50 m of compute across the debugging run | **20 minutes** |
| Bazel cache | 17 GB | 17 GB (reused) |
| Source tree after build | 4.9 GB | 4.9 GB |
| distdir | 69 MB | 69 MB |
| Builder image | 5.0 GB | — |
| Output package | 245 MB | 242 MB |

2.4 costs roughly twice what 2.3 did, and the Bazel cache doubles, because more
of the tree moved into Bazel: `erlang` is compiled from an OTP git commit (~11
minutes, largely single-threaded), the frontend is built with npm here rather
than shipped prebuilt, and `python3-modules` now also drags in a hermetic CPython
plus a Rust toolchain. The warm figure is what matters for CI and it is
unchanged.

Both warm figures are a **full `./run.sh build`** — source tree dropped, all
patches re-applied, package rebuilt and re-verified — not a resumed run.

Note the two packages differ in size: the build is **not** byte-reproducible
(timestamps and archive ordering), so do not diff checksums across builds.

**Implication for CI:** a warm build is ~20 minutes, so a runner with a
persistent volume for `/root/.cache` and `distdir/` is sufficient; no dedicated
long-lived machine is needed. Budget ~25 GB for the cache plus the source tree,
and note that changing anything Bazel sees as an action input — notably `PATH`,
which `scripts/run-bazel.sh` forwards via `--action_env` — invalidates the whole
cache and forces a cold build. `2.4.0/bazelrc.local` extends that `PATH` on
purpose (to expose Rust), so edit it only when you mean to pay for a cold build.
