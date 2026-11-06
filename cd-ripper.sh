#!/bin/bash

# ============================================================================
# CD Ripper
# ============================================================================
# Rip an audio CD (or import WAV files), match it to MusicBrainz, and write
# tagged FLAC and/or AAC files. Every step can be run on its own, so a failed
# metadata match never means ripping the disc again.
#
#   rip     disc -> <out>/RIP/<id>/ (lossless, rip.log, rip.cue, no lookup)
#   match   find the right release for a rip / folder; preview, --save it
#   update  write metadata into existing FLAC/M4A files (no re-encode)
#   encode  raw rip or WAV folder -> FLAC master and/or AAC
#   run     rip -> match -> encode in one go (also the default)
#
# Encoder settings are fixed on purpose so every album comes out the same:
#   FLAC: flac -8 --verify        AAC: fdkaac VBR mode 5 (AAC-LC, .m4a)
# AAC is always derived from the FLAC master, never from lossy audio.
#
# Dependencies: cyanrip (disc), flac + metaflac, fdkaac, AtomicParsley,
#               ffmpeg (ffprobe), curl, jq.
# ============================================================================

set -euo pipefail

LIB="${CD_RIPPER_LIB:-/usr/local/lib/cd-ripper}"
[[ -d "$LIB" ]] || LIB="$(dirname "$(readlink -f "$0")")/lib"

# shellcheck source=lib/common.sh
source "$LIB/common.sh"
source "$LIB/source.sh"
source "$LIB/tags.sh"
source "$LIB/offset.sh"
source "$LIB/metadata.sh"
source "$LIB/rip.sh"
source "$LIB/encode.sh"
source "$LIB/update.sh"
source "$LIB/run.sh"

show_usage() {
    cat << EOF
Usage: $0 <command> [folder] [options]

Commands:
  rip              Read the disc into <out>/RIP/<id>/ (lossless FLAC, rip.log,
                   rip.cue, rip.json). No lookup, so it cannot fail on metadata.
  match <folder>   Find the MusicBrainz release for a rip folder, a WAV folder
                   or existing FLAC/M4A files, check it against the real track
                   count and durations, and show what it would change.
                   --save writes release.json into the rip folder.
  update <folder>  Write metadata into existing files in place: tags, cover art
                   and names (no re-encode). Works on a rip folder (changes its
                   encoded FLAC/AAC) or on any folder of .flac/.m4a files.
                   Preview unless --apply.
  encode <folder>  Encode a rip folder or a folder of WAV files to FLAC and,
                   with --format aac, to AAC too. Uses release.json if present.
  run [folder]     rip -> match -> encode. With a WAV folder, skips the rip.
                   Without a command, this is what runs.

Options:
  -f, --format <flac|aac>    Encode: aac also keeps the FLAC master (default flac)
  -i, --input-dir <dir>      Folder of WAV files (same as giving the folder)
  -o, --out <dir>            Output folder (default \$CD_OUT_DIR or /music)
  -d, --device <path>        Optical drive (default \$CD_DEVICE or /dev/sr0)
      --discard-master       With --format aac: delete the FLAC master afterwards.
                             This removes ALL lossless audio; the rip log and cue
                             then go to the AAC folder's extras/rip/
      --rename-folder        update: also rename a library folder (rip output
                             folders are always renamed)
      --keep-raw             Keep RIP/<id>/raw after encoding (normally it is
                             removed once the verified FLAC master exists)

  Metadata (flags always win over what was found):
      --mb-release <id>      Use exactly this MusicBrainz release
      --barcode <code>       Release by barcode (UPC/EAN, back of the case). If
                             MusicBrainz has no usable release, Discogs is tried
                             ($DISCOGS_TOKEN optional: higher rate limit, covers)
      --discogs-release <n>  Use exactly this Discogs release (the number)
      --discid <id>          Release by MusicBrainz disc ID (set for you on rips)
      --lookup               Also search by artist + album (otherwise offline
                             for WAV folders; match/update always may)
      --pick earliest        If several different releases fit, take the earliest
      --artist, --album, --year   Set these directly
      --disc <n[/total]>     Disc number for multi-disc releases, e.g. 2/3
      --save                 match: write release.json
      --apply                update: really change files (default is a preview)

  Disc ripping:
      --offset <samples>     Drive read offset (else found automatically)
      --find-offset          Measure and save this drive's offset, then exit
      --allow-unverified     Keep a rip that AccurateRip did not verify
  -h, --help                 Show this help

Drive offset (disc rips): never assumed to be 0. Order: --offset / \$CD_OFFSET,
the value saved for this drive (<out>/.cd-ripper/drive-offsets.tsv), the
AccurateRip drive database, then measured from the disc (cyanrip -f).

Output:
  <out>/RIP/<id>/raw/                      the raw rip (removed after a verified encode)
  <out>/RIP/<id>/rip.json, release.json    small state files, kept
  <out>/FLAC/Artist - Album/NN - Title.flac
  <out>/FLAC/Artist - Album/extras/rip/    rip.log, rip.cue, ... (stored once, here)
  <out>/FLAC/Artist - Album/extras/release/  cover.jpg
  <out>/AAC/Artist - Album/NN - Title.m4a
  Multi-disc: "Artist - Album - Disc 2".   Unknown: "Unknown Artist - Unknown Album".

Examples:
  $0 run --format aac --barcode 042281827129      # rip, match, encode
  $0 rip                                          # just the disc
  $0 match /music/RIP/<id> --barcode 042281827129 # preview a match
  $0 update /music/RIP/<id> --barcode 042281827129 --apply
  $0 encode /music/RIP/<id> --format aac
  $0 run "/in/Artist - Album [WAV]" --format aac --barcode 042281827129
  $0 update "/music/Some Artist - Some Album" --mb-release <id> --apply
EOF
}

main() {
    local cmd="${1:-run}"
    case "$cmd" in
        rip|match|update|encode|run) [[ $# -gt 0 ]] && shift ;;
        *) cmd="run" ;;   # legacy: no subcommand means run
    esac

    parse_flags "$@"
    if [[ $FIND_OFFSET -eq 1 || "$cmd" =~ ^(rip|encode|run)$ ]]; then require_persistent_out; fi
    mkdir -p "$OUT_DIR"
    WORK_DIR="$(mktemp -d)"
    trap cleanup EXIT

    if [[ $FIND_OFFSET -eq 1 ]]; then
        cmd_find_offset
        exit 0
    fi

    case "$cmd" in
        rip)
            [[ -z "$TARGET" ]] || die "rip reads the optical drive and takes no folder."
            cmd_rip ;;
        match)  cmd_match ;;
        update) cmd_update ;;
        encode) cmd_encode ;;
        run)    cmd_run ;;
    esac
}

main "$@"
