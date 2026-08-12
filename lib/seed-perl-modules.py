#!/usr/bin/env python3
"""Pre-seed Bazel's --distdir with the perl module tarballs Checkmk pins.

Why this is needed
------------------
omd/packages/perl-modules/perl-modules_http.bzl pins ~250 CPAN tarballs at
exact versions, and gives each two URLs: Checkmk's internal mirror (unreachable
from outside) and one public URL. Many of those public URLs point at
    https://www.cpan.org/modules/by-module/<Ns>/<Dist>-<ver>.tar.gz
but that path only ever serves the *current* version of a distribution, so every
pinned older version 404s. The build then dies on the first one it needs, e.g.
Params-Validate-1.18.

Bazel consults --distdir by basename and verifies the sha256 before touching the
network, so dropping the correct tarballs there fixes all of them at once
without patching 250 URLs.

Resolution order per file: the URL the .bzl lists, then the real location from
MetaCPAN's release index, then BackPAN for releases deleted from CPAN. Every
download is checked against the sha256 the .bzl pins, so a wrong or truncated
file can never be seeded.
"""

import concurrent.futures
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request

TIMEOUT = 60
UA = {"User-Agent": "check-mk-arm-build/1.0"}


def parse_bzl(path):
    """Extract (filename, sha256, url) triples from perl-modules_http.bzl."""
    text = open(path, encoding="utf-8").read()
    entries = {}
    pattern = re.compile(
        r'"(?P<name>[^"]+\.(?:tar\.gz|tgz))"\s*:\s*\{\s*'
        r'"sha256"\s*:\s*"(?P<sha>[0-9a-f]{64})"\s*,\s*'
        r'"url"\s*:\s*"(?P<url>[^"]+)"',
        re.MULTILINE,
    )
    for m in pattern.finditer(text):
        entries[m.group("name")] = (m.group("sha"), m.group("url"))
    return entries


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read()


def split_dist_version(filename):
    """Params-Validate-1.18.tar.gz -> ("Params-Validate", "1.18")"""
    base = re.sub(r"\.(tar\.gz|tgz)$", "", filename)
    if "-" not in base:
        return base, ""
    dist, _, version = base.rpartition("-")
    return dist, version


def metacpan_urls(filename):
    """Real download URLs for a pinned release, newest source first."""
    dist, version = split_dist_version(filename)
    if not version:
        return []
    query = {
        "query": {
            "bool": {
                "must": [
                    {"term": {"distribution": dist}},
                    {"term": {"version": version}},
                ]
            }
        },
        "fields": ["download_url"],
        "size": 5,
    }
    try:
        req = urllib.request.Request(
            "https://fastapi.metacpan.org/v1/release/_search",
            data=json.dumps(query).encode(),
            headers={**UA, "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = json.load(resp)
    except Exception:
        return []

    urls = []
    for hit in data.get("hits", {}).get("hits", []):
        fields = hit.get("fields") or {}
        found = fields.get("download_url")
        if isinstance(found, list):
            found = found[0] if found else None
        if found:
            urls.append(found)
            # Releases deleted from CPAN survive on BackPAN at the same path.
            urls.append(
                found.replace("https://cpan.metacpan.org/", "https://backpan.perl.org/")
            )
    return urls


def seed_one(distdir, filename, want_sha, listed_url):
    dest = os.path.join(distdir, filename)

    if os.path.exists(dest):
        if sha256_of(dest) == want_sha:
            return filename, "cached", None
        os.unlink(dest)

    errors = []
    for url in [listed_url] + metacpan_urls(filename):
        try:
            blob = fetch(url)
        except Exception as exc:  # 404, DNS, refused, timeout ...
            errors.append(f"{url}: {exc}")
            continue

        got = hashlib.sha256(blob).hexdigest()
        if got != want_sha:
            errors.append(f"{url}: sha256 {got[:12]} != pinned {want_sha[:12]}")
            continue

        tmp = dest + ".part"
        with open(tmp, "wb") as fh:
            fh.write(blob)
        os.replace(tmp, dest)
        return filename, "fetched", url

    return filename, "FAILED", "; ".join(errors)


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <perl-modules_http.bzl> <distdir>")
    bzl, distdir = sys.argv[1], sys.argv[2]
    os.makedirs(distdir, exist_ok=True)

    entries = parse_bzl(bzl)
    if not entries:
        sys.exit(f"parsed no module entries from {bzl} — has its format changed?")
    print(f"  {len(entries)} pinned perl module tarballs")

    cached = fetched = 0
    failures = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        futures = [
            pool.submit(seed_one, distdir, name, sha, url)
            for name, (sha, url) in sorted(entries.items())
        ]
        for future in concurrent.futures.as_completed(futures):
            name, status, detail = future.result()
            if status == "cached":
                cached += 1
            elif status == "fetched":
                fetched += 1
            else:
                failures.append((name, detail))

    print(f"  cached={cached} fetched={fetched} failed={len(failures)}")
    for name, detail in failures:
        print(f"  FAILED {name}\n      {detail}", file=sys.stderr)
    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
