# Videos — Plex movie & TV library

This directory is a Plex library of DVD rips: movies and TV series.

## Library conventions

- One folder per movie, named `Movie Title (Year)` (Plex movie convention).
- Raw MakeMKV rips stay in `./<movie>/output/` and are **kept** after encoding.
- The finished encode lives in the movie folder as `Movie Title (Year).mkv`.
- `Doutor Jivago/` predates the `(Year)` convention — leave it unless asked.
- TV series: `Show Name (Year)/Season NN/`. Raw MakeMKV rips stay in
  `./<show>/Season NN/output/` and are **kept** after encoding. Encoded
  episodes land in the season folder as
  `Show Name - SXXEYY - Episode Title.mkv`.
- The `(Year)` belongs on the **series folder only** (the show's premiere
  year, used to disambiguate same-titled shows), never on `Season NN`
  folders — this matches both Plex's and Jellyfin's naming conventions, so
  the library structure works unchanged if the server is ever switched from
  Plex to Jellyfin.

## Ripping a DVD (movie)

Use the **`rip-film` skill**. It drives `~/Videos/dvd-ripper.sh` through
`rip` → `scan` → `encode` and handles year lookup, folder creation, feature-file
identification, and track selection.

Must run inside the distrobox that has `makemkvcon`, `HandBrakeCLI`, and
`mediainfo`.

## Ripping a DVD (TV series)

Use the **`rip-series` skill**. It drives `~/Videos/dvd-ripper.sh` through
`rip` → `batch` and handles episode-list lookup (season/episode/title),
folder creation, episode-vs-junk classification by duration, track selection,
and renaming each encoded file to its matched episode.

Same distrobox requirement as above.

## Ripping an audio CD

`cd-ripper.sh` has independent stages, run in its own image (`Containerfile.cd`:
cyanrip, flac, fdkaac, AtomicParsley, ffmpeg, jq): `rip`, `match`, `update`,
`encode`, and `run` (rip → match → encode; also the default with no command).
Code is split into `lib/*.sh`. Use the **`rip-cd` skill** to run it.

Key ideas:
- `rip` writes `<out>/RIP/<id>/` (raw lossless FLAC + `rip.log` + `rip.cue` in
  `raw/`, `rip.json`) and does **no metadata lookup** (`cyanrip -N`), so a
  metadata failure can never cost a rip. **Never re-rip a disc to fix tags.**
- Metadata is a separate step: `match` finds the MusicBrainz release (order:
  `--mb-release`, `--barcode`, saved disc ID, `--lookup` artist+album search),
  validates it against the real track count and durations, and previews;
  `--save` writes `release.json`. `update` writes tags/cover/names into existing
  FLAC/M4A files in place (no re-encode), preview unless `--apply`, and works on
  a rip folder or any folder of `.flac`/`.m4a` files.
- `encode` makes the FLAC master (`flac -8 --verify`) and, with `--format aac`,
  AAC derived from it (`fdkaac -m 5`). Encoder settings are fixed — don't change
  them. `--discard-master` removes only the FLAC deliverable; `RIP/` (log, cue)
  is never deleted. Disc rips also copy `rip.log`, `rip.cue` and
  `cyanrip-output.txt` into each album folder's `extras/`, so the rip record
  travels with the music when the folder is moved into the library.
- Output: separate trees `FLAC/Artist - Album/NN - Title.flac` and
  `AAC/Artist - Album/…` (flat; ` - Disc N` only for multi-disc; year is tagged
  not in the folder name). No match: `Unknown Artist - Unknown Album/Track NN`.
  Multi-disc needs `--disc N/TOTAL` unless one disc fits the durations.
- Ambiguous matches stop and list candidates; the user picks with `--mb-release`
  or `--pick earliest`. Never guess a barcode, release ID or year.
- **Drive offset is never assumed 0.** Order: `--offset`/`$CD_OFFSET` → saved
  per-drive value (`<out>/.cd-ripper/drive-offsets.tsv`) → AccurateRip drive
  database → `cyanrip -f` measured → stop with instructions. After the rip, if
  AccurateRip does not verify every track, `rip` stops (raw kept);
  `--allow-unverified` overrides. `--find-offset` measures once per drive.
- Disc commands need `--device` and network; WAV-folder runs can use
  `--network none`. Docker on macOS can't see the drive.
- The container sets `LANG=C.UTF-8` (fdkaac mangles accents otherwise). `inputs/`
  (WAV test albums) and `outputs/` are git-ignored test folders.
- Tests: `tests/run.sh` (docker, stand-in `cyanrip`, network). **Not yet verified
  on a real drive:** cyanrip's real `-N` output and log/cue names, whether
  `cyanrip -I` prints the disc ID, and its AccurateRip summary wording.

## Standing preferences

- Always keep **European Portuguese + English** audio and subtitles, with the
  **Portuguese track listed first** in both `--audio` and `--subtitle`.
- Many discs here have **Portuguese subtitles only** (no Portuguese audio) —
  that's fine: encode English audio plus both-language subtitles, don't stop.
- Keep the raw `./output/` rips.
- Encode settings are fixed by the script (x264 RF21, lossless audio copy,
  chapter markers) — don't change them.

## Identifying the feature file

Never trust "largest file" alone. Match `mediainfo` duration against the
official runtime, tolerance **±8%** (PAL rips run ~4% short). Watch for
multi-disc sets (longest title well under the known runtime).

## `dvd-ripper.sh` quick reference

Lives at `~/Videos/dvd-ripper.sh` (not on `$PATH` — always invoke by that
path, since these commands run from inside a movie/season subfolder).

```
~/Videos/dvd-ripper.sh rip
    # no flags; rips all titles of disc:0 to ./output/*.mkv (MakeMKV names them)

~/Videos/dvd-ripper.sh scan --input ./output/<file>.mkv [--save]
    # HandBrake track scan; --save writes ./output/<file>_scan.txt

~/Videos/dvd-ripper.sh encode --name "Movie Title (Year)" --input ./output/<file>.mkv \
    --audio <i,j> [--subtitle <i,j>]
    # comma-separated 1-based track numbers; writes "<name>.mkv" to CWD

~/Videos/dvd-ripper.sh batch --input-dir ./output --output-dir . \
    --audio <i,j> [--subtitle <i,j>]
    # TV series: same track selection applied to every file in --input-dir;
    # output keeps each file's original basename, --output-dir . writes into
    # the season folder (parent of output/) — rip-series renames after this
```

Track numbers are 1-based, comma-separated, and equal `mediainfo`'s per-kind
`%StreamKindPos%` (verified — HandBrake and mediainfo order tracks identically).
