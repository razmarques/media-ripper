# media-ripper

Scripts for archiving physical media into a media library, run inside
containers so the host needs nothing but Docker (or Podman).

- **Audio CDs** → FLAC and/or AAC: `cd-ripper.sh` + `Containerfile.cd`
- **DVDs** → H.264 MKV: `dvd-ripper.sh` + `Containerfile`

## Audio CDs (`cd-ripper.sh`)

One command rips a disc (or imports a folder of WAV files), encodes it, and
writes tagged files to an output folder.

- The **FLAC master is always created first** (`flac -8 --verify`).
- **AAC** is derived from that FLAC (`fdkaac -m 5`: VBR, AAC-LC, `.m4a`),
  never from another lossy file.
- Encoder settings are fixed so every album comes out the same.

### 1. Build the image

```sh
docker build -t media-ripper-cd:latest -f Containerfile.cd .
```

### 2. Rip a disc

The container needs the optical drive, plus network access (MusicBrainz
metadata and AccurateRip verification). The drive must be reachable from the
container, which in practice means a Linux host.

```sh
docker run --rm --device=/dev/sr0 -v ~/Music:/music \
    media-ripper-cd:latest --format flac
```

Use `--format aac` for AAC (the FLAC master is kept too), or add
`--discard-master` to delete the FLAC after the AAC files are written.

#### Accurate ripping (offset + AccurateRip)

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

```sh
docker run --rm --device=/dev/sr0 -v ~/Music:/music media-ripper-cd:latest --find-offset
```

After ripping, cyanrip compares each track's checksum with **AccurateRip**,
a public database of checksums submitted by other people who ripped the same
pressing. If every track matches, the rip is bit-for-bit what others got. If
tracks do not verify, the script **stops before encoding** (wrong offset,
damaged disc, or a different pressing). `--allow-unverified` keeps the rip
anyway. A disc that is not in the database cannot be verified; the script
warns and continues. The cyanrip log, cue sheet and output are kept next to
the FLAC files.

### 3. Or import a folder of WAV files (no drive, no network)

Useful for testing, or for discs you already ripped:

```sh
docker run --rm --network none \
    -v "$PWD/inputs":/in:ro -v ~/Music:/music \
    media-ripper-cd:latest --input-dir "/in/Artist - Album [WAV]" --format aac
```

Metadata for a folder import:

- **Artist / album** come from the folder name `Artist - Album` (a trailing
  `[WAV]` is ignored), or from `--artist` / `--album`.
- **Track numbers and titles** come from file names such as `3.Title.wav`.
  Names like `Track 3.wav` give a number and no title.
- A `cover.jpg` / `folder.jpg` in the folder is embedded.

### Options

| Option | Meaning |
|---|---|
| `-f, --format flac\|aac` | Output format (default `flac`) |
| `-i, --input-dir <dir>` | Import WAVs from a folder instead of the drive |
| `-o, --out <dir>` | Output folder (default `/music` in the container) |
| `-d, --device <path>` | Optical drive (default `/dev/sr0`) |
| `--offset <samples>` | Drive read offset (else found automatically, see above) |
| `--find-offset` | Measure and save this drive's offset, then exit |
| `--allow-unverified` | Keep a rip that AccurateRip did not verify |
| `--barcode <code>` | Folder import: exact MusicBrainz release by barcode |
| `--lookup` | Folder import: MusicBrainz text search by artist + album |
| `--disc <n[/total]>` | Disc number for multi-disc releases, e.g. `2/3` |
| `--artist`, `--album`, `--year` | Override looked-up or folder-derived metadata |
| `--discard-master` | With `--format aac`, delete the FLAC afterwards |

### Output

One folder per release, named `Artist - Album`. FLAC and AAC go in separate
trees so the two formats never collide:

```
FLAC/Artist - Album/01 - Title.flac
AAC/Artist - Album/01 - Title.m4a
```

Multi-disc releases (and only those) get a disc suffix, one folder per disc:

```
FLAC/Artist - Album - Disc 1/01 - Title.flac
FLAC/Artist - Album - Disc 2/01 - Title.flac
```

The disc number comes from the disc lookup on a real rip. For a folder
import, pass `--disc 2/3` (disc 2 of 3). If a release has several discs and
the disc number is unknown, the script stops and asks for `--disc` instead of
guessing. `--disc 1` alone, with no total, counts as a single-disc release.

If no metadata is found, everything goes in one placeholder folder:

```
FLAC/Unknown Artist - Unknown Album/Track 01.flac
```

For disc rips, the cyanrip log and cue sheet are kept next to the FLAC files.

### Status

Folder import is tested end to end. Disc ripping, including offset
resolution and AccurateRip checks, is tested only against a stand-in
`cyanrip` and the real AccurateRip drive list, not yet against a real drive.

## DVDs (`dvd-ripper.sh`)

Commands: `rip` (MakeMKV, lossless), `scan` (HandBrake track listing) and
`encode` (H.264 RF21, audio copied, chapter markers). The image is described
in `Containerfile`. Run `dvd-ripper.sh` with no arguments for usage. See
`CLAUDE.md` for the library conventions.

## Layout

```
cd-ripper.sh      CD ripping and encoding
Containerfile.cd  image for cd-ripper.sh
dvd-ripper.sh     DVD ripping and encoding
Containerfile     image for dvd-ripper.sh
inputs/           WAV test albums (git-ignored)
```
