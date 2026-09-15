#!/usr/bin/env python3
"""Publish new_data/ to the CDN bucket under the time-stamped names.

  1. stamps new_elections.json and the year manifests (manifest_version.py);
  2. lists oss://<bucket>/gerrymander/ and uploads every database whose
     published name is not there yet, then each manifest.json whose content
     differs, then new_elections.json last;
  3. checks every uploaded object's ETag against the local file's MD5;
  4. writes new_data/cdn_orphans.txt — objects no manifest refers to any more,
     for deleting in the OSS console — and new_data/cdn_refresh_urls.txt, the
     overwritten fixed URLs that need a CDN refresh.

Databases are never overwritten: a changed one has a new name.  Uploads go
through the series tool todo/tool/oss_upload.sh; listing signs its own
requests with the same credentials (~/.alibabacloud/oss.env, never printed).

    .venv/bin/python publish_cdn.py [--dry-run]
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import shutil
import subprocess
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from email.utils import formatdate
from pathlib import Path

import manifest_version

ROOT = Path(__file__).resolve().parent
NEW_DATA = ROOT / "new_data"
STAGE = NEW_DATA / ".upload_stage"
PREFIX = "gerrymander"
UPLOAD_TOOL = ROOT.parents[1] / "todo" / "tool" / "oss_upload.sh"
CDN = "https://files.xp-oncology.cn"


def credentials() -> dict[str, str]:
    env = {}
    for line in (Path.home() / ".alibabacloud" / "oss.env").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip('"').strip("'")
    return {k: os.environ.get(k, env.get(k, "")) for k in
            ("OSS_ACCESS_KEY_ID", "OSS_ACCESS_KEY_SECRET", "OSS_BUCKET", "OSS_ENDPOINT")}


def list_objects(creds: dict[str, str]) -> dict[str, tuple[int, str]]:
    """{key: (size, etag)} under PREFIX/."""
    objects, marker = {}, ""
    while True:
        date = formatdate(usegmt=True)
        to_sign = f"GET\n\n\n{date}\n/{creds['OSS_BUCKET']}/"
        signature = base64.b64encode(hmac.new(creds["OSS_ACCESS_KEY_SECRET"].encode(),
                                              to_sign.encode(), hashlib.sha1).digest()).decode()
        query = urllib.parse.urlencode({"prefix": f"{PREFIX}/", "max-keys": 1000, "marker": marker})
        request = urllib.request.Request(
            f"https://{creds['OSS_BUCKET']}.{creds['OSS_ENDPOINT']}/?{query}",
            headers={"Date": date, "Authorization": f"OSS {creds['OSS_ACCESS_KEY_ID']}:{signature}"})
        root = ET.fromstring(urllib.request.urlopen(request, timeout=120).read())
        ns = root.tag.split("}")[0] + "}" if root.tag.startswith("{") else ""
        for c in root.findall(f"{ns}Contents"):
            key = c.findtext(f"{ns}Key")
            objects[key] = (int(c.findtext(f"{ns}Size")), c.findtext(f"{ns}ETag").strip('"').upper())
            marker = key
        if root.findtext(f"{ns}IsTruncated") != "true":
            return objects
        marker = root.findtext(f"{ns}NextMarker") or marker


def md5(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 22), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def wanted_objects() -> tuple[dict[str, Path], dict[str, Path]]:
    """({key: local db file}, {key: local manifest file}) the manifests call for."""
    dbs, manifests = {}, {}
    for manifest_path in sorted(NEW_DATA.glob("20*/manifest.json")):
        year = manifest_path.parent.name
        manifest = json.loads(manifest_path.read_text())
        for entry in manifest.get("states", []) + ([manifest["national"]] if manifest.get("national") else []):
            name = entry["url"].rsplit("/", 1)[-1]
            dbs[f"{PREFIX}/{year}/{name}"] = manifest_path.parent / entry["db"]
        manifests[f"{PREFIX}/{year}/manifest.json"] = manifest_path
    manifests[f"{PREFIX}/new_elections.json"] = NEW_DATA / "new_elections.json"
    return dbs, manifests


def upload(source: Path, remote_prefix: str, dry_run: bool) -> None:
    command = [str(UPLOAD_TOOL), str(source), remote_prefix, "--force"]
    if dry_run:
        print("  would run:", " ".join(command))
        return
    subprocess.run(command, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="list what would be uploaded, upload nothing")
    args = parser.parse_args()

    manifest_version.stamp()
    creds = credentials()
    remote = list_objects(creds)
    dbs, manifests = wanted_objects()

    missing = {key: path for key, path in dbs.items() if key not in remote}
    stale_manifests = {key: path for key, path in manifests.items()
                       if key not in remote or remote[key][1] != md5(path)}
    size = sum(p.stat().st_size for p in missing.values())
    print(f"{len(dbs)} databases published, {len(missing)} to upload ({size / 1048576:.0f} MB); "
          f"{len(stale_manifests)} manifests to upload", flush=True)

    shutil.rmtree(STAGE, ignore_errors=True)
    try:
        for key, path in missing.items():
            staged = STAGE / key.removeprefix(f"{PREFIX}/")
            staged.parent.mkdir(parents=True, exist_ok=True)
            os.link(path, staged)
        for year_dir in sorted(p for p in STAGE.glob("*") if p.is_dir()):
            upload(year_dir, f"{PREFIX}/{year_dir.name}", args.dry_run)
        # new_elections.json last: clients must never see a name before its file.
        for key in sorted(stale_manifests, key=lambda k: k.endswith("new_elections.json")):
            upload(stale_manifests[key], key.rsplit("/", 1)[0], args.dry_run)
    finally:
        shutil.rmtree(STAGE, ignore_errors=True)
    if args.dry_run:
        return

    remote = list_objects(creds)
    uploaded = {**missing, **stale_manifests}
    wrong = [key for key, path in uploaded.items() if remote.get(key, (0, ""))[1] != md5(path)]
    if wrong:
        raise SystemExit(f"uploaded objects that don't match the local files: {wrong}")

    wanted = set(dbs) | set(manifests)
    orphans = sorted(k for k in remote if k not in wanted and not k.endswith("/"))
    (NEW_DATA / "cdn_orphans.txt").write_text("".join(f"{k}\n" for k in orphans))
    refresh = [f"{CDN}/{k}" for k in stale_manifests if k in remote]
    (NEW_DATA / "cdn_refresh_urls.txt").write_text("".join(f"{u}\n" for u in refresh))
    print(f"verified {len(uploaded)} uploads; {len(orphans)} orphaned objects listed in "
          f"new_data/cdn_orphans.txt; refresh the {len(refresh)} URLs in new_data/cdn_refresh_urls.txt",
          flush=True)


if __name__ == "__main__":
    main()
