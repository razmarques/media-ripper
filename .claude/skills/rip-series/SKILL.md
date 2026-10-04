---
name: rip-series
description: >-
  Rip a TV-series DVD into the Plex library end to end using
  dvd-rip — find the episode list for the season, rip all titles, classify
  episodes vs junk titles by duration, match each episode to its title, then
  encode each episode (keeping European Portuguese + English audio and
  subtitles) straight to its Plex filename. Use when the user wants to rip a TV series / a
  season disc / multiple episodes from a DVD, or mentions dvd-ripper for a
  show rather than a movie. For single-feature movie discs, use rip-film
  instead.
---

# rip-series

Automates the TV-series DVD → Plex workflow around `dvd-rip`, a host wrapper
(on `$PATH`) that runs one `dvd-ripper.sh` subcommand (`rip`, `info`, `scan`,
`probe`, `encode`) in a throwaway podman container. **`dvd-rip` is the only
tool you use for ripping, probing and encoding** — never call `makemkvcon`,
`HandBrakeCLI`, `mediainfo`, `podman` or `docker` directly (they are denied).
Companion to the `rip-film` skill, which handles single-feature movie discs —
use this one instead whenever a disc holds multiple episodes.

The library root is `$LIBRARY_ROOT` (default `~/Videos/`); `dvd-rip` only works
from inside it. Layout: `Show Name (Year)/Season NN/` is the season folder —
raw MakeMKV rips stay in `./output/` inside it; encoded episodes land directly
in the season folder (the parent of `output/`) as
`Show Name - SXXEYY - Episode Title.mkv`.

## Standing preferences

- Always keep **European Portuguese + English** audio and subtitles, **with
  the Portuguese track listed first** in both `--audio` and `--subtitle`.
- Many discs have **Portuguese subtitles only** (no Portuguese audio). That is
  fine — encode English audio + both-language subtitles, don't stop to ask.
- **Keep the raw `./output/` rips** after encoding. Never delete them.
- Encode settings are fixed by the script (x264 RF21, lossless audio copy,
  chapter markers) — don't try to change them.
- Each episode is encoded with its own `dvd-rip encode` call, but this skill
  picks **one** audio/subtitle track selection and reuses it for every
  episode. That is safe because all titles ripped from the same disc are
  authored identically — verify that assumption in step 6 rather than taking
  it for granted.

## Procedure

### 1. Show, season, and episode list

- Ask the user (AskUserQuestion) for the show title and which season/disc
  this is. A season can span multiple discs — confirm which disc(s) this rip
  covers.
- `WebSearch` for the episode list of that season: episode number, title, and
  runtime if available. Cross-check at least two sources (TheTVDB, TMDB,
  Wikipedia, a relevant fandom wiki, epguides.com). While there, capture the
  release year for the folder name.
- If sources disagree on episode count, order, or titles, stop and ask the
  user to pick via AskUserQuestion, listing each candidate with its source.

### 2. Preflight

- `dvd-rip info` to confirm a disc is actually readable before the long rip.
  On failure (including "image not found" — tell the user to run
  `dvd-rip --build`), surface the output and stop. Never try to install
  anything.
- Keep this output around for step 5. Each line like
  `MSG:3028,...,"Title #N was added (X cell(s), duration)"` gives that
  title's **cell count** — a free second signal for classifying episodes vs
  junk, no extra cost since this scan already runs. These lines appear in
  the same order MakeMKV will later write `./output/*_t00.mkv`,
  `*_t01.mkv`, ... (sequential, only titles above its minimum-length
  threshold) — so the Nth line here is the Nth ripped file in filename
  order.

### 3. Folder

- Show folder name: `<Show Name> (<Year>)`. Replace or strip characters
  Plex/ext4 dislike: `:` `/` `?` `*`.
- Season folder inside it: `Season <NN>`, zero-padded two digits (Plex
  convention), e.g. `Season 01`.
- Case-insensitively look for an existing show folder under `$LIBRARY_ROOT`
  (default `~/Videos/`). Reuse it if found, otherwise `mkdir` it; do the same
  for the season folder inside it.
- `cd` into the season folder. Show the user the resolved absolute path, then
  proceed straight to ripping — no confirmation needed once metadata and the
  folder are in place.

### 4. Rip

- From inside the season folder: `dvd-rip rip`
- It writes `./output/<label>_t<NN>.mkv`, one file per DVD title (episodes
  and, usually, non-episode junk titles mixed together).
- When done, report `ls -lh output/`. If zero `.mkv` files were produced the
  rip failed — surface the MakeMKV output and stop.

### 5. Classify ripped titles: episode vs junk

- Collect duration and size for every ripped file in one call:
  ```
  dvd-rip probe --input-dir ./output   # file|duration_ms|size_bytes
  ```
- DVD title sets for series almost always include non-episode junk (menus,
  trailers, recaps, promos) alongside the real episodes. Compare each
  duration against the known episode runtimes from step 1, **tolerance ±8%**
  (same as the movie workflow, to absorb PAL speedup and listing variance) —
  treat anything within tolerance of *any* expected episode runtime as an
  episode candidate, everything else as junk.
- Cross-reference each file's **cell count** from the step-2 preflight
  listing (matched positionally, per above). Real episodes on a disc are
  almost always authored with an identical cell count; a title whose cell
  count doesn't match the others is a strong junk signal even if its
  duration happens to land within the ±8% tolerance — downgrade it to junk
  rather than trusting duration alone in that case. Cell count only tells
  you episode-vs-junk, not episode order — it won't disambiguate which
  specific episode a file is.
- Print the full table (file, duration, size, cell count, classification:
  episode candidate / junk). If the number of episode candidates doesn't
  match the number of episodes expected on this disc, show the table and
  ask the user how to proceed (AskUserQuestion) rather than guessing.

### 6. Pick tracks — European Portuguese + English

Source of truth is `dvd-rip probe`. Its `index` column (mediainfo's per-kind
`%StreamKindPos%`) is exactly the 1-based HandBrake `--audio` / `--subtitle`
index.

```
dvd-rip probe --input ./output/<file>
# audio:    index|lang|lang_name|channels|title
# subtitle: index|lang|lang_name|format|forced
```

- Run this against one episode-candidate file, then spot-check a second one.
  If the two disagree on track layout, stop and ask before proceeding — don't
  assume the rest of the disc matches.
- **Portuguese** = language `pt` or `pt-PT`. If a track reports `pt-BR` /
  `pob` (Brazilian), show it and ask whether to use it (usually skip).
- **English** = language `en`.
- Multiple candidate tracks for one language:
  - audio → prefer the most channels (5.1 over 2.0). Still tied → ask.
  - subtitle → prefer the non-forced full track (`%Forced%` = No). Still tied
    → ask.
- **No Portuguese audio**: proceed with English audio only, still add both
  Portuguese + English subtitles. Tell the user, don't stop.
- **No Portuguese anything**: continue English-only, no prompt.
- Build each list **Portuguese index first, then English**, dropping any
  absent language. Example: `--audio 2 --subtitle 7,3`.

### 7. Scan (saved artifact)

- `dvd-rip scan --input ./output/<one episode file> --save`
- This writes `./output/<file>_scan.txt`. Keep it for the record only — same
  as the movie workflow, don't parse it to choose tracks.

### 8. Map titles to episodes (before encoding)

- Take the files classified as episode candidates in step 5, sorted by their
  title order (the DVD authoring order, i.e. filename order), and match them
  1:1, in order, against the step-1 episode list sorted by episode number.
  Cross-check duration against any known per-episode runtime as a sanity
  check.
- Build the target name for each: `Show Name - SXXEYY - Episode Title`
  (e.g. `Shaun the Sheep - S01E01 - Off the Baa!`). Strip `:` `/` `?` `*`.
- Print the file → episode table. If the order/duration cross-check conflicts
  for any file (e.g. an episode's duration doesn't fit where the order says
  it should go), stop and ask rather than guessing at episode identity —
  encoding is slow, so settle identity first.

### 9. Encode each episode

For every matched episode, from inside the season folder:

```
dvd-rip encode --name "<Show Name> - SXXEYY - <Episode Title>" \
    --input ./output/<file> \
    --audio <list> [--subtitle <list>]
```

- Quote `--name` — it has spaces. The file lands in the season folder (the
  current directory) already named correctly; there is no rename step.
- Junk titles are **not** encoded; they stay untouched in `./output/`.
- Run the episodes one after another (the encode of each is long); if one
  fails, report it and stop rather than skipping silently.

### 10. Verify and report

- `dvd-rip probe --input` each encoded episode: confirm its duration matches
  its source, and that the expected audio/subtitle tracks are present in
  Portuguese-then-English order.
- Report the final season folder listing (`ls`). **Leave `./output/` in
  place.**

## Notes

- Disc is always `disc:0` (single drive assumed).
- `dvd-rip` always uses HandBrake title `-t 1` — correct, because MakeMKV puts
  each DVD title in its own file.
- Audio is never re-encoded; the script forces `--aencoder copy` per track.
- HandBrake track numbers == the `index` column of `dvd-rip probe`.
- Duration tolerance is ±8% to absorb PAL speedup.
- A season spanning multiple discs means repeating steps 2–10 once per disc,
  reusing the same show/season folder and the same episode list from step 1
  (just a different slice of it per disc).
