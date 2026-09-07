#!/usr/bin/env python3
"""Sync reMarkable documents to/from ~/NotesDev/Remarkable over USB.

No SSH. Talks only to the tablet's USB web interface at 10.11.99.1, which
serves a live JSON listing, renders documents to PDF on demand, and accepts
uploads.

Ground truth is discovered every run, never stored:
  - what exists on the tablet -> walked live from /documents/
  - what exists locally       -> scanned from the destination tree
  - whether a file is current -> local mtime vs the tablet's ModifiedClient
  - whether an upload worked  -> re-read the listing and confirm it is there

There is deliberately no manifest/catalog file. Delete a local file and it
comes back; change a notebook on the tablet and it re-downloads.

  rmsync.py                 download tablet -> Mac (default)
  rmsync.py --upload        also push local-only files Mac -> tablet
  rmsync.py --dry-run       show what would happen, change nothing
"""

import argparse
import datetime as dt
import json
import mimetypes
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

BASE = "http://10.11.99.1"
DEST = os.path.expanduser("~/NotesDev/Remarkable")
MTIME_SLACK = 2.0        # seconds; filesystem timestamp rounding
UPLOADABLE = (".pdf", ".epub")

OFFLINE_HELP = """\
Tablet is not answering on %s.

Things that make this happen, in the order worth checking:
  1. USB file access got into a bad state. In Settings > General settings >
     Storage, toggle it OFF and back ON. (This is the one that has actually
     bitten us -- the port refuses connections until you re-toggle.)
  2. The tablet is not plugged in, or the cable is charge-only.
  3. The Mac has no 10.11.99.x address: check `ifconfig | grep 10.11.99`.

Nothing was changed.""" % BASE


def parse_time(s):
    """'2026-09-02T18:51:33.746Z' -> epoch seconds, or None."""
    if not s:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return dt.datetime.strptime(s, fmt).replace(
                tzinfo=dt.timezone.utc).timestamp()
        except ValueError:
            continue
    return None


def reachable():
    try:
        urllib.request.urlopen(BASE + "/documents/", timeout=10).read(1)
        return True
    except Exception:
        return False


def listing(parent_id):
    with urllib.request.urlopen(BASE + "/documents/" + parent_id, timeout=30) as r:
        return json.load(r)


def safe(name):
    """A VisibleName is free text; make it one safe path component."""
    name = (name or "untitled").replace("/", "-").replace("\0", "")
    return (name.strip().strip(".") or "untitled")[:180]


def key(name):
    """Match key shared by both sides.

    A notebook is 'Physics' on the tablet but 'Physics.pdf' on disk, so the
    extension has to come off or every notebook looks local-only and gets
    uploaded back as a duplicate.
    """
    n = name.lower()
    for ext in UPLOADABLE:
        if n.endswith(ext):
            n = n[: -len(ext)]
            break
    return n.strip()


def walk():
    """Discover the whole tablet tree live. Returns (documents, folders)."""
    docs, folders = [], []

    def rec(parent_id, rel):
        try:
            items = listing(parent_id)
        except Exception as e:
            print("  ! cannot list %s: %s" % (rel or "/", e), file=sys.stderr)
            return
        for it in items:
            name = safe(it.get("VisibleName") or it.get("VissibleName"))
            path = os.path.join(rel, name) if rel else name
            if it.get("Type") == "CollectionType":
                folders.append(path)
                rec(it["ID"], path)
            else:
                docs.append({"rel": path, "id": it["ID"],
                             "ftype": it.get("fileType"),
                             "mtime": parse_time(it.get("ModifiedClient"))})

    rec("", "")
    return docs, folders


def local_path(doc):
    rel = doc["rel"]
    if not rel.lower().endswith(".pdf"):
        rel += ".pdf"
    return os.path.join(DEST, rel)


def current(path, want_mtime):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return False
    if want_mtime is None:
        return True
    return abs(os.path.getmtime(path) - want_mtime) <= MTIME_SLACK


def download(doc, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    url = "%s/download/%s/placeholder" % (BASE, doc["id"])
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".part")
    os.close(fd)
    try:
        with urllib.request.urlopen(url, timeout=300) as r, open(tmp, "wb") as f:
            while True:
                chunk = r.read(65536)
                if not chunk:
                    break
                f.write(chunk)
        if os.path.getsize(tmp) == 0:
            raise IOError("empty response")
        os.replace(tmp, path)  # atomic: never leave a half file in place
        if doc["mtime"]:
            os.utime(path, (doc["mtime"], doc["mtime"]))
        return os.path.getsize(path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def post_upload(path):
    """POST one file as multipart/form-data.

    Returns the HTTP status. The tablet gives no destination control and the
    file may land in any folder, so a 201 does not tell you where it went.
    Callers must verify by walking the whole tree, not just the root.
    """
    boundary = "----rmsync" + uuid.uuid4().hex
    ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
    with open(path, "rb") as f:
        payload = f.read()
    head = ("--%s\r\nContent-Disposition: form-data; name=\"file\"; "
            "filename=\"%s\"\r\nContent-Type: %s\r\n\r\n"
            % (boundary, os.path.basename(path), ctype)).encode()
    body = head + payload + ("\r\n--%s--\r\n" % boundary).encode()
    req = urllib.request.Request(
        BASE + "/upload", data=body, method="POST",
        headers={"Content-Type": "multipart/form-data; boundary=" + boundary,
                 "Content-Length": str(len(body))})
    with urllib.request.urlopen(req, timeout=600) as r:
        return r.status


def find_local(): 
    """Every uploadable file under DEST."""
    out = []
    for root, _, files in os.walk(DEST):
        for f in files:
            if f.lower().endswith(UPLOADABLE) and not f.endswith(".part"):
                out.append(os.path.join(root, f))
    return sorted(out)


def do_download(docs, args):
    todo = [d for d in docs if args.force or not current(local_path(d), d["mtime"])]
    skip = len(docs) - len(todo)
    print("DOWNLOAD  up to date: %d   to fetch: %d" % (skip, len(todo)))
    if args.dry_run:
        for d in todo:
            print("   would fetch  %s" % local_path(d)[len(DEST) + 1:])
        return 0, 0, skip

    ok = failed = 0
    for i, d in enumerate(todo, 1):
        path = local_path(d)
        label = path[len(DEST) + 1:]
        for attempt in range(args.retries + 1):
            try:
                size = download(d, path)
                print("[%d/%d] got  %s (%.1f MB)" % (i, len(todo), label, size / 1e6))
                ok += 1
                break
            except Exception as e:
                if attempt < args.retries:
                    if not reachable():
                        print("      tablet not answering; waiting 15s "
                              "(may need USB file access re-toggled)")
                        time.sleep(15)
                    else:
                        time.sleep(2)
                    continue
                print("[%d/%d] FAIL %s: %s" % (i, len(todo), label, e))
                failed += 1
    return ok, failed, skip


def do_upload(docs, args):
    """Push local files that have no counterpart on the tablet.

    The destination folder cannot be chosen or predicted: observed uploads
    landed in the tablet's currently-open folder, not reliably in root. Local
    subfolders are therefore not reproduced, and files are matched by name
    only, never by path.
    """
    on_tablet = {key(os.path.basename(d["rel"])) for d in docs}
    todo = [p for p in find_local()
            if key(os.path.basename(p)) not in on_tablet]

    print("\nUPLOAD    local-only files: %d" % len(todo))
    if not todo:
        return 0, 0
    for p in todo:
        print("   would push   %s" % p[len(DEST) + 1:])
    if args.dry_run:
        return 0, 0

    sent = []
    for i, p in enumerate(todo, 1):
        label = p[len(DEST) + 1:]
        try:
            status = post_upload(p)
            print("[%d/%d] sent %s (HTTP %s, unverified)" % (i, len(todo), label, status))
            sent.append(p)
        except Exception as e:
            print("[%d/%d] FAIL %s: %s" % (i, len(todo), label, e))

    # A 201 does not say where the file went. Re-walk every folder to find it;
    # checking only the root reports successful uploads as missing.
    print("\n   verifying against the tablet ...")
    time.sleep(5)
    after, _ = walk()
    now = {key(os.path.basename(d["rel"])) for d in after}
    ok = [p for p in sent if key(os.path.basename(p)) in now]
    lost = [p for p in sent if key(os.path.basename(p)) not in now]
    for p in lost:
        print("   NOT FOUND anywhere on tablet after upload: %s" % p[len(DEST) + 1:])
    return len(ok), len(lost)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true",
                    help="show what would happen, write nothing either way")
    ap.add_argument("--force", action="store_true",
                    help="re-download every document, ignoring timestamps")
    ap.add_argument("--upload", action="store_true",
                    help="also push local-only files (destination folder is "
                         "chosen by the tablet, not by rmsync)")
    ap.add_argument("--no-download", action="store_true",
                    help="skip the download pass (use with --upload)")
    ap.add_argument("--retries", type=int, default=2,
                    help="retries per document (default: 2)")
    args = ap.parse_args()

    if not reachable():
        print(OFFLINE_HELP)
        return 2

    print("Discovering documents on the tablet ...")
    docs, folders = walk()
    if not docs:
        print("No documents found. Refusing to act on an empty listing.")
        return 2
    print("Found %d documents in %d folders.\n" % (len(docs), len(folders)))

    dok = dfail = dskip = 0
    if not args.no_download:
        dok, dfail, dskip = do_download(docs, args)

    uok = ufail = 0
    if args.upload:
        uok, ufail = do_upload(docs, args)

    if not args.dry_run:
        print("\ndownloaded: %d   failed: %d   already current: %d" % (dok, dfail, dskip))
        if args.upload:
            print("uploaded:   %d   rejected: %d" % (uok, ufail))
    return 1 if (dfail or ufail) else 0


if __name__ == "__main__":
    sys.exit(main())
