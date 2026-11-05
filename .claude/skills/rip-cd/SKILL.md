---
name: rip-cd
description: >-
  Encode an audio CD (a folder of WAV files, or a disc in the drive) to FLAC
  and/or AAC by running cd-ripper.sh in its docker container. Claude only
  assembles the parameters — folder, barcode, artist, album, year, format —
  and runs the container; the script does the deterministic work. Use when the
  user wants to rip / convert / encode an audio CD, a folder of WAVs, or
  mentions cd-ripper. For DVDs use rip-film or rip-series instead.
---

# rip-cd

Claude's job here is to **assemble the right `docker run` command** for
`cd-ripper.sh` and run it. All encoding, naming, tagging and MusicBrainz
matching is done by the script, so never reimplement any of it, and never
change the encoder settings (FLAC `-8 --verify`, AAC `fdkaac -m 5`).

Image: `media-ripper-cd:latest`, built from `Containerfile.cd` in the repo root.
Docker only (no podman on this machine).

## Inputs to collect

From the user's message; ask (AskUserQuestion) only for what is missing and
needed:

| Need | Notes |
|---|---|
| **Input folder** | Folder of `.wav` files. Required unless ripping a physical disc. |
| **Format** | `flac` or `aac`. If not stated, ask. `aac` also keeps the FLAC master. |
| **Barcode** | Best identifier. Digits from the back cover (spaces/dashes are fine). |
| Artist, album | Only if the folder name isn't `Artist - Album [WAV]` and there's no barcode. |
| Year | Only if the user gives one. Never guess it. |
| Output folder | Default `./outputs` in the repo root. |
| Discard FLAC | Only for `aac`, and only if the user asked for it. |

Rules for the values:

- **Never invent a barcode, release ID or year.** Use exactly what the user
  gave. If the user has none, the script falls back to a text search.
- A barcode makes artist/album optional (MusicBrainz fills them). Without a
  barcode, lookup needs both artist and album (from flags or the folder name).
- If the user passes a catalog number, label or country: the script has no
  flag for those yet. Say so, and ask for the barcode instead (it is printed
  on the back cover) — don't try to work around it.
- `--discard-master` deletes the lossless copy. Use it only on an explicit
  request, and only with `--format aac`.

## Procedure

### 1. Make sure the image exists

```
docker image inspect media-ripper-cd:latest >/dev/null 2>&1 \
  || docker build -t media-ripper-cd:latest -f Containerfile.cd .
```

Run from the repo root. Rebuild (without `||`) if `cd-ripper.sh` or
`Containerfile.cd` changed since the image was built.

### 2. Build the command

Use absolute host paths and fixed container mount points, so the command
works regardless of the current directory:

```
docker run --rm [--network none] \
  -v "<abs input folder>":"/in/<folder name>":ro \
  -v "<abs output folder>":/music \
  media-ripper-cd:latest \
  --input-dir "/in/<folder name>" --format <flac|aac> \
  [--barcode <digits>] [--lookup] \
  [--artist "<artist>"] [--album "<album>"] [--year <yyyy>] \
  [--discard-master]
```

- `--barcode` implies lookup. Without a barcode, add `--lookup` only if the
  user wants MusicBrainz data and gave (or the folder name has) artist + album.
- **Network:** add `--network none` only when no lookup is requested. Lookup
  needs network, so omit it then.
- Create the output folder first (`mkdir -p`) so Docker doesn't create it as
  root.
- Quote every path and value; names contain spaces and accents.
- Physical disc (Linux host with the drive only): no `--input-dir`, add
  `--device=/dev/sr0`, keep the network on. The script finds the drive offset
  itself (flag/saved/AccurateRip DB/measured); pass `--offset <n>` only if the
  user gives one. If the user has a new drive, run `--find-offset` once first.
  If it stops with "AccurateRip did not verify", report that — never add
  `--allow-unverified` on your own. Docker on macOS cannot see the
  drive — say so rather than trying.

### 3. Run and read the output

Run the command and read what the script printed:

- `Matched release <id> (<date>)` — lookup worked. Report the release ID, year,
  and the artist/album it ended with.
- `No release … matched` / `Lookup skipped` — report why. Tracks then keep
  whatever the folder/file names gave. Suggest rerunning with `--barcode`.
- `Unknown Artist - Unknown Album` in the output path means no artist/album
  was found; offer to rerun with `--artist/--album` or `--barcode`.
- The year may be a reissue's date when matched by text search. Mention that a
  barcode gives an exact edition.

### 4. Report

Give the output paths (`FLAC/…`, `AAC/…`), track count, and which metadata
source was used (barcode / text search / folder names / none). Mention any
warnings. The `skipping unknown chunk 'LIST'` warnings from flac are harmless.
Don't move the files into the library or touch the input WAVs.

## Notes

- Output layout: `FLAC/Artist/Album (Year)/NN - Title.flac` and
  `AAC/…/NN - Title.m4a`; unmatched: `Unknown Artist - Unknown Album/Track NN`.
- Folder import reads titles from file names like `3.Title.wav`; `Track 3.wav`
  gives a number only. A `cover.jpg` / `folder.jpg` in the folder is embedded.
- Full option list: run the image with `--help`.
