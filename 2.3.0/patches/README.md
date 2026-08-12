# Checkmk 2.3.0 aarch64 patch set

Applied in the order given by `series`. `lib/build-common.sh` dry-runs each
patch immediately before applying it and aborts on the first failure, so a
patch that stops applying against a newer patch level is loud, not silent.

Numbering carries intent:

| Range       | Meaning                                    | Upstreamable?        |
| ----------- | ------------------------------------------ | -------------------- |
| `0001-0099` | aarch64 architecture fixes                 | yes — offer to Checkmk |
| `0100-0199` | reachability of downloads (internal mirrors) | no                 |
| `0200-0299` | dependency pruning / missing aarch64 wheels | no                  |
| `0300-0399` | build-host conveniences                     | no                  |

## The patches

| Patch | What / why | Droppable when |
| ----- | ---------- | -------------- |
| `0001-python-sysconfigdata-aarch64` | CPython names its sysconfig module after the host triplet. `Python.make` and `BUILD.Python.bazel` both hardcode `_sysconfigdata__linux_x86_64-linux-gnu.py`, so the build cannot find it on aarch64. | upstream derives the name from the triplet |
| `0002-bazel-pathhash-aarch64` | `run-bazel-build.sh` fingerprints the toolchain via four x86-only paths. On aarch64 all four hash to `--`, and `create_build_environment_variables.py` then raises *"All provided 'pathhash' items result in emtpy hashes"*. Repointed at the aarch64 libc, the gcc dir and `/usr/bin/gcc`. | upstream picks paths per architecture |
| `0003-protobuf-static-link-latomic` | aarch64 needs `-latomic` explicitly to link `protoc` statically; x86-64 gets the intrinsics inline. | upstream adds it, or protobuf is no longer built this way |
| `0004-net-snmp-perl-archlib-aarch64` | `INSTALLARCHLIB` hardcodes `x86_64-linux-gnu-thread-multi`; perl's real `archname` here is `aarch64-linux-gnu-thread-multi`. | upstream uses `$Config{archname}` |
| `0005-snap7-aarch64-build-profile` | snap7 ships one makefile per architecture and the BUILD file asks for `x86_64_linux.mk`. `aarch64_linux.mk` is generated from upstream's `arm_v6_linux.mk` by the `seed-distdir` build stage. | snap7 ships an aarch64 profile upstream |
| `0006-omd-drop-navicli-x86-only` | `navicli` installs prebuilt x86-only EMC binaries. There is no aarch64 build, so the package is dropped entirely. | EMC ships aarch64 binaries (unlikely) |
| `0007-perl-modules-tar-no-same-owner` | The build runs as root in a container, so `tar` tries to restore the uid/gid recorded inside CPAN tarballs and fails. | build stops running as root |
| `0100-snap7-repackaged-tarball-sha` | snap7 1.4.2 is published only as `.7z`, so Checkmk serves a repackaged tarball from `artifacts.lan.tribe29.com`, which is unreachable externally (confirmed: connection times out). `seed-distdir` reproduces that repackaging locally — following the recipe preserved in snap7.make's commented-out `snap7-repackage` target — and feeds it to Bazel via `--distdir`. Only the checksum differs. | snap7 publishes a `.tar.gz`, or Checkmk mirrors it publicly |
| `0101-python3-modules-public-pypi` | `omd/packages/python3-modules/BUILD` pipes every `pip install` through `INTERNAL_PYPI_MIRROR` (`devpi.lan.tribe29.com`). `USE_EXTERNAL_PIPENV_MIRROR=true` only redirects the *pipenv* path in `defines.make`, not this one. | upstream honours the env var here too |

## Not needed for 2.3 (contrary to the older 2.2 recipe)

Verified against 2.3.0p49 — the originals are parked in `unused/`:

- **`fake-windows-artifacts` path fix** — `scripts/fake-artifacts` (renamed in
  2.3) is not invoked anywhere in the `make deb` path.
- **heirloom-mailx source URL** — `heirloom-mailx_http.bzl` already lists a
  working `ftp.nl.debian.org` URL ahead of the internal mirror.
- **`npm ci` -> `npm install`** — the root Makefile already probes the internal
  registry and falls back to the public one when it is unreachable.
- **`--break-system-packages`** — handled in the build image by removing
  `EXTERNALLY-MANAGED` and setting `PIP_BREAK_SYSTEM_PACKAGES=1`.
- **`empty_pathhash` RuntimeError removal** — unnecessary once `0002` makes the
  probed paths resolve; all four now produce real hashes.
- **`pymssql` bump** — 2.3 already pins 2.3.9.
- **webpack `NODE_OPTIONS` memory cap** — not needed at 18 GB; add back if
  webpack OOMs on a smaller machine.

## Things the tarball omits (restored by build.sh, not patched)

The release tarball strips dotfiles, including **`.bazelversion`**. Without it
bazelisk installs the newest Bazel (9.x), which enables bzlmod, ignores
`WORKSPACE` entirely and fails with *"No repository visible as '@openssl'"*.
`restore_tarball_omissions()` writes it back.
