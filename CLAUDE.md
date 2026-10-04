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

Use the **`rip-film` skill**. It drives `dvd-rip` through
`info` → `rip` → `probe` → `scan` → `encode` and handles year lookup, folder
creation, feature-file identification, and track selection.

## Execution environment

All ripping/encoding runs inside a podman container, via the host wrapper
`dvd-rip` (repo root; put it on `$PATH`, e.g. symlink into `~/.local/bin`).
It runs exactly one `dvd-ripper.sh` subcommand per throwaway container, mounts
only `$LIBRARY_ROOT` (default `~/Videos`), has no network, and passes the optical
drive only to `rip`/`info`. Build the image once with `dvd-rip --build`.

`dvd-rip` is the **only** tool Claude uses for this work. `makemkvcon`,
`HandBrakeCLI`, `mediainfo`, `podman`, `docker` and `distrobox` are denied in
`.claude/settings.json` — never call them directly. Run `dvd-rip` from inside
the movie/season folder; it refuses to run outside `$LIBRARY_ROOT`.

## Ripping a DVD (TV series)

Use the **`rip-series` skill**. It drives `dvd-rip` through
`info` → `rip` → `probe` → `encode` (once per episode) and handles episode-list
lookup (season/episode/title), folder creation, episode-vs-junk classification
by duration, track selection, and encoding each episode straight to its
`Show Name - SXXEYY - Episode Title.mkv` name. Junk titles are never encoded.

Same execution environment as above.

## Standing preferences

- Always keep **European Portuguese + English** audio and subtitles, with the
  **Portuguese track listed first** in both `--audio` and `--subtitle`.
- Many discs here have **Portuguese subtitles only** (no Portuguese audio) —
  that's fine: encode English audio plus both-language subtitles, don't stop.
- Keep the raw `./output/` rips.
- Encode settings are fixed by the script (x264 RF21, lossless audio copy,
  chapter markers) — don't change them.

## Identifying the feature file

Never trust "largest file" alone. Match the `dvd-rip probe` duration against the
official runtime, tolerance **±8%** (PAL rips run ~4% short). Watch for
multi-disc sets (longest title well under the known runtime).

## `dvd-rip` quick reference

`dvd-rip` (host wrapper, on `$PATH`) forwards to `dvd-ripper.sh` inside the
container. Run it from inside the movie/season folder.

```
dvd-rip --build
    # build the container image from ./Containerfile

dvd-rip info
    # list the disc's titles (incl. cell counts) without ripping

dvd-rip rip
    # no flags; rips all titles of disc:0 to ./output/*.mkv (MakeMKV names them)

dvd-rip probe --input-dir ./output
    # one line per file: file|duration_ms|size_bytes

dvd-rip probe --input ./output/<file>.mkv
    # duration, size, resolution, plus audio/subtitle tables
    # (index|lang|lang_name|channels|title and index|lang|lang_name|format|forced)

dvd-rip scan --input ./output/<file>.mkv [--save]
    # HandBrake track scan; --save writes ./output/<file>_scan.txt

dvd-rip encode --name "Movie Title (Year)" --input ./output/<file>.mkv \
    --audio <i,j> [--subtitle <i,j>]
    # comma-separated 1-based track numbers; writes "<name>.mkv" to CWD.
    # TV series: call once per episode with
    # --name "Show Name - SXXEYY - Episode Title" from the season folder.
```

Track numbers are 1-based, comma-separated, and equal the `index` column of
`dvd-rip probe` (mediainfo's per-kind `%StreamKindPos%`; HandBrake and
mediainfo order tracks identically).
