#!/bin/bash

# ============================================================================
# CD Ripper
# ============================================================================
# One command: rip an audio CD (or import a folder of WAV files), encode it,
# and deliver tagged files to an output folder.
#
# The lossless FLAC master is ALWAYS produced first. Lossy output (AAC) is
# derived from that FLAC, never from another lossy file.
#
#   FLAC: flac -8 --verify                 (reference encoder, max compression)
#   AAC : fdkaac VBR mode 5, AAC-LC .m4a   (FDK-AAC, ~200-250 kbps)
#
# These parameters are fixed on purpose so every album comes out the same.
#
# Dependencies:
#   cyanrip  - secure CD ripping, AccurateRip, MusicBrainz (disc source only)
#   flac     - FLAC encoder + metaflac
#   fdkaac   - AAC encoder (AAC output only)
#
# ============================================================================

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
FORMAT="flac"
INPUT_DIR=""
OUT_DIR="${CD_OUT_DIR:-/music}"
DEVICE="${CD_DEVICE:-/dev/sr0}"
ARTIST=""
ALBUM=""
YEAR=""
DISCARD_MASTER=0

# Fixed encoder settings -- do not make these configurable.
FLAC_ARGS=(-8 -V -s -f)
FDK_ARGS=(-m 5 -S)

WORK_DIR=""
COVER=""
PLACEHOLDER_DIR="Unknown Artist - Unknown Album"

# Per-track data, index-aligned.
TRACK_SRC=()
TRACK_NUM=()
TRACK_TITLE=()
SRC_IS_FLAC=0

# ============================================================================
# Helpers
# ============================================================================

show_usage() {
    cat << EOF
Usage: $0 [options]

Rips an audio CD (or imports a folder of WAV files), encodes it, and writes
tagged files under <out>/FLAC/ or <out>/AAC/.

Options:
  -f, --format <flac|aac>    Output format (default: flac).
                             aac also keeps the FLAC master unless
                             --discard-master is given.
  -i, --input-dir <dir>      Import WAV files from this folder instead of
                             reading the optical drive.
  -o, --out <dir>            Output folder (default: \$CD_OUT_DIR or /music)
  -d, --device <path>        Optical drive (default: \$CD_DEVICE or /dev/sr0)
      --artist <name>        Album artist (overrides lookup / folder name)
      --album <title>        Album title  (overrides lookup / folder name)
      --year <yyyy>          Release year (overrides lookup)
      --discard-master       With --format aac: delete the FLAC master after
                             the AAC files are written
  -h, --help                 Show this help

Folder import:
  If --artist/--album are not given, they are parsed from a folder named
  "Artist - Album" (a trailing "[WAV]" is ignored). Track numbers and titles
  are parsed from file names such as "3.Title.wav" or "Track 3.wav".
  A cover.jpg / folder.jpg in the folder is embedded.

Output layout:
  Metadata known:    <out>/FLAC/Artist/Album (Year)/NN - Title.flac
  No match / unknown: <out>/FLAC/Unknown Artist - Unknown Album/Track NN.flac
  (AAC: same under <out>/AAC/, extension .m4a)

Examples:
  $0 --format flac
  $0 --format aac --discard-master
  $0 --input-dir "inputs/Gerry Mulligan - Night Lights [WAV]" --format aac
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

parse_flags() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--format)      FORMAT="${2:-}"; shift 2 ;;
            -i|--input-dir)   INPUT_DIR="${2:-}"; shift 2 ;;
            -o|--out)         OUT_DIR="${2:-}"; shift 2 ;;
            -d|--device)      DEVICE="${2:-}"; shift 2 ;;
            --artist)         ARTIST="${2:-}"; shift 2 ;;
            --album)          ALBUM="${2:-}"; shift 2 ;;
            --year)           YEAR="${2:-}"; shift 2 ;;
            --discard-master) DISCARD_MASTER=1; shift ;;
            -h|--help)        show_usage; exit 0 ;;
            *)
                echo "Error: Unknown option: $1" >&2
                echo "" >&2
                show_usage >&2
                exit 1 ;;
        esac
    done

    case "$FORMAT" in
        flac|aac) ;;
        *) die "--format must be 'flac' or 'aac' (got '$FORMAT')" ;;
    esac
    if [[ $DISCARD_MASTER -eq 1 && "$FORMAT" != "aac" ]]; then
        die "--discard-master only makes sense with --format aac"
    fi
    if [[ -n "$YEAR" && ! "$YEAR" =~ ^[0-9]{4}$ ]]; then
        die "--year must be 4 digits (got '$YEAR')"
    fi
}

# Make a string safe as a single path component.
sanitize() {
    local s="$1"
    s="${s//\// -}"
    s="${s//:/ -}"
    s="$(printf '%s' "$s" | tr -d '\000-\037' | sed -e 's/^[. ]*//' -e 's/[. ]*$//')"
    printf '%s' "$s"
}

pad2() { printf '%02d' "$((10#$1))"; }

# metaflac tag value (first occurrence), empty if absent.
flac_tag() {
    metaflac --show-tag="$2" "$1" 2>/dev/null | head -n 1 | cut -d= -f2- || true
}

cleanup() {
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ============================================================================
# Source stage: folder of WAVs
# ============================================================================

# Artist/album from a folder name like "Artist - Album [WAV]".
parse_folder_name() {
    local name
    name="$(basename "$INPUT_DIR")"
    name="$(printf '%s' "$name" | sed -E 's/[[:space:]]*\[[^]]*\][[:space:]]*$//')"
    if [[ "$name" == *" - "* ]]; then
        [[ -z "$ARTIST" ]] && ARTIST="${name%% - *}"
        [[ -z "$ALBUM" ]]  && ALBUM="${name#* - }"
    fi
    return 0
}

# Sets P_NUM / P_TITLE from a WAV file name; $2 is the fallback track number.
parse_track_name() {
    local base="${1%.*}"
    P_NUM="$2"
    P_TITLE=""
    if [[ "$base" =~ ^[Tt]rack[[:space:]_-]*([0-9]+)$ ]]; then
        P_NUM="${BASH_REMATCH[1]}"
    elif [[ "$base" =~ ^([0-9]+)$ ]]; then
        P_NUM="${BASH_REMATCH[1]}"
    elif [[ "$base" =~ ^([0-9]+)[[:space:]._-]+(.+)$ ]]; then
        P_NUM="${BASH_REMATCH[1]}"
        P_TITLE="${BASH_REMATCH[2]}"
    else
        P_TITLE="$base"
    fi
}

find_cover() {
    local dir="$1" f
    for f in cover.jpg cover.jpeg cover.png folder.jpg folder.png front.jpg front.png; do
        if [[ -f "$dir/$f" ]]; then
            COVER="$dir/$f"
            return 0
        fi
    done
    return 0
}

source_from_folder() {
    [[ -d "$INPUT_DIR" ]] || die "Input folder not found: $INPUT_DIR"
    echo "=== Source: WAV folder ==="
    echo "Folder: $INPUT_DIR"

    parse_folder_name
    find_cover "$INPUT_DIR"

    local files=() f idx=0
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$INPUT_DIR" -maxdepth 1 -type f -iname '*.wav' -print0 | sort -zV)

    [[ ${#files[@]} -gt 0 ]] || die "No .wav files in $INPUT_DIR"

    for f in "${files[@]}"; do
        idx=$((idx + 1))
        parse_track_name "$(basename "$f")" "$idx"
        TRACK_SRC+=("$f")
        TRACK_NUM+=("$P_NUM")
        TRACK_TITLE+=("$P_TITLE")
    done
    SRC_IS_FLAC=0
    echo "Tracks: ${#TRACK_SRC[@]}"
}

# ============================================================================
# Source stage: optical drive
# ============================================================================

rip_with_cyanrip() {
    local stage="$1" nolookup="$2"
    local args=(-d "$DEVICE" -o flac -D rip -F "{track}" -L rip -M rip)
    [[ "$nolookup" == "1" ]] && args+=(-N)
    (cd "$stage" && cyanrip "${args[@]}")
}

source_from_disc() {
    echo "=== Source: optical drive ($DEVICE) ==="
    local stage="$WORK_DIR/stage"
    mkdir -p "$stage"

    if ! rip_with_cyanrip "$stage" 0; then
        echo ""
        echo "Rip with metadata lookup failed; retrying without lookup."
        echo "(Output will use placeholder names unless --artist/--album given.)"
        rm -rf "$stage" && mkdir -p "$stage"
        rip_with_cyanrip "$stage" 1 || die "cyanrip failed"
    fi

    local f
    while IFS= read -r -d '' f; do
        TRACK_SRC+=("$f")
    done < <(find "$stage/rip" -maxdepth 1 -type f -name '*.flac' -print0 | sort -zV)
    [[ ${#TRACK_SRC[@]} -gt 0 ]] || die "cyanrip produced no FLAC files"
    SRC_IS_FLAC=1

    local first="${TRACK_SRC[0]}" n t
    for f in "${TRACK_SRC[@]}"; do
        n="$(flac_tag "$f" TRACKNUMBER)"
        TRACK_NUM+=("${n%%/*}")
        TRACK_TITLE+=("$(flac_tag "$f" TITLE)")
    done

    [[ -z "$ALBUM" ]]  && ALBUM="$(flac_tag "$first" ALBUM)"
    if [[ -z "$ARTIST" ]]; then
        ARTIST="$(flac_tag "$first" ALBUMARTIST)"
        [[ -z "$ARTIST" ]] && ARTIST="$(flac_tag "$first" ALBUM_ARTIST)"
        [[ -z "$ARTIST" ]] && ARTIST="$(flac_tag "$first" ARTIST)"
    fi
    if [[ -z "$YEAR" ]]; then
        t="$(flac_tag "$first" DATE)"
        YEAR="${t:0:4}"
        [[ "$YEAR" =~ ^[0-9]{4}$ ]] || YEAR=""
    fi

    # Cover art embedded by cyanrip, reused for AAC.
    if metaflac --export-picture-to="$WORK_DIR/cover.img" "$first" 2>/dev/null; then
        COVER="$WORK_DIR/cover.img"
    fi

    # Keep the rip log and cue sheet with the master.
    mkdir -p "$WORK_DIR/extras"
    find "$stage/rip" -maxdepth 1 -type f \( -name '*.log' -o -name '*.cue' \) \
        -exec cp {} "$WORK_DIR/extras/" \; 2>/dev/null || true
}

# ============================================================================
# Naming
# ============================================================================

album_rel_dir() {
    if [[ -n "$ARTIST" && -n "$ALBUM" ]]; then
        printf '%s/%s%s' "$(sanitize "$ARTIST")" "$(sanitize "$ALBUM")" "${YEAR:+ ($YEAR)}"
    else
        printf '%s' "$PLACEHOLDER_DIR"
    fi
}

track_basename() {
    local i="$1" n title
    n="$(pad2 "${TRACK_NUM[$i]}")"
    title="${TRACK_TITLE[$i]}"
    if [[ -n "$title" ]]; then
        printf '%s - %s' "$n" "$(sanitize "$title")"
    else
        printf 'Track %s' "$n"
    fi
}

# ============================================================================
# Encode stages
# ============================================================================

encode_flac_master() {
    local rel master_dir total i dst
    rel="$(album_rel_dir)"
    master_dir="$OUT_DIR/FLAC/$rel"
    total=${#TRACK_SRC[@]}
    mkdir -p "$master_dir"

    echo ""
    echo "=== Encoding FLAC (flac -8 --verify) -> $master_dir ==="

    MASTER_FILES=()
    for i in "${!TRACK_SRC[@]}"; do
        dst="$master_dir/$(track_basename "$i").flac"
        local args=("${FLAC_ARGS[@]}" -o "$dst")
        if [[ $SRC_IS_FLAC -eq 0 ]]; then
            # WAV source carries no tags: write them.
            args+=(-T "TRACKNUMBER=$((10#${TRACK_NUM[$i]}))" -T "TRACKTOTAL=$total")
            [[ -n "${TRACK_TITLE[$i]}" ]] && args+=(-T "TITLE=${TRACK_TITLE[$i]}")
            [[ -n "$ARTIST" ]] && args+=(-T "ARTIST=$ARTIST" -T "ALBUMARTIST=$ARTIST")
            [[ -n "$ALBUM" ]]  && args+=(-T "ALBUM=$ALBUM")
            [[ -n "$YEAR" ]]   && args+=(-T "DATE=$YEAR")
            [[ -n "$COVER" ]]  && args+=(--picture="$COVER")
        fi
        echo "  $(basename "$dst")"
        flac "${args[@]}" "${TRACK_SRC[$i]}"
        MASTER_FILES+=("$dst")
    done

    if [[ -d "$WORK_DIR/extras" ]]; then
        cp "$WORK_DIR"/extras/* "$master_dir/" 2>/dev/null || true
    fi
    MASTER_DIR="$master_dir"
}

encode_aac_from_master() {
    local rel aac_dir total i dst
    rel="$(album_rel_dir)"
    aac_dir="$OUT_DIR/AAC/$rel"
    total=${#MASTER_FILES[@]}
    mkdir -p "$aac_dir"

    echo ""
    echo "=== Encoding AAC from FLAC master (fdkaac VBR 5) -> $aac_dir ==="

    for i in "${!MASTER_FILES[@]}"; do
        dst="$aac_dir/$(track_basename "$i").m4a"
        local args=("${FDK_ARGS[@]}" -o "$dst" --track "$((10#${TRACK_NUM[$i]}))/$total")
        [[ -n "${TRACK_TITLE[$i]}" ]] && args+=(--title "${TRACK_TITLE[$i]}")
        [[ -n "$ARTIST" ]] && args+=(--artist "$ARTIST" --album-artist "$ARTIST")
        [[ -n "$ALBUM" ]]  && args+=(--album "$ALBUM")
        [[ -n "$YEAR" ]]   && args+=(--date "$YEAR")
        [[ -n "$COVER" ]]  && args+=(--tag-from-file "covr:$COVER")
        echo "  $(basename "$dst")"
        flac -d -c -s "${MASTER_FILES[$i]}" | fdkaac "${args[@]}" -
    done

    AAC_DIR="$aac_dir"
}

discard_master() {
    echo ""
    echo "=== Discarding FLAC master (--discard-master) ==="
    rm -rf "$MASTER_DIR"
    # Remove now-empty parent (Artist/) and FLAC/ dirs, if empty.
    rmdir -p --ignore-fail-on-non-empty "$(dirname "$MASTER_DIR")" 2>/dev/null || true
}

# ============================================================================
# Main
# ============================================================================

parse_flags "$@"

command -v flac >/dev/null || die "flac not found"
[[ "$FORMAT" == "aac" ]] && { command -v fdkaac >/dev/null || die "fdkaac not found"; }

mkdir -p "$OUT_DIR"
WORK_DIR="$(mktemp -d)"

MASTER_FILES=()
MASTER_DIR=""
AAC_DIR=""

if [[ -n "$INPUT_DIR" ]]; then
    source_from_folder
else
    command -v cyanrip >/dev/null || die "cyanrip not found"
    source_from_disc
fi

echo ""
echo "Artist: ${ARTIST:-<unknown>}"
echo "Album:  ${ALBUM:-<unknown>}"
echo "Year:   ${YEAR:-<unknown>}"

encode_flac_master

if [[ "$FORMAT" == "aac" ]]; then
    encode_aac_from_master
    [[ $DISCARD_MASTER -eq 1 ]] && discard_master
fi

echo ""
echo "=========================================="
echo "✔ Done"
echo "=========================================="
if [[ "$FORMAT" == "aac" ]]; then
    echo "AAC:  $AAC_DIR"
    [[ $DISCARD_MASTER -eq 1 ]] || echo "FLAC: $MASTER_DIR"
else
    echo "FLAC: $MASTER_DIR"
fi
