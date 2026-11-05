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

`cd-ripper.sh` is a single command (no subcommands): it rips a CD (or imports
a folder of WAVs), encodes, and writes tagged files to an output folder. It
runs in its own image, built from `Containerfile.cd` (cyanrip, flac, fdkaac) —
separate from the DVD image because the toolchains share nothing.

```
docker build -t media-ripper-cd:latest -f Containerfile.cd .

# Disc: needs the drive and network (MusicBrainz + AccurateRip)
docker run --rm --device=/dev/sr0 -v "$MUSIC_ROOT":/music \
    media-ripper-cd:latest --format flac|aac [--discard-master]

# Folder import (testing; offline). Artist/album come from a folder named
# "Artist - Album [WAV]", titles from file names like "3.Title.wav"
docker run --rm --network none -v "$PWD/inputs":/in:ro -v "$MUSIC_ROOT":/music \
    media-ripper-cd:latest --input-dir "/in/Artist - Album [WAV]" --format aac
```

- The **FLAC master is always produced first** (`flac -8 --verify`); AAC is
  derived from it (`fdkaac -m 5`, VBR, AAC-LC `.m4a`). Never encode lossy from
  lossy. `--discard-master` deletes the FLAC after an AAC run; by default it
  is kept. Encoder settings are fixed by the script — don't change them.
- Output goes to `--out` (default `/music` inside the container, i.e. the
  mounted `$MUSIC_ROOT`), in separate trees: `FLAC/…` and `AAC/…`.
- Layout when metadata is known: `Artist/Album (Year)/NN - Title.ext`. When
  there is no match: `Unknown Artist - Unknown Album/Track NN.ext`.
- Test status: folder import is tested end to end (FLAC verified bit-exact
  against the WAV; AAC tags incl. accents). The disc path was tested only with
  a stand-in `cyanrip` (tag read-back, naming, FLAC re-encode, retry without
  lookup) — **not yet against a real drive**.
- The container sets `LANG=C.UTF-8`; without it fdkaac mangles accented tags
  to `??`. Keep it in `Containerfile.cd`.
- `inputs/` holds WAV test albums and is git-ignored.

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
