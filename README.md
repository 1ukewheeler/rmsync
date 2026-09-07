# rmsync

Sync a **reMarkable Paper Pro** to a local folder over **USB only** — no SSH, no
dependencies, one file, Python standard library.

```bash
./rmsync.py                  # download tablet -> Mac
./rmsync.py --upload         # also push local-only files Mac -> tablet
./rmsync.py --dry-run        # show what would happen, change nothing
./rmsync.py --upload --no-download   # push only
```

Documents land in `~/NotesDev/Remarkable`, mirroring the tablet's folder
structure. Edit `DEST` at the top of the script to change that.

## Why this exists

The usual recommendation for two-way reMarkable sync is
[rmirro](https://github.com/hersle/rmirro). It did not fit, for two independent
reasons:

1. **rmirro requires SSH.** It is not SSH-optional. SSH is how it enumerates
   documents and how it runs its `rsync` backup; the USB web interface is only
   its PDF *renderer*. "USB, no SSH" is not a configuration of rmirro — it is a
   different tool.
2. **rmirro is unmaintained and assumes rM1/rM2.** It verifies the connection by
   checking that `uname -n` returns `reMarkable`; a Paper Pro returns
   `imx8mm-ferrari`, so it refuses to run without a patch
   ([issue #11](https://github.com/hersle/rmirro/issues/11)).

rmsync talks only to the tablet's USB web interface at `10.11.99.1`.

## Design: discovery over stored config

There is **no manifest, catalog, or state file**. Every run rediscovers reality:

| Question | Answered by |
|---|---|
| What is on the tablet? | walked live from `/documents/` |
| What is on disk? | scanned from the destination tree |
| Is a file current? | local mtime vs the tablet's `ModifiedClient` |
| Did an upload work? | re-read the listing and confirm it is there |

Each downloaded file's mtime is stamped with the tablet's `ModifiedClient`
timestamp, so the filesystem *is* the sync state. Delete a local file and it
comes back. Change a notebook on the tablet and it re-downloads. There is
nothing to keep in sync and nothing to drift.

## Safety

- **Never deletes anything**, on the tablet or locally. Local files with no
  tablet counterpart are reported, not removed.
- Downloads go to a temp file and are **atomically renamed**, so an interrupted
  run cannot leave a truncated PDF in place.
- Refuses to act on an empty listing.
- Fails soft: if the tablet stops answering mid-run it waits and retries rather
  than crashing.

## The USB web interface, as actually observed

Endpoints on `http://10.11.99.1`:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/documents/` | JSON listing of the root folder |
| `GET` | `/documents/<id>` | JSON listing of a folder |
| `GET` | `/download/<id>/placeholder` | the document rendered to PDF |
| `POST` | `/upload` | multipart upload, field name `file` |

Three things worth knowing, each of which cost time to work out:

### 1. Uploads land in a folder you did not choose

The upload endpoint takes no destination parameter, and the file does **not**
reliably land in the root folder. Two test uploads made minutes apart, with
identical requests, ended up in different places:

| File | Landed in |
|---|---|
| `rmsync-upload-test.pdf` | `/Textbooks/` |
| `rmsync-real-test.pdf` | root |

The most likely explanation is that the file goes to whichever folder the
tablet currently has open, but that was not confirmed, and there is no way to
control or query it over the web interface. **Treat the destination folder as
unpredictable.**

The practical consequence: after uploading, you must search the whole tree to
find the file. `rmsync --upload` verifies by re-walking every folder, not by
checking the root — a root-only check reports successful uploads as missing.

### 2. The port refuses connections until USB file access is re-toggled

Symptom: `ping 10.11.99.1` succeeds, port 22 is open, but port 80 gives an
immediate connection *refused* — not a timeout — despite the USB web interface
being switched on.

Fix: Settings > General settings > Storage, toggle USB file access **off and
back on**.

(Note for anyone diagnosing this: refused-vs-timeout is the useful signal.
A refusal means the network path is fine and nothing is listening, which rules
out cables, routing, and firewalls.)

### 3. Notebooks and the extension mismatch

A notebook is `Physics` on the tablet but `Physics.pdf` on disk, so the
extension is stripped on both sides before comparing. Without that, every
downloaded notebook looks local-only and gets uploaded back as a duplicate PDF.
rmsync matches by **name only**, never by path, since paths cannot be relied on
across the upload boundary.

## Limitations

- **Everything arrives as PDF.** Notebooks are rendered by the tablet; `.epub`
  files come down as PDF, not as the original epub. The interface only serves
  rendered output.
- **Not true bidirectional sync.** The web API has no delete or rename
  endpoint, so deletions and renames do not propagate in either direction, and
  rmsync cannot remove a file from the tablet — that must be done on-device.
  Deleting a document on the tablet while its local copy remains means
  `--upload` will push it back. Use `--dry-run` first.
- **Upload is additive only**, and only for `.pdf` and `.epub`. You cannot
  choose the destination folder; see above.
- The tablet must be plugged in with USB file access on.
