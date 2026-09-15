#!/usr/bin/env python3
"""Delete the bucket objects listed in new_data/cdn_orphans.txt.

publish_cdn.py writes that list: objects under gerrymander/ that no manifest
refers to any more (databases superseded by a time-stamped name).  Before
deleting, every listed key is checked again against the current manifests, and
any key still referenced is refused.  Run it only after new_elections.json has
been refreshed on the CDN, or clients still holding the old manifest will fail
to download.

    .venv/bin/python delete_cdn_orphans.py          # shows what would be deleted
    .venv/bin/python delete_cdn_orphans.py --yes    # deletes
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import urllib.request
from email.utils import formatdate
from xml.sax.saxutils import escape

from publish_cdn import NEW_DATA, credentials, list_objects, wanted_objects


def delete_batch(creds: dict[str, str], keys: list[str]) -> str:
    body = ("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Delete><Quiet>true</Quiet>"
            + "".join(f"<Object><Key>{escape(k)}</Key></Object>" for k in keys)
            + "</Delete>").encode()
    content_md5 = base64.b64encode(hashlib.md5(body).digest()).decode()
    content_type = "application/xml"
    date = formatdate(usegmt=True)
    to_sign = f"POST\n{content_md5}\n{content_type}\n{date}\n/{creds['OSS_BUCKET']}/?delete"
    signature = base64.b64encode(hmac.new(creds["OSS_ACCESS_KEY_SECRET"].encode(),
                                          to_sign.encode(), hashlib.sha1).digest()).decode()
    request = urllib.request.Request(
        f"https://{creds['OSS_BUCKET']}.{creds['OSS_ENDPOINT']}/?delete", data=body, method="POST",
        headers={"Date": date, "Content-MD5": content_md5, "Content-Type": content_type,
                 "Authorization": f"OSS {creds['OSS_ACCESS_KEY_ID']}:{signature}"})
    return urllib.request.urlopen(request, timeout=120).read().decode()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--yes", action="store_true", help="actually delete")
    args = parser.parse_args()

    keys = [k.strip() for k in (NEW_DATA / "cdn_orphans.txt").read_text().splitlines() if k.strip()]
    dbs, manifests = wanted_objects()
    still_used = [k for k in keys if k in dbs or k in manifests or not k.startswith("gerrymander/")]
    if still_used:
        raise SystemExit(f"refusing: these keys are still referenced or outside gerrymander/: {still_used}")

    creds = credentials()
    remote = list_objects(creds)
    present = [k for k in keys if k in remote]
    size = sum(remote[k][0] for k in present)
    print(f"{len(present)} of {len(keys)} listed objects exist ({size / 1048576:.0f} MB)")
    if not args.yes:
        print("dry run — pass --yes to delete them")
        return

    for start in range(0, len(present), 1000):
        result = delete_batch(creds, present[start:start + 1000])
        if "<Error>" in result:
            raise SystemExit(result)
    left = [k for k in present if k in list_objects(creds)]
    print(f"deleted {len(present) - len(left)} objects" + (f"; still present: {left}" if left else ""))


if __name__ == "__main__":
    main()
