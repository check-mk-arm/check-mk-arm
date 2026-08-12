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
| `2.2.0/`  | 2.2.x   | `debian:bookworm`     | inherited from upstream, kept for reference (untouched) |
| `2.3.0/`  | 2.3.0p49| `debian:bookworm-slim`| rewritten                               |

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

## How it works

1. **fetch-src** — download the official `check-mk-raw-<ver>.cre.tar.gz`.
2. **fetch-donor-deb** — download the amd64 *Cloud* edition package. The Windows
   agent binaries cannot be built on Linux/ARM, so they are lifted from there;
   this is what the upstream ARM recipe has always done.
3. **seed-distdir** — repackage snap7 from its SourceForge `.7z` (upstream ships
   no `.tar.gz` since 1.4.2 and Checkmk's own mirror is unreachable from
   outside), adding an aarch64 build profile, and hand it to Bazel via
   `--distdir`.
4. **patch** — apply `2.3.0/patches/` in `series` order. Each patch is dry-run
   immediately before being applied and the first failure aborts the build.
5. **build-deb** — `debuild` in `omd/`, which compiles everything and produces
   the package.

See [`2.3.0/patches/README.md`](2.3.0/patches/README.md) for what each patch does
and when it can be dropped. Patches numbered `0001-0099` are genuine
architecture fixes and are suitable to offer upstream to Checkmk.

## Consuming the result

[`checkmk_build`](https://gitlab.com/joeri2821-gh14/joeri2821-docker-images/checkmk)
wraps the package into a runnable Docker image. The base image must match the
distro the package was built for (2.3 → bookworm, 2.4 → trixie), because the
dependencies are distro-specific.

## Caveats

- Community-built and **not supported or endorsed by Checkmk**. Do not report
  problems with these packages to Checkmk.
- The bundled **Windows agent binaries are x86-64** by construction. They are
  shipped for deployment to Windows hosts and never run on the server.
- **`navicli`** (EMC storage) is dropped — prebuilt x86-only binaries with no
  aarch64 equivalent.
