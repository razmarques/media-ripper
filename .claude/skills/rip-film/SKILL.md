---
name: rip-film
description: >-
  Rip a single-feature movie DVD into the Plex library end to end using
  dvd-rip — find the release year, make a Plex folder, rip,
  identify the real feature file by duration, then scan and encode keeping
  European Portuguese + English audio and subtitles. Use when the user wants
  to rip a DVD / rip this disc / rip a movie, or mentions dvd-ripper for a
  movie. For TV-show discs (multiple episodes per disc), use the rip-series
  skill instead.
---

# rip-film

Automates the movie DVD → Plex workflow around `dvd-rip`, a host wrapper
(on `$PATH`) that runs one `dvd-ripper.sh` subcommand (`rip`, `info`, `scan`,
`probe`, `encode`) in a throwaway podman container. **`dvd-rip` is the only
tool you use for ripping, probing and encoding** — never call `makemkvcon`,
`HandBrakeCLI`, `mediainfo`, `podman` or `docker` directly (they are denied).
For TV-series discs (one disc = many episodes), use the `rip-series` skill
instead — it handles episode-list lookup and per-episode encoding.

The library root is `$LIBRARY_ROOT` (default `~/Videos/`); `dvd-rip` only works
from inside it. One folder per movie named
`Movie Title (Year)`; raw MakeMKV rips stay in `./output/`; the encoded file
lands in the movie folder as `Movie Title (Year).mkv`.

## Standing preferences

- Always keep **European Portuguese + English** audio and subtitles, **with the
  Portuguese track listed first** in both `--audio` and `--subtitle`.
- Many discs have **Portuguese subtitles only** (no Portuguese audio). That is
  fine — encode English audio + both-language subtitles, don't stop to ask.
- **Keep the raw `./output/` rips** after encoding. Never delete them.
- Encode settings are fixed by the script (x264 RF21, lossless audio copy,
  chapter markers) — don't try to change them.

## Procedure

### 1. Title and year

- Ask the user for the movie title (AskUserQuestion). Accept an optional year in
  their answer.
- If no year was given, `WebSearch` for it. Cross-check at least two sources
  (IMDb / Wikipedia / TMDB). While there, capture the **official runtime** (used
  in step 5) and the commonly-used English title.
- If sources disagree on year or title (remake vs original, festival vs wide
  release), stop and ask the user to pick via AskUserQuestion, listing each
  candidate with its source.

### 2. Preflight

- `dvd-rip info` to confirm a disc is actually readable before the long rip.
  On failure (including "image not found" — tell the user to run
  `dvd-rip --build`), surface the output and stop. Never try to install
  anything.

### 3. Folder

- Target folder name: `<Title> (<Year>)`. Replace or strip characters Plex/ext4
  dislike: `:` `/` `?` `*`.
- Case-insensitively look for an existing folder under `$LIBRARY_ROOT`
  (default `~/Videos/`).
  Reuse it if found, otherwise `mkdir` it.
- `cd` into it. Show the user the resolved absolute path, then proceed
  straight to ripping — no confirmation needed once metadata and the folder
  are in place.

### 4. Rip

- From inside the movie folder: `dvd-rip rip`
- It writes `./output/<label>_t<NN>.mkv`, one file per DVD title.
- When done, report `ls -lh output/`. If zero `.mkv` files were produced the rip
  failed — surface the MakeMKV output and stop.

### 5. Identify the feature file (be certain, not fast)

- Collect duration and size for every ripped file in one call:
  ```
  dvd-rip probe --input-dir ./output   # file|duration_ms|size_bytes
  ```
  (`dvd-rip probe --input <file>` also reports the resolution.)
- Compare each file's duration to the official runtime from step 1.
  **Tolerance ±8%** — DVD rips run a few % short (PAL 25 fps speedup is 4.3%),
  plus listing variance.
- **Auto-select** a file only when it is BOTH the largest file AND within ±8% of
  the official runtime. Print the full table (file, duration, size) and the pick
  either way.
- If the largest file and the closest duration match are different files, or
  nothing lands within ±8%, print the table and ask the user to choose
  (AskUserQuestion).
- If the best match is far below the known runtime (e.g. a 2h feature but the
  longest title is ~1h), it may be one disc of a multi-disc set — say so and ask
  how to proceed before continuing.

### 6. Scan (saved artifact)

- `dvd-rip scan --input ./output/<file> --save`
- This writes `./output/<file>_scan.txt`. Keep it for the record; do **not**
  parse it to choose tracks (HandBrake shows localized language names and its
  subtitle lines have no ISO codes). Use step 7 instead.

### 7. Pick tracks — European Portuguese + English

Source of truth is `dvd-rip probe`. Its `index` column (mediainfo's per-kind
`%StreamKindPos%`) is exactly the 1-based HandBrake `--audio` / `--subtitle`
index.

```
dvd-rip probe --input ./output/<file>
# audio:    index|lang|lang_name|channels|title
# subtitle: index|lang|lang_name|format|forced
```

- **Portuguese** = language `pt` or `pt-PT`. If a track reports `pt-BR` / `pob`
  (Brazilian), show it and ask whether to use it (usually skip).
- **English** = language `en`.
- Multiple candidate tracks for one language:
  - audio → prefer the most channels (5.1 over 2.0). Still tied → ask.
  - subtitle → prefer the non-forced full track (`%Forced%` = No). Still tied →
    ask.
- **No Portuguese audio**: proceed with English audio only, still add both
  Portuguese + English subtitles. Tell the user, don't stop.
- **No Portuguese anything**: continue English-only, no prompt.
- Build each list **Portuguese index first, then English**, dropping any absent
  language. Example: `--audio 2 --subtitle 7,3`.

### 8. Encode

From inside the movie folder:

```
dvd-rip encode --name "<Title> (<Year>)" \
    --input ./output/<file> \
    --audio <list> [--subtitle <list>]
```

- Quote `--name` — it has spaces and parentheses.
- Omit `--subtitle` only if there are genuinely no wanted subtitle tracks.
- Produces `<Title> (<Year>).mkv` in the movie folder.

### 9. Verify and report

- Confirm the output file exists (`ls`) and `dvd-rip probe --input` it.
- Check its duration ≈ the source file's, and that the expected audio/subtitle
  tracks are present in Portuguese-then-English order.
- Report the final path and size. **Leave `./output/` in place.**

## Notes

- Disc is always `disc:0` (single drive assumed).
- `dvd-rip` always uses HandBrake title `-t 1` — correct, because MakeMKV
  puts each DVD title in its own file.
- Audio is never re-encoded; the script forces `--aencoder copy` per track.
- HandBrake track numbers == the `index` column of `dvd-rip probe`.
- Duration tolerance is ±8% to absorb PAL speedup.
