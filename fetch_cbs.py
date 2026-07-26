#!/usr/bin/env python3
"""
Download the CBS Wijk- en Buurtkaart for one or more years.

    python code/nl_boundaries/fetch_cbs.py --years 2015 2020 2025
    python code/nl_boundaries/fetch_cbs.py --years 2015 2020 2025 --check

Years already on disk are skipped, so re-running is cheap.

The one wrinkle worth knowing: CBS re-uploads a year whenever they correct it and bump a
version suffix, and the suffix isn't consistent — 2025 is v1, 2024 is v2, everything older
is v3. Hardcoding those would break the next time they re-publish, so I just try v5 down to
v1 and take the first one that exists.

Licence: publishing this geometry is fine as long as CBS and Kadaster are credited. Keep that
attribution on anything you publish.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import urllib.request
import urllib.error
import zipfile
from pathlib import Path

BASE = "https://geodata.cbs.nl/files/Wijkenbuurtkaart"

# Try newest first. Nothing's gone past v3 so far; v5 is just headroom.
CANDIDATE_REVISIONS = [5, 4, 3, 2, 1]

# Years I've confirmed on geodata.cbs.nl (July 2026). Older ones live on a different CBS path;
# the probe will just report those as missing.
KNOWN_RANGE = range(2012, 2026)

OUT_DIR = Path(__file__).resolve().parents[1] / "data" / "raw" / "cbs"

# Cloud-synced folders. Dumping a few hundred MB into one is slow and eats quota, but the real
# reason for this list: on macOS the OneDrive/iCloud file provider can grab a file and rename it
# out from under you between close() and rename(), so os.rename() blows up on a download that
# actually finished fine. finalize() handles that case.
CLOUD_MARKERS = ("CloudStorage", "OneDrive", "Dropbox", "Google Drive", "iCloud", "pCloud")


def in_cloud_folder(p: Path) -> str | None:
    s = str(p)
    return next((m for m in CLOUD_MARKERS if m in s), None)


def url_for(year: int, rev: int) -> str:
    return f"{BASE}/WijkBuurtkaart_{year}_v{rev}.zip"


def probe(year: int, timeout: int = 20) -> tuple[str, int, int] | None:
    """Highest available revision for a year as (url, revision, size), or None if there isn't one."""
    for rev in CANDIDATE_REVISIONS:
        url = url_for(year, rev)
        req = urllib.request.Request(url, method="HEAD")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status == 200:
                    size = int(resp.headers.get("Content-Length", 0))
                    return url, rev, size
        except urllib.error.HTTPError:
            continue          # this revision does not exist, try the next one down
        except urllib.error.URLError as exc:
            print(f"  network error probing {year} v{rev}: {exc.reason}", file=sys.stderr)
            return None
    return None


def human(n: int) -> str:
    return f"{n / 1_048_576:.0f} MB" if n else "unknown size"


def finalize(tmp: Path, dest: Path, expected: int) -> None:
    """Move the finished .part file into place.

    If the data sits in a cloud-synced folder, the sync agent sometimes renames the .part file
    for us before we get to it. That's not a failure — if the destination is there at the right
    size, the download worked, so say so instead of crashing on the leftover bookkeeping.
    """
    if tmp.exists():
        try:
            tmp.replace(dest)                      # atomic when the filesystem allows it
        except OSError:
            shutil.move(str(tmp), str(dest))       # fallback: cross-device, or the sync agent got there first
        return

    if dest.exists() and (not expected or abs(dest.stat().st_size - expected) < 4096):
        print(f"  note: the temp file was renamed by the filesystem "
              f"(cloud sync); {dest.name} is present and complete")
        return

    raise RuntimeError(
        f"{tmp.name} vanished before it could be renamed and {dest.name} is not present. "
        f"Re-run, ideally with --out pointing outside a cloud-synced folder."
    )


def verify_zip(path: Path) -> bool:
    try:
        with zipfile.ZipFile(path) as zf:
            return zf.testzip() is None
    except zipfile.BadZipFile:
        return False


def download(url: str, dest: Path) -> None:
    """Stream to a .part file, then move it into place — so a killed run never leaves a
    half file that looks finished to the next one."""
    tmp = dest.with_name(dest.name + ".part")
    expected = 0
    with urllib.request.urlopen(url, timeout=120) as resp, open(tmp, "wb") as fh:
        expected = int(resp.headers.get("Content-Length", 0))
        done = 0
        while chunk := resp.read(1 << 20):
            fh.write(chunk)
            done += len(chunk)
            if expected:
                pct = 100 * done / expected
                print(f"\r  {dest.name}  {pct:5.1f}%  ({human(done)})", end="", flush=True)
        print()
    finalize(tmp, dest, expected)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--years", type=int, nargs="+", required=True,
                    help="Vintages to fetch, e.g. --years 2015 2020 2025")
    ap.add_argument("--check", action="store_true",
                    help="Probe availability and sizes only; download nothing.")
    ap.add_argument("--out", type=Path,
                    default=Path(os.environ.get("NL_DATA_DIR", OUT_DIR)),
                    help="Destination directory. Defaults to $NL_DATA_DIR, else code/data/raw/cbs. "
                         "Prefer somewhere outside a cloud-synced folder.")
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)

    marker = in_cloud_folder(args.out)
    if marker:
        print(f"NOTE: {args.out} sits inside a {marker} folder.\n"
              f"      335 MB will be uploaded to the cloud, and the sync agent can interfere\n"
              f"      with file renames mid-download. To keep the data local instead:\n"
              f"        export NL_DATA_DIR=~/geodata/cbs\n")

    total_bytes = 0
    plan: list[tuple[int, str, Path, int]] = []

    for year in sorted(set(args.years)):
        if year not in KNOWN_RANGE:
            print(f"{year}: outside the confirmed range {KNOWN_RANGE.start}-{KNOWN_RANGE.stop - 1}; "
                  f"probing anyway")
        found = probe(year)
        if not found:
            print(f"{year}: NOT FOUND at any revision")
            continue
        url, rev, size = found
        dest = args.out / f"WijkBuurtkaart_{year}_v{rev}.zip"

        if dest.exists():
            # "exists" isn't "usable" — a run killed mid-stream leaves a plausible-sized file
            # that won't open. Catch it here instead of letting ogr2ogr choke on it much later.
            if verify_zip(dest):
                print(f"{year}: v{rev}  {human(size):>8}  already downloaded, verified")
                continue
            print(f"{year}: v{rev}  {human(size):>8}  present but CORRUPT, re-downloading")
            dest.unlink()
        else:
            print(f"{year}: v{rev}  {human(size):>8}  to download")

        plan.append((year, url, dest, size))
        total_bytes += size

    if args.check:
        print(f"\nWould download {len(plan)} file(s), {human(total_bytes)} total.")
        return 0

    if not plan:
        print("\nNothing to do; all requested vintages are present.")
        return 0

    print(f"\nDownloading {len(plan)} file(s), {human(total_bytes)} total.\n")
    failed = []
    for year, url, dest, _ in plan:
        download(url, dest)
        if not verify_zip(dest):
            failed.append(dest.name)
            print(f"  WARNING: {dest.name} did not pass a zip integrity check")

    if failed:
        print(f"\n{len(failed)} file(s) failed verification: {', '.join(failed)}")
        print("Re-run to fetch them again.")
        return 1

    print("\nDone. Next:")
    print("  python code/nl_boundaries/load_to_postgis.py --years " +
          " ".join(str(y) for y in sorted(set(args.years))))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
