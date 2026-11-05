---
name: rip-cd
description: >-
  Rip, match, encode or fix the metadata of audio CDs with cd-ripper.sh in its
  docker container: a disc in the drive, a folder of WAV files, or existing
  FLAC/M4A files. Claude only assembles the parameters (folder, barcode,
  artist, album, year, disc, format) and runs the right stage; the script does
  the deterministic work. Use when the user wants to rip / convert / encode an
  audio CD or WAV folder, or to fix tags / artwork / names on a rip or on
  existing music files. For DVDs use rip-film or rip-series instead.
---

# rip-cd

Claude's job is to **pick the right stage and assemble the `docker run` command**
for `cd-ripper.sh`, run it, and report. All ripping, matching, encoding and
tagging is done by the script — never reimplement it, and never change the
encoder settings (FLAC `-8 --verify`, AAC `fdkaac -m 5`).

Image: `media-ripper-cd:latest`, built from `Containerfile.cd` in the repo root.
Docker only (no podman on this machine).

## The stages

| Stage | Use it when |
|---|---|
| `run` | New disc or WAV folder, end to end: rip → match → encode. |
| `rip` | Only read the disc (lossless, no lookup). |
| `match <folder>` | Find / check the MusicBrainz release; preview, `--save` keeps it. |
| `update <folder>` | **Metadata is wrong or missing on files that already exist.** Retags / renames in place, no re-rip and no re-encode. Preview unless `--apply`. |
| `encode <folder>` | Encode a rip folder or WAV folder (again). |

**Never re-rip a disc, and never re-encode, just to fix metadata.** If a rip
exists in `<out>/RIP/<id>/`, fix it with `update` (or `match --save` then
`encode`). If the user says metadata was not found after a rip, the answer is
`update <RIP folder> --barcode … --apply`, not another rip.

## Inputs to collect

From the user's message; ask (AskUserQuestion) only for what is missing and needed:

| Need | Notes |
|---|---|
| **What to work on** | Disc in the drive, a WAV folder, a `RIP/<id>` folder, or a folder of existing `.flac`/`.m4a`. |
| **Format** | `flac` or `aac` for `run`/`encode`. If not stated, ask. `aac` also keeps the FLAC master. |
| **Barcode** | Best identifier (back of the case; spaces/dashes fine). |
| `--mb-release <id>` | Only if the user gives one, or to resolve an ambiguity they chose. |
| Artist, album | Only if there is no barcode and the folder isn't named `Artist - Album [WAV]`. |
| Year, disc | Only if the user gives them. Disc looks like `2/3`. Never guess either. |
| Output folder | Default `./outputs` in the repo root. |
| Discard FLAC | Only for `aac`, and only if the user asked for it. |

Rules:

- **Never invent a barcode, release ID or year.** Use exactly what the user gave.
- A catalog number, label or country can't be passed to the script; ask for the
  barcode instead.
- `--discard-master` deletes the FLAC deliverable (the `RIP/` folder with the
  log and cue is never deleted). Use it only on an explicit request, with aac.
- `--pick earliest` and `--allow-unverified` are the user's decisions: never add
  them on your own.

## Procedure

### 1. Make sure the image is current

```
docker build -t media-ripper-cd:latest -f Containerfile.cd .
```

Cheap when nothing changed; required after any change to `cd-ripper.sh`,
`lib/` or `Containerfile.cd`.

### 2. Build the command

Absolute host paths, fixed mount points:

```
docker run --rm [--network none] [--device=/dev/sr0] \
  [-v "<abs input folder>":"/in/<name>":ro] \
  -v "<abs output folder>":/music \
  media-ripper-cd:latest <stage> [<folder>] [options]
```

- Folders inside the container: a WAV folder is `/in/<name>`; a rip folder or
  library folder is under `/music/...` (mount the **parent** of a folder you want
  renamed — a mount point itself cannot be renamed).
- `mkdir -p` the output folder first so Docker doesn't create it as root.
- **Network:** `--network none` only when nothing needs MusicBrainz (WAV-folder
  `run`/`encode` with no `--barcode`/`--mb-release`/`--lookup`). `match`,
  `update` with identifiers, and every disc command need the network.
- **Disc** (`rip`, `run` without a folder): add `--device=/dev/sr0`, keep the
  network on. The script finds the drive offset itself; pass `--offset <n>` only
  if the user gives one, or run `--find-offset` once for a new drive. Docker on
  macOS cannot see the drive: say so rather than trying.
- Quote every path and value; names contain spaces and accents.

### 3. Common flows

- **New disc:** `run --format <f> [--barcode <digits>]`. Without a barcode the
  rip still succeeds and encodes with placeholder names; then offer `update`.
- **New WAV folder:** `run /in/<name> --format <f> [--barcode <digits>]`.
- **Fix metadata afterwards:** first `update <folder> --barcode <digits>`
  **without `--apply`**, show the user the preview (artist, album, year, titles,
  renames), and only after they agree run it again with `--apply`.
- **Ambiguous match** (script exits 3 and lists editions): show the candidates
  (date, country, label, barcode) and let the user choose; rerun with
  `--mb-release <id>`. Offer `--pick earliest` as the alternative.
- **Multi-disc:** if the script asks for the disc number, ask the user and pass
  `--disc N/TOTAL`.
- **Verification failure** (`AccurateRip did not verify`): report it as is; the
  raw rip is kept. Never add `--allow-unverified` yourself.

### 4. Report

Say which stage ran, the output paths (`FLAC/…`, `AAC/…`, `RIP/<id>/`), the track
count, the metadata source (barcode / disc ID / search / folder names / none) with
the matched release ID and date, and any warnings. The flac message
`skipping unknown chunk 'LIST'` is harmless. Don't move files into the library
or touch the input WAVs.

## Notes

- Layout: `FLAC/Artist - Album/NN - Title.flac`, `AAC/Artist - Album/…m4a`;
  multi-disc `… - Disc N`; no match `Unknown Artist - Unknown Album/Track NN`.
  The year is tagged, not in the folder name.
- Matching is checked against the real files (track count and durations within
  2 s), so a wrong edition is rejected rather than applied.
- Folder imports read titles from names like `3.Title.wav`; a `cover.jpg` /
  `folder.jpg` in the folder is embedded; MusicBrainz cover art is used when a
  match is saved.
- Full option list: run the image with `--help`.
