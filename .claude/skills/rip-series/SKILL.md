---
name: rip-series
description: >-
  Rip a TV-series DVD into the Plex library end to end using
  ~/Videos/dvd-ripper.sh — find the episode list for the season, rip all titles,
  classify episodes vs junk titles by duration, batch-encode keeping European
  Portuguese + English audio and subtitles, then rename each encoded file to
  the episode it matches. Use when the user wants to rip a TV series / a
  season disc / multiple episodes from a DVD, or mentions dvd-ripper for a
  show rather than a movie. For single-feature movie discs, use rip-film
  instead.
---

# rip-series

Automates the TV-series DVD → Plex workflow around `~/Videos/dvd-ripper.sh`'s
(not on `$PATH` — always invoke by this path) `batch` command. Must run
inside the distrobox that has `makemkvcon`,
`HandBrakeCLI`, and `mediainfo`. Companion to the `rip-film` skill, which
handles single-feature movie discs — use this one instead whenever a disc
holds multiple episodes.

The library root is `/home/rodolfo/Videos/`. Layout:
`Show Name (Year)/Season NN/` is the season folder — raw MakeMKV rips stay in
`./output/` inside it; encoded episodes land directly in the season folder
(the parent of `output/`) as `Show Name - SXXEYY - Episode Title.mkv`.

## Standing preferences

- Always keep **European Portuguese + English** audio and subtitles, **with
  the Portuguese track listed first** in both `--audio` and `--subtitle`.
- Many discs have **Portuguese subtitles only** (no Portuguese audio). That is
  fine — encode English audio + both-language subtitles, don't stop to ask.
- **Keep the raw `./output/` rips** after encoding. Never delete them.
- Encode settings are fixed by the script (x264 RF21, lossless audio copy,
  chapter markers) — don't try to change them.
- `dvd-ripper.sh batch` applies **one** audio/subtitle track selection to
  every file in the input directory. This is safe because all titles ripped
  from the same disc are authored identically — verify that assumption in
  step 6 rather than taking it for granted.

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

- `command -v makemkvcon HandBrakeCLI mediainfo` — if any is missing, stop and
  tell the user to start Claude inside the distrobox that has them. Never try
  to install anything.
- `makemkvcon -r info disc:0` to confirm a disc is actually readable before
  the long rip. On failure, surface the output and stop.
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
- Case-insensitively look for an existing show folder under
  `/home/rodolfo/Videos/`. Reuse it if found, otherwise `mkdir` it; do the
  same for the season folder inside it.
- `cd` into the season folder. Show the user the resolved absolute path, then
  proceed straight to ripping — no confirmation needed once metadata and the
  folder are in place.

### 4. Rip

- From inside the season folder: `~/Videos/dvd-ripper.sh rip`
- It writes `./output/<label>_t<NN>.mkv`, one file per DVD title (episodes
  and, usually, non-episode junk titles mixed together).
- When done, report `ls -lh output/`. If zero `.mkv` files were produced the
  rip failed — surface the MakeMKV output and stop.

### 5. Classify ripped titles: episode vs junk

- For every `output/*.mkv`, collect duration and size:
  ```
  mediainfo --Output='General;%Duration%' <file>   # milliseconds
  ```
  plus `ls -l` size.
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

Source of truth is `mediainfo`. Its per-kind `%StreamKindPos%` is exactly the
1-based HandBrake `--audio` / `--subtitle` index.

```
mediainfo --Output='Audio;%StreamKindPos%|%Language%|%Language/String%|%Channel(s)%|%Title%\n' <file>
mediainfo --Output='Text;%StreamKindPos%|%Language%|%Language/String%|%Format%|%Forced%\n' <file>
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

- `~/Videos/dvd-ripper.sh scan --input ./output/<one episode file> --save`
- This writes `./output/<file>_scan.txt`. Keep it for the record only — same
  as the movie workflow, don't parse it to choose tracks.

### 8. Batch encode

From inside the season folder:

```
~/Videos/dvd-ripper.sh batch --input-dir ./output --output-dir . \
    --audio <list> [--subtitle <list>]
```

- `--output-dir .` writes encoded files into the season folder itself (the
  parent of `./output/`).
- This encodes **every** ripped title, junk included — `batch` has no
  filtering flag, and this workflow does not modify the script. Junk titles
  are usually short, so this is cheap; they're handled in step 10.
- Output filenames mirror the raw basenames (e.g. `title_t00.mkv`).

### 9. Rename using the episode map

- Restrict attention to the batch-encoded files whose raw counterpart was
  classified as an episode candidate in step 5.
- Sort those by their original title order (the DVD authoring order), and
  match them 1:1, in order, against the step-1 episode list sorted by episode
  number. Cross-check duration as a sanity check.
- Rename each matched file to the Plex convention:
  `Show Name - SXXEYY - Episode Title.mkv` (e.g.
  `Shaun the Sheep - S01E01 - Off the Baa!.mkv`), in the season folder.
- If the order/duration cross-check conflicts for any file (e.g. an episode's
  duration doesn't fit where the order says it should go), stop and ask
  rather than guessing at episode identity.

### 10. Leftover junk outputs

- Any batch-encoded file that didn't match an episode (from a junk raw title)
  is a wasted encode of non-episode footage. List these for the user and ask
  before deleting them — never delete without confirmation. The raw junk
  titles stay untouched in `./output/` regardless.

### 11. Verify and report

- `mediainfo` each renamed episode file: confirm its duration matches its
  source, and that the expected audio/subtitle tracks are present in
  Portuguese-then-English order.
- Report the final season folder listing. **Leave `./output/` in place.**

## Notes

- Disc is always `disc:0` (single drive assumed).
- `~/Videos/dvd-ripper.sh` always uses HandBrake title `-t 1` — correct,
  because MakeMKV puts each DVD title in its own file.
- Audio is never re-encoded; the script forces `--aencoder copy` per track.
- HandBrake track numbers == `mediainfo` per-kind `%StreamKindPos%`.
- Duration tolerance is ±8% to absorb PAL speedup.
- A season spanning multiple discs means repeating steps 2–11 once per disc,
  reusing the same show/season folder and the same episode list from step 1
  (just a different slice of it per disc).
