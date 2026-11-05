# shellcheck shell=bash
# Shared state, helpers and flag parsing for cd-ripper.sh (sourced by it).

# ============================================================================
# Configuration (set by parse_flags)
# ============================================================================
FORMAT="flac"
TARGET=""                         # positional <dir> for match/update/encode
INPUT_DIR=""                      # --input-dir (WAV folder), alias for TARGET
OUT_DIR="${CD_OUT_DIR:-/music}"
DEVICE="${CD_DEVICE:-/dev/sr0}"

# Values given on the command line. They always win over everything else.
ARG_ARTIST=""
ARG_ALBUM=""
ARG_YEAR=""
ARG_DISC=""                       # disc number
ARG_TOTAL_DISCS=""
ARG_BARCODE=""
ARG_MBID=""                       # MusicBrainz release ID
ARG_DISCID=""                     # MusicBrainz disc ID
ARG_PICK=""                       # "earliest" to break ties between editions

LOOKUP=0                          # allow text search by artist + album in `run`
FIND_OFFSET=0
ALLOW_UNVERIFIED=0
DISCARD_MASTER=0
SAVE=0                            # match: write release.json
APPLY=0                           # update: really change files

OFFSET="${CD_OFFSET:-}"
OFFSET_SOURCE=""

# Fixed encoder settings -- do not make these configurable.
FLAC_ARGS=(-8 -V -s -f)
FDK_ARGS=(-m 5 -S)

PLACEHOLDER_DIR="Unknown Artist - Unknown Album"
UA="media-ripper/1.0 (cd-ripper.sh)"
MB_API="https://musicbrainz.org/ws/2"

WORK_DIR=""

# ============================================================================
# Per-run working state (reset_state clears it between stages)
# ============================================================================
SESSION_DIR=""                    # <out>/RIP/<id>, holds rip.json / release.json
SRC_KIND=""                       # flac (raw rip) | wav | library
SRC_DIR=""                        # directory holding the audio files

TRACK_SRC=()
TRACK_NUM=()
TRACK_DUR=()                      # seconds
FILE_TITLE=()                     # titles found in tags / file names
TRACK_TITLE=()                    # final titles
declare -A RJ_TITLE=()            # titles from release.json, keyed by track number

FILE_ARTIST=""; FILE_ALBUM=""; FILE_YEAR=""; FILE_DISC=""; FILE_TOTAL_DISCS=""
RJ_ARTIST="";   RJ_ALBUM="";   RJ_YEAR="";   RJ_DISC="";   RJ_TOTAL_DISCS=""
RJ_MBID="";     RJ_BARCODE=""; RJ_METHOD=""
ARTIST=""; ALBUM=""; YEAR=""; DISC=""; TOTAL_DISCS=""
COVER=""

reset_state() {
    SESSION_DIR=""; SRC_KIND=""; SRC_DIR=""
    TRACK_SRC=(); TRACK_NUM=(); TRACK_DUR=(); FILE_TITLE=(); TRACK_TITLE=()
    RJ_TITLE=()
    FILE_ARTIST=""; FILE_ALBUM=""; FILE_YEAR=""; FILE_DISC=""; FILE_TOTAL_DISCS=""
    RJ_ARTIST="";   RJ_ALBUM="";   RJ_YEAR="";   RJ_DISC="";   RJ_TOTAL_DISCS=""
    RJ_MBID="";     RJ_BARCODE=""; RJ_METHOD=""
    ARTIST=""; ALBUM=""; YEAR=""; DISC=""; TOTAL_DISCS=""
    COVER=""
}

# ============================================================================
# Small helpers
# ============================================================================

die() {
    echo "Error: $*" >&2
    exit 1
}

cleanup() {
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
    return 0
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

# ffprobe tag value (works for .m4a and anything else ffmpeg reads).
media_tag() {
    ffprobe -v error -show_entries "format_tags=$2" -of default=nw=1:nk=1 "$1" 2>/dev/null \
        | head -n 1 || true
}

# Duration of an audio file in seconds (float), empty on failure.
media_duration() {
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | head -n 1 || true
}

need_tools() {
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null || die "$t not found"
    done
}

# ============================================================================
# Naming
# ============================================================================

is_multidisc() {
    [[ -n "$DISC" ]] || return 1
    [[ "$((10#$DISC))" -gt 1 ]] && return 0
    [[ -n "$TOTAL_DISCS" && "$((10#$TOTAL_DISCS))" -gt 1 ]] && return 0
    return 1
}

# Single folder: "Artist - Album", plus " - Disc N" for multi-disc releases.
album_rel_dir() {
    local name
    if [[ -n "$ARTIST" && -n "$ALBUM" ]]; then
        name="$(sanitize "$ARTIST") - $(sanitize "$ALBUM")"
    else
        name="$PLACEHOLDER_DIR"
    fi
    if is_multidisc; then
        name="$name - Disc $((10#$DISC))"
    fi
    printf '%s' "$name"
}

# File base name (no extension) for track index $1.
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

# Artist/album from a folder name like "Artist - Album [WAV]".
# Sets FILE_ARTIST / FILE_ALBUM if empty.
parse_folder_name() {
    local name
    name="$(basename "$1")"
    name="$(printf '%s' "$name" | sed -E 's/[[:space:]]*\[[^]]*\][[:space:]]*$//')"
    if [[ "$name" == *" - "* ]]; then
        [[ -z "$FILE_ARTIST" ]] && FILE_ARTIST="${name%% - *}"
        [[ -z "$FILE_ALBUM" ]]  && FILE_ALBUM="${name#* - }"
    fi
    return 0
}

# Sets P_NUM / P_TITLE from a file name; $2 is the fallback track number.
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

# ============================================================================
# Flag parsing (one flag set for every command)
# ============================================================================

parse_flags() {
    local disc_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--format)        FORMAT="${2:-}"; shift 2 ;;
            -i|--input-dir)     INPUT_DIR="${2:-}"; shift 2 ;;
            -o|--out)           OUT_DIR="${2:-}"; shift 2 ;;
            -d|--device)        DEVICE="${2:-}"; shift 2 ;;
            --artist)           ARG_ARTIST="${2:-}"; shift 2 ;;
            --album)            ARG_ALBUM="${2:-}"; shift 2 ;;
            --year)             ARG_YEAR="${2:-}"; shift 2 ;;
            --barcode)          ARG_BARCODE="${2:-}"; shift 2 ;;
            --mb-release)       ARG_MBID="${2:-}"; shift 2 ;;
            --discid)           ARG_DISCID="${2:-}"; shift 2 ;;
            --pick)             ARG_PICK="${2:-}"; shift 2 ;;
            --lookup)           LOOKUP=1; shift ;;
            --disc)             disc_arg="${2:-}"; shift 2 ;;
            --offset)           OFFSET="${2:-}"; shift 2 ;;
            --find-offset)      FIND_OFFSET=1; shift ;;
            --allow-unverified) ALLOW_UNVERIFIED=1; shift ;;
            --discard-master)   DISCARD_MASTER=1; shift ;;
            --save)             SAVE=1; shift ;;
            --apply)            APPLY=1; shift ;;
            -h|--help)          show_usage; exit 0 ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                echo "" >&2
                show_usage >&2
                exit 1 ;;
            *)
                [[ -z "$TARGET" ]] || die "Unexpected argument: $1"
                TARGET="$1"; shift ;;
        esac
    done

    case "$FORMAT" in
        flac|aac) ;;
        *) die "--format must be 'flac' or 'aac' (got '$FORMAT')" ;;
    esac
    [[ -z "$ARG_PICK" || "$ARG_PICK" == "earliest" ]] || die "--pick must be 'earliest'"
    if [[ -n "$ARG_YEAR" && ! "$ARG_YEAR" =~ ^[0-9]{4}$ ]]; then
        die "--year must be 4 digits (got '$ARG_YEAR')"
    fi
    if [[ -n "$ARG_MBID" && ! "$ARG_MBID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
        die "--mb-release must be a MusicBrainz release ID (UUID)"
    fi
    if [[ -n "$disc_arg" ]]; then
        [[ "$disc_arg" =~ ^([0-9]+)(/([0-9]+))?$ ]] || die "--disc must look like 2 or 2/3 (got '$disc_arg')"
        ARG_DISC="${BASH_REMATCH[1]}"
        ARG_TOTAL_DISCS="${BASH_REMATCH[3]:-}"
        [[ "$ARG_DISC" -ge 1 ]] || die "--disc number must be 1 or more"
        if [[ -n "$ARG_TOTAL_DISCS" && "$ARG_DISC" -gt "$ARG_TOTAL_DISCS" ]]; then
            die "--disc $ARG_DISC is greater than the total ($ARG_TOTAL_DISCS)"
        fi
    fi
    if [[ -n "$OFFSET" ]]; then
        OFFSET="${OFFSET#+}"
        [[ "$OFFSET" =~ ^-?[0-9]+$ ]] || die "--offset must be an integer (got '$OFFSET')"
        OFFSET_SOURCE="user"
    fi
    if [[ -n "$ARG_BARCODE" ]]; then
        ARG_BARCODE="${ARG_BARCODE//[ -]/}"
        [[ "$ARG_BARCODE" =~ ^[0-9]{8,14}$ ]] || die "--barcode must be 8-14 digits"
    fi
    if [[ -z "$TARGET" && -n "$INPUT_DIR" ]]; then
        TARGET="$INPUT_DIR"
    fi
    return 0
}
