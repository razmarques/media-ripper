# media-ripper

Scripts for archiving physical media into a media library, run inside
containers so the host needs nothing but Docker (or Podman).

- **Audio CDs** → FLAC and/or AAC: `cd-ripper.sh` + `Containerfile.cd`
- **DVDs** → H.264 MKV: `dvd-ripper.sh` + `Containerfile`

## Audio CDs (`cd-ripper.sh`)

The CD tool is split into steps that run independently, so a failed metadata
match never means ripping the disc again.

| Command | What it does | Needs |
|---|---|---|
| `rip` | Reads the disc into `RIP/<id>/`: lossless FLAC, `rip.log`, `rip.cue`, `rip.json`. Does **no** lookup, so metadata can't make it fail. | the drive |
| `match <folder>` | Finds the MusicBrainz release for a rip, a WAV folder or existing FLAC/M4A files, checks it against the real track count and durations, and shows a preview. `--save` writes `release.json`. | network |
| `update <folder>` | Writes metadata (tags, cover art, file and folder names) into existing FLAC/M4A files **in place, without re-encoding**. Preview unless `--apply`. | none / network |
| `encode <folder>` | Raw rip or WAV folder to a FLAC master and, with `--format aac`, AAC. Uses `release.json` if there is one. | none |
| `run` | `rip` → `match` → `encode` in one go. Also what runs if you give no command. | the drive |

- The **FLAC master is always made first** (`flac -8 --verify`); **AAC** is
  derived from it (`fdkaac -m 5`: VBR, AAC-LC, `.m4a`). Settings are fixed so
  every album comes out the same.
- **A bad match never repeats the rip.** `run` encodes with placeholder names
  and prints the `update` command that fixes it later.

### 1. Build the image

```sh
docker build -t media-ripper-cd:latest -f Containerfile.cd .
```

The commands below use `cdr` as shorthand for this (set `~/Music` to wherever
you want the output; mount the **parent** folder when you want to rename
folders inside it):

```sh
alias cdr='docker run --rm -v ~/Music:/music media-ripper-cd:latest'
```

Disc commands (`rip`, `run`, `--find-offset`) also need `--device=/dev/sr0`
and network access. Docker on macOS cannot see the drive; use a Linux host.

### 2. Everyday use

```sh
# Rip, match and encode in one go (disc in the drive)
docker run --rm --device=/dev/sr0 -v ~/Music:/music media-ripper-cd:latest \
    run --format aac --barcode 042281827129

# Or step by step
cdr rip                                         # lossless rip -> RIP/<id>/
cdr match  /music/RIP/<id> --barcode 042281827129          # preview
cdr match  /music/RIP/<id> --barcode 042281827129 --save   # keep the match
cdr encode /music/RIP/<id> --format aac
```

### 3. Fix metadata later (no disc, no re-rip, no re-encode)

```sh
cdr update /music/RIP/<id> --barcode 042281827129            # preview the changes
cdr update /music/RIP/<id> --barcode 042281827129 --apply    # write them
```

`update` changes the encoded FLAC/AAC files recorded for that rip. It also works
on **any folder of `.flac`/`.m4a` files**, such as an existing library:

```sh
cdr update "/music/Some Artist - Some Album" --mb-release <id> --apply
```

The raw rip, `rip.log` and `rip.cue` are never touched by `match`, `update` or
`encode`.

### 4. WAV folders (no drive, no network needed)

```sh
docker run --rm --network none -v "$PWD/inputs":/in:ro -v ~/Music:/music \
    media-ripper-cd:latest run "/in/Artist - Album [WAV]" --format aac
```

Add `--barcode`/`--mb-release`/`--lookup` (and drop `--network none`) to match
online. Without them, artist/album come from a folder named `Artist - Album`
(a trailing `[WAV]` is ignored), titles from file names like `3.Title.wav`
(`Track 3.wav` gives a number only), and a `cover.jpg`/`folder.jpg` in the
folder is embedded.

### How matching works

Order: `--mb-release` → `--barcode` (exact) → the disc ID saved by `rip` →
artist + album search (`--lookup`; `match` and `update` allow it by default when
nothing better is given). Every candidate is **checked against your files**:
same track count and every track length within 2 s, so a different edition or
album is rejected. If several editions fit and they are the same record (titles
differ only in case or punctuation), the earliest dated one is taken and the
others are listed. If they are genuinely different, it stops and lists them;
choose with `--mb-release <id>` or `--pick earliest`. A multi-disc release
needs `--disc 2/3` unless exactly one disc fits. Cover art comes from the Cover
Art Archive. The barcode is on the back of the case.

### Accurate ripping (offset + AccurateRip)

A bit-exact rip needs the drive's **read offset**: every drive reads audio
shifted by a fixed number of samples. The script never assumes 0. It resolves
the offset in this order:

1. `--offset <samples>` (or `$CD_OFFSET`)
2. a value saved earlier for this drive (`<out>/.cd-ripper/drive-offsets.tsv`)
3. the [AccurateRip drive database](http://www.accuraterip.com/driveoffsets.htm),
   matched on the drive's vendor and model (needs network)
4. measured from the inserted disc with `cyanrip -f` (the disc must be in the
   AccurateRip database); the result is saved for next time

If none works, it stops and says how to fix it. To measure a new drive once:
`--find-offset`.

After ripping, cyanrip compares each track's checksum with **AccurateRip**, a
public database of checksums from other people who ripped the same pressing. If
every track matches, the rip is bit-for-bit what others got. If tracks do not
verify, `rip` stops (the raw rip is kept); `--allow-unverified` accepts it. A
disc that is not in the database cannot be verified; the script warns and
continues.

### Options

| Option | Meaning |
|---|---|
| `-f, --format flac\|aac` | Encode: `aac` also keeps the FLAC master (default `flac`) |
| `--discard-master` | With `--format aac`, delete the FLAC afterwards (the rip folder is never deleted) |
| `-o, --out <dir>` | Output folder (default `/music` in the container) |
| `-d, --device <path>` | Optical drive (default `/dev/sr0`) |
| `--mb-release <id>` | Use exactly this MusicBrainz release |
| `--barcode <code>` | Release by barcode (UPC/EAN) |
| `--discid <id>` | Release by MusicBrainz disc ID (recorded by `rip`) |
| `--lookup` | Also search by artist + album |
| `--pick earliest` | If several different releases fit, take the earliest |
| `--artist`, `--album`, `--year` | Set directly; always win over what was found |
| `--disc <n[/total]>` | Disc number for multi-disc releases, e.g. `2/3` |
| `--save` | `match`: write `release.json` |
| `--apply` | `update`: change files (default is a preview) |
| `--offset <samples>`, `--find-offset`, `--allow-unverified` | Disc ripping, see above |

### Output

```
RIP/<id>/raw/           the lossless rip + rip.log + rip.cue (never renamed or deleted)
RIP/<id>/rip.json       drive, offset, AccurateRip result, disc ID, encoded folders
RIP/<id>/release.json   the matched metadata (after match --save)
FLAC/Artist - Album/01 - Title.flac
FLAC/Artist - Album/extras/   rip.log, rip.cue, cyanrip-output.txt (disc rips only)
AAC/Artist - Album/01 - Title.m4a
AAC/Artist - Album/extras/    same, so the record moves with the folder
FLAC/Artist - Album - Disc 2/...                  multi-disc releases only
FLAC/Unknown Artist - Unknown Album/Track 01.flac no metadata found
```

FLAC and AAC are separate trees so the two formats never collide. The year is
tagged but not part of the folder name. `extras/` is a copy: the originals stay in
`RIP/<id>/`. In the FLAC copy the cue's file names point at the renamed tracks
(`../01 - Title.flac`); `update` keeps them in step. In the AAC copy the cue is
unchanged, since it describes the lossless rip.

### Status and limits

Everything except the real drive is covered by `tests/run.sh` (stand-in
`cyanrip`, uses the network). **Not yet tested on a real drive:** cyanrip's real
`-N` output and log/cue names, whether `cyanrip -I` shows the disc ID (without
it `run` has nothing to look up automatically and needs `--barcode`), and the
wording of its AccurateRip summary. Run `rip` once and inspect
`RIP/<id>/rip.log`, `rip.json` and `disc-info.txt`.

```sh
docker build -t media-ripper-cd:latest -f Containerfile.cd .
tests/run.sh      # needs inputs/album: WAVs of Gerry Mulligan - Night Lights
```

## DVDs (`dvd-ripper.sh`)

Commands: `rip` (MakeMKV, lossless), `scan` (HandBrake track listing) and
`encode` (H.264 RF21, audio copied, chapter markers). The image is described
in `Containerfile`. Run `dvd-ripper.sh` with no arguments for usage. See
`CLAUDE.md` for the library conventions.

## Layout

```
cd-ripper.sh      CD tool: rip / match / update / encode / run
lib/              its modules (offset, rip, metadata, encode, update, ...)
tests/            tests/run.sh and a stand-in cyanrip
Containerfile.cd  image for cd-ripper.sh
dvd-ripper.sh     DVD ripping and encoding
Containerfile     image for dvd-ripper.sh
inputs/           WAV test albums (git-ignored)
```
