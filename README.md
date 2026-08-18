# check-mk-arm

Builds **Checkmk Community** (formerly Raw) `.deb` packages for **arm64 /
aarch64**.

Checkmk publishes no ARM server packages for any version — every
`check-mk-{raw,community}-*.deb` on `download.checkmk.com` is `amd64`, and every
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
| `2.5.0/`  | 2.5.0p11| `debian:trixie-slim`  | re-derived — 2.5 builds the package with Bazel |

The distro is not a preference. Up to 2.4 `omd/omd.make` derived `DISTRO_CODE`
from `/etc/debian_version`, so the base image alone decided the
`_0.<code>_arm64.deb` suffix — and `omd/distros/DEBIAN_13.mk`, the file that sets
`DISTRO_CODE = trixie`, exists only from the 2.4.0 branch on, so 2.3 physically
cannot produce a trixie package. 2.5 takes it from the `--cmk_distro` Bazel flag
instead (`bazelrc.local` sets `debian-13`), but the constraint is the same one in
a different place: the flag selects `omd/distros/DEBIAN_13.mk`, whose dependency
list has to match the distro the build image actually is. Either way the runtime
image's base distro has to match the package's (bookworm pulls `libperl5.36`,
trixie `libperl5.40`).

**Checkmk renamed its editions in 2.5**: Raw became Community, Enterprise became
Pro, Cloud became Ultimate. That changes the source tarball's name (and drops the
`.cre` infix), the package name, and the `<version>.<edition>` directory the
package installs into — so from 2.5 on the artifacts are
`check-mk-community-2.5.0p11_0.trixie_arm64.deb` and
`/opt/omd/versions/2.5.0p11.community`.

## AI usage

Creating the packages and builds was assisted by AI. Code / changes were manually reviewed, and the output was tested by a human before creating releases.


## Consuming the result

[`docker/`](docker/) wraps the package into a runnable image, published to GHCR:

```
docker pull ghcr.io/<owner>/checkmk-community-arm:2.5.0p11
```

[`.github/workflows/docker-image.yml`](.github/workflows/docker-image.yml) is a
`workflow_call` workflow that both build workflows invoke, so 2.2 and 2.3+ share
one image recipe. It globs for both package names, since 2.5 renamed the Raw
edition to Community (`check-mk-community-*_arm64.deb`). It runs only on a release run, because it fetches the package
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


## Building

Requires an **arm64 host with Docker**. Ideally runs in github CI on ARM runners.
Nothing is installed on the host; the whole toolchain lives in the build image. Budget several hours for a cold build and tens of GB of disk.

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

The finished package lands in `/data/checkmk/work/<version>/debs/` together with a `.sha256`.

### How it works

1. **fetch-src** — download the official source tarball
   (`check-mk-raw-<ver>.cre.tar.gz` up to 2.4,
   `check-mk-community-<ver>.tar.gz` from 2.5).
2. **fetch-donor-deb** — download the amd64 *Cloud* (2.5: *Ultimate*) edition
   package. The Windows agent binaries cannot be built on Linux/ARM, so they are
   lifted from there; this is what the upstream ARM recipe has always done. From
   2.5 the Linux agent-controller binaries come from there too — they are static
   musl payloads for monitored hosts and upstream builds them with a musl
   toolchain that only runs on an x86-64 exec platform.
3. **seed-distdir** / **seed-perl-modules** — put the archives whose upstream
   URLs are dead or unreachable into Bazel's `--distdir`, where they are matched
   by name and sha256 before any download is attempted. Up to 2.4 this also
   repackaged snap7 from its SourceForge `.7z`; 2.5 has a repository rule that
   does that itself.
4. **patch** — apply `<minor>/patches/` in `series` order. Each patch is dry-run
   immediately before being applied and the first failure aborts the build.
5. **venv** and **frontend** (2.4 only) — have Bazel create the build venv with
   `uv`, and build `packages/cmk-frontend{,-vue}/dist` with npm. Both are inputs
   `make deb` needs and neither is in the release tarball any more. 2.5 builds
   both inside Bazel, so the stages are gone.
6. **repin-crates** (2.5 only) — regenerate `site.Cargo.lock.bazel` after patch
   `0013` adds aarch64 to `@site_crates`' platform list.
7. **build-deb** — up to 2.4, `debuild` in `omd/`. 2.5 moved the whole packaging
   into Bazel, so it is `bazel build //omd:deb_community`.
8. **collect** — copy the package into `debs/` beside a `.sha256`.

See [`2.3.0/patches/README.md`](2.3.0/patches/README.md),
[`2.4.0/patches/README.md`](2.4.0/patches/README.md) and
[`2.5.0/patches/README.md`](2.5.0/patches/README.md) for what each patch does and
when it can be dropped. Patches numbered `0001-0099` are genuine architecture
fixes and are suitable to offer upstream to Checkmk.


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

## Continuous integration

[`.github/workflows/build-deb.yml`](.github/workflows/build-deb.yml) runs the
same `./run.sh` on GitHub's free `ubuntu-24.04-arm` runner (4 vCPU, 16 GB,
~46 GB free disk, 6 h job cap). 2.3 needs 4 cores, 5.3 GiB and ~25 GB, which fits
with roughly 2× margin and no caching. 2.4 is tighter: ~27 GB (a 17 GB Bazel
cache, a 4.9 GB source tree and a 5 GB builder image) against the ~46 GB the
`Reclaim runner disk` step leaves. Every CI run is cold, so keep an eye on the
350-minute step timeout when a patch level changes enough to rebuild `erlang` and
`python3-modules` from scratch.

| Trigger | Result |
| --- | --- |
| push to `ci/**` | package kept as a workflow artifact |
| `workflow_dispatch` | artifact, for any version you name, and optionally the release |

The build logs are uploaded as an artifact too, on success or failure.

**Releases are made by the build.** Run the workflow by
hand, give it a version, and set `release` to `draft` or `publish`: a build that
passes `ci/verify-deb.sh` then creates a release tagged with the Checkmk version
(`2.3.0p49`) pointing at the commit that built it, carrying the `.deb` and its
`.sha256`. Choose `draft` to look it over before it goes public.


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
  take their place on the list. 2.5 has nine, having added `mk-oracle` and
  robotmk's `micromamba`, and putting `cmk-agent-ctl` and `mk-sql` back because
  they are lifted from the donor rather than built. A minor without a curated
  list is held only to the `agents/`-path rule and has what it found recorded in
  the log;
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
