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
| `--artist`, `--album`, `--year` | Override looked-up or folder-derived metadata |
| `--discard-master` | With `--format aac`, delete the FLAC afterwards |

### Output

FLAC and AAC go in separate trees under the output folder:

```
FLAC/Artist/Album (Year)/01 - Title.flac
AAC/Artist/Album (Year)/01 - Title.m4a
```

If no metadata is found, everything goes in one placeholder folder:

```
FLAC/Unknown Artist - Unknown Album/Track 01.flac
```

For disc rips, the cyanrip log and cue sheet are kept next to the FLAC files.

### Status

Folder import is tested end to end. Disc ripping is tested only against a
stand-in `cyanrip`, not yet against a real drive.

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
