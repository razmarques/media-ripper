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
LOOKUP=0
BARCODE=""
DISC=""
TOTAL_DISCS=""
OFFSET="${CD_OFFSET:-}"
OFFSET_SOURCE=""
FIND_OFFSET=0
DISC_ARG=""
ALLOW_UNVERIFIED=0

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
      --barcode <code>       Folder import only: look up the exact release by
                             its barcode (UPC/EAN, printed on the back
                             cover). Implies --lookup. Most reliable option;
                             artist and album are filled in if not given.
      --lookup               Folder import only: search MusicBrainz for the
                             artist + album and fill in year and missing
                             track titles. Needs network access and works
                             only if the match has the same track count.
      --disc <n[/total]>     Disc number for multi-disc releases, e.g. 2/3.
                             Disc rips read this from the lookup; for a
                             folder import, pass it yourself.
      --offset <samples>     Drive read offset in samples (or $CD_OFFSET).
                             Required for an accurate rip; if omitted it is
                             found automatically (see "Drive offset" below).
      --find-offset          Only measure this drive's offset (needs a disc
                             that is in the AccurateRip database), save it,
                             and exit.
      --allow-unverified     Keep the rip even if AccurateRip says tracks did
                             not verify. Default: stop before encoding.
      --discard-master       With --format aac: delete the FLAC master after
                             the AAC files are written
  -h, --help                 Show this help

Drive offset (disc rips):
  Every drive reads audio shifted by a fixed number of samples, and an
  accurate rip needs that value. It is never assumed to be 0. Order used:
    1. --offset / $CD_OFFSET
    2. saved value for this drive (<out>/.cd-ripper/drive-offsets.tsv)
    3. AccurateRip's drive database, matched on the drive's vendor + model
    4. measured from the inserted disc (cyanrip -f; the disc must be in the
       AccurateRip database)
  If none works the script stops and tells you what to do.

Folder import:
  If --artist/--album are not given, they are parsed from a folder named
  "Artist - Album" (a trailing "[WAV]" is ignored). Track numbers and titles
  are parsed from file names such as "3.Title.wav" or "Track 3.wav".
  A cover.jpg / folder.jpg in the folder is embedded.

Output layout:
  One folder per release: <out>/FLAC/Artist - Album/NN - Title.flac
  Multi-disc releases:    <out>/FLAC/Artist - Album - Disc 2/NN - Title.flac
  No match / unknown:     <out>/FLAC/Unknown Artist - Unknown Album/Track NN.flac
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
            --barcode)        BARCODE="${2:-}"; LOOKUP=1; shift 2 ;;
            --lookup)         LOOKUP=1; shift ;;
            --disc)           DISC_ARG="${2:-}"; shift 2 ;;
            --offset)         OFFSET="${2:-}"; shift 2 ;;
            --find-offset)    FIND_OFFSET=1; shift ;;
            --allow-unverified) ALLOW_UNVERIFIED=1; shift ;;
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
    if [[ -n "$DISC_ARG" ]]; then
        [[ "$DISC_ARG" =~ ^([0-9]+)(/([0-9]+))?$ ]] || die "--disc must look like 2 or 2/3 (got '$DISC_ARG')"
        DISC="${BASH_REMATCH[1]}"
        TOTAL_DISCS="${BASH_REMATCH[3]:-}"
        [[ "$DISC" -ge 1 ]] || die "--disc number must be 1 or more"
        if [[ -n "$TOTAL_DISCS" && "$DISC" -gt "$TOTAL_DISCS" ]]; then
            die "--disc $DISC is greater than the total ($TOTAL_DISCS)"
        fi
    fi
    if [[ -n "$OFFSET" ]]; then
        OFFSET="${OFFSET#+}"
        [[ "$OFFSET" =~ ^-?[0-9]+$ ]] || die "--offset must be an integer (got '$OFFSET')"
        OFFSET_SOURCE="user"
    fi
    if [[ -n "$BARCODE" ]]; then
        BARCODE="${BARCODE//[ -]/}"
        [[ "$BARCODE" =~ ^[0-9]{8,14}$ ]] || die "--barcode must be 8-14 digits"
    fi
    if [[ $LOOKUP -eq 1 && -z "$INPUT_DIR" ]]; then
        die "--lookup/--barcode apply to --input-dir imports (disc rips look up automatically)"
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

# Search MusicBrainz for ARTIST + ALBUM; accept a release only if one of its
# media has exactly as many tracks as we have WAVs. Fills YEAR (if empty) and
# any empty track titles. Failure is non-fatal: we keep what we have.
lookup_musicbrainz() {
    local total=${#TRACK_SRC[@]}
    local ua="media-ripper/1.0 (cd-ripper.sh)"
    local mb="https://musicbrainz.org/ws/2"

    if [[ -z "$BARCODE" && ( -z "$ARTIST" || -z "$ALBUM" ) ]]; then
        echo "Lookup skipped: need --barcode, or both artist and album."
        return 0
    fi
    command -v curl >/dev/null && command -v jq >/dev/null || {
        echo "Lookup skipped: curl/jq not available."
        return 0
    }

    echo ""
    local q resp ids id titles date n=0
    if [[ -n "$BARCODE" ]]; then
        echo "=== MusicBrainz lookup: barcode $BARCODE ($total tracks) ==="
        q="barcode:$BARCODE"
    else
        echo "=== MusicBrainz lookup: $ARTIST - $ALBUM ($total tracks) ==="
        q="artist:\"${ARTIST//\"/}\" AND release:\"${ALBUM//\"/}\""
    fi
    resp="$(curl -fsS --max-time 20 -A "$ua" -G "$mb/release" \
        --data-urlencode "query=$q" --data-urlencode "limit=10" \
        --data-urlencode "fmt=json")" || {
        echo "Lookup failed (network?); continuing without it."
        return 0
    }
    # The barcode search is fuzzy: keep only releases whose barcode is exact.
    ids="$(printf '%s' "$resp" | jq -r --arg b "$BARCODE" \
        '.releases[]? | select($b == "" or .barcode == $b) | .id')"
    [[ -n "$ids" ]] || { echo "No releases found; continuing without it."; return 0; }

    while IFS= read -r id; do
        n=$((n + 1)); [[ $n -gt 6 ]] && break
        sleep 1   # MusicBrainz asks for at most 1 request/second
        resp="$(curl -fsS --max-time 20 -A "$ua" -G "$mb/release/$id" \
            --data-urlencode "inc=recordings+artist-credits" --data-urlencode "fmt=json")" || continue
        local media
        media="$(printf '%s' "$resp" | jq -r '.media | length')"
        if [[ "$media" -gt 1 && -z "$DISC" ]]; then
            # Several discs and we don't know which one this is: don't guess.
            if printf '%s' "$resp" | jq -e --argjson n "$total" \
                '[.media[]? | select((.tracks | length) == $n)] | length > 0' >/dev/null; then
                TOTAL_DISCS="$media"
                echo "Release $id has $media discs; pass --disc <n> so the right"
                echo "track titles are used. Not applying titles."
                return 0
            fi
            continue
        fi
        titles="$(printf '%s' "$resp" | jq -r --argjson n "$total" --argjson d "${DISC:-0}" \
            '[.media[]? | select((.tracks | length) == $n and ($d == 0 or .position == $d))][0] | .tracks[]?.title')"
        [[ -n "$titles" ]] || continue
        [[ "$media" -gt 1 && -z "$TOTAL_DISCS" ]] && TOTAL_DISCS="$media"

        date="$(printf '%s' "$resp" | jq -r '.date // ""')"
        if [[ -n "$BARCODE" ]]; then
            [[ -z "$ARTIST" ]] && ARTIST="$(printf '%s' "$resp" | jq -r \
                '[."artist-credit"[]? | .name + (.joinphrase // "")] | join("")')"
            [[ -z "$ALBUM" ]] && ALBUM="$(printf '%s' "$resp" | jq -r '.title // ""')"
        fi
        if [[ -z "$YEAR" && "${date:0:4}" =~ ^[0-9]{4}$ ]]; then
            YEAR="${date:0:4}"
        fi
        local i=0 t
        while IFS= read -r t; do
            [[ -z "${TRACK_TITLE[$i]}" ]] && TRACK_TITLE[$i]="$t"
            i=$((i + 1))
        done <<< "$titles"
        echo "Matched release $id (${date:-no date})"
        return 0
    done <<< "$ids"

    echo "No release with $total tracks matched; continuing without it."
    [[ -n "$BARCODE" ]] && echo "(Does the barcode belong to this edition, and the track count match?)"
    return 0
}

# ============================================================================
# Drive offset + rip verification
# ============================================================================
# cyanrip refuses to rip until it knows the drive's read offset, and a wrong
# offset ruins AccurateRip verification. We never fall back to 0.

AR_OFFSETS_URL="http://www.accuraterip.com/driveoffsets.htm"

# "VENDOR - MODEL" for the drive, normalised like AccurateRip's list.
# Override with $CD_DRIVE_ID.
drive_id() {
    if [[ -n "${CD_DRIVE_ID:-}" ]]; then
        printf '%s' "$CD_DRIVE_ID"
        return 0
    fi
    local dev dir vendor model
    dev="$(basename "$DEVICE")"
    dir="/sys/class/block/$dev/device"
    [[ -r "$dir/vendor" && -r "$dir/model" ]] || return 0
    vendor="$(tr -s ' ' < "$dir/vendor" | sed 's/^ //;s/ $//')"
    model="$(tr -s ' ' < "$dir/model" | sed 's/^ //;s/ $//')"
    printf '%s - %s' "$vendor" "$model"
}

# Normalise a drive name so sysfs names and the AccurateRip list compare equal.
norm_drive() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -s ' ' \
        | sed -E 's/ +- +/ - /; s/^HL-DT-ST - /LG ELECTRONICS - /; s/^MATSHITA - /PANASONIC - /; s/^JLMS - /LITE-ON - /; s/^ATA - //; s/^ //; s/ $//'
}

offset_cache_file() { printf '%s/.cd-ripper/drive-offsets.tsv' "$OUT_DIR"; }

cache_get_offset() {
    local id="$1" f
    f="$(offset_cache_file)"
    [[ -f "$f" ]] || return 0
    awk -F'\t' -v id="$id" '$1 == id { v = $2 } END { if (v != "") print v }' "$f"
}

cache_put_offset() {
    local id="$1" off="$2" f
    [[ -n "$id" ]] || return 0
    f="$(offset_cache_file)"
    mkdir -p "$(dirname "$f")"
    if [[ -f "$f" ]]; then
        grep -v -F "$id"$'\t' "$f" > "$f.tmp" || true
        mv "$f.tmp" "$f"
    fi
    printf '%s\t%s\n' "$id" "$off" >> "$f"
}

# AccurateRip drive database lookup. Prints the offset only if the drive name
# matches and all matching rows agree on one numeric value.
ar_db_offset() {
    local id="$1" want
    [[ -n "$id" ]] || return 0
    command -v curl >/dev/null || return 0
    want="$(norm_drive "$id")"
    curl -fsS --max-time 30 -A "media-ripper/1.0 (cd-ripper.sh)" "$AR_OFFSETS_URL" 2>/dev/null \
      | sed -e 's/<[^>]*>/\n/g' -e 's/&nbsp;/ /g' -e 's/&amp;/\&/g' \
      | awk -v want="$want" '
            function trim(x) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", x); return x }
            function norm(x,   y) {
                y = toupper(x); gsub(/[ \t]+/, " ", y)
                sub(/ +- +/, " - ", y)
                sub(/^HL-DT-ST - /, "LG ELECTRONICS - ", y)
                sub(/^MATSHITA - /, "PANASONIC - ", y)
                sub(/^JLMS - /, "LITE-ON - ", y)
                sub(/^ATA - /, "", y)
                return trim(y)
            }
            { l = trim($0) }
            l == "" { next }
            l ~ /^[+-][0-9]+$/ || l ~ /^\[Purged\]$/ {
                if (norm(prev) == want) {
                    if (l ~ /^[+-]/) { v = l; sub(/^\+/, "", v); seen[v] = 1 } else seen["P"] = 1
                }
            }
            { prev = l }
            END {
                n = 0; for (k in seen) { n++; val = k }
                if (n == 1 && val != "P") print val
            }'
}

# Measure the offset from the inserted disc (needs an AccurateRip entry).
measure_offset() {
    local out found
    out="$(cyanrip -d "$DEVICE" -f 2>&1 | tee /dev/stderr)" || true
    found="$(printf '%s' "$out" | grep -aoE 'Drive offset of [+-]?[0-9]+ found' | tail -1 | grep -oE '[+-]?[0-9]+')"
    found="${found#+}"
    [[ -n "$found" ]] && printf '%s' "$found"
    return 0
}

resolve_offset() {
    local id cached db
    id="$(drive_id)"
    echo "Drive: ${id:-<unknown>}"

    if [[ -n "$OFFSET" ]]; then
        echo "Drive offset: $OFFSET (from --offset / \$CD_OFFSET)"
        return 0
    fi

    cached="$(cache_get_offset "$id")"
    if [[ -n "$cached" ]]; then
        OFFSET="$cached"; OFFSET_SOURCE="cache"
        echo "Drive offset: $OFFSET (saved for this drive)"
        return 0
    fi

    db="$(ar_db_offset "$id")"
    if [[ -n "$db" ]]; then
        OFFSET="$db"; OFFSET_SOURCE="db"
        echo "Drive offset: $OFFSET (AccurateRip drive database)"
        return 0
    fi

    echo "Drive not in the AccurateRip database (or name not recognised)."
    echo "Measuring the offset from the inserted disc (cyanrip -f)..."
    OFFSET="$(measure_offset)"
    if [[ -n "$OFFSET" ]]; then
        OFFSET_SOURCE="measured"
        echo "Drive offset: $OFFSET (measured)"
        cache_put_offset "$id" "$OFFSET"
        return 0
    fi

    die "Could not determine the drive offset.
  - Look your drive up at $AR_OFFSETS_URL and pass --offset <samples>, or
  - insert a disc that is in the AccurateRip database and run --find-offset."
}

# Reads cyanrip's AccurateRip summary. Sets VERIFY_STATUS to
# verified | failed | unavailable.
check_verification() {
    local out="$1" line acc tot
    VERIFY_STATUS="unavailable"
    if grep -aq 'missing entry\|Unable to get AccuRIP DB data' "$out"; then
        echo "AccurateRip: this disc is not in the database; the rip cannot be verified."
        return 0
    fi
    line="$(grep -aE 'Tracks ripped accurately: [0-9]+/[0-9]+' "$out" | tail -1)"
    if [[ -z "$line" ]]; then
        echo "AccurateRip: no verification result found in cyanrip output."
        return 0
    fi
    acc="$(printf '%s' "$line" | grep -oE '[0-9]+/[0-9]+' | head -1 | cut -d/ -f1)"
    tot="$(printf '%s' "$line" | grep -oE '[0-9]+/[0-9]+' | head -1 | cut -d/ -f2)"
    if [[ "$acc" -eq "$tot" ]]; then
        VERIFY_STATUS="verified"
        echo "AccurateRip: all $tot tracks verified."
    else
        VERIFY_STATUS="failed"
        echo "AccurateRip: only $acc/$tot tracks verified."
    fi
    return 0
}

# ============================================================================
# Source stage: optical drive
# ============================================================================

rip_with_cyanrip() {
    local stage="$1" nolookup="$2"
    local args=(-d "$DEVICE" -s "$OFFSET" -o flac -D rip -F "{track}" -L rip -M rip)
    [[ "$nolookup" == "1" ]] && args+=(-N)
    [[ -n "$DISC" && -n "$TOTAL_DISCS" ]] && args+=(-c "$DISC/$TOTAL_DISCS")
    (cd "$stage" && cyanrip "${args[@]}") 2>&1 | tee "$stage/cyanrip.out"
}

source_from_disc() {
    echo "=== Source: optical drive ($DEVICE) ==="
    resolve_offset
    local stage="$WORK_DIR/stage"
    mkdir -p "$stage"

    if ! rip_with_cyanrip "$stage" 0; then
        echo ""
        echo "Rip with metadata lookup failed; retrying without lookup."
        echo "(Output will use placeholder names unless --artist/--album given.)"
        rm -rf "$stage" && mkdir -p "$stage"
        rip_with_cyanrip "$stage" 1 || die "cyanrip failed"
    fi

    echo ""
    check_verification "$stage/cyanrip.out"
    if [[ "$VERIFY_STATUS" == "failed" && $ALLOW_UNVERIFIED -eq 0 ]]; then
        die "AccurateRip did not verify every track, so the rip is not trusted.
  Likely causes: wrong drive offset (offset used: $OFFSET, from $OFFSET_SOURCE),
  a damaged disc, or a different pressing than the database holds.
  Try --find-offset, clean the disc, or pass --allow-unverified to keep it."
    fi
    if [[ "$VERIFY_STATUS" == "verified" && ( "$OFFSET_SOURCE" == "db" ) ]]; then
        cache_put_offset "$(drive_id)" "$OFFSET"
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

    # Disc number / total (multi-disc releases), unless given with --disc.
    if [[ -z "$DISC" ]]; then
        t="$(flac_tag "$first" DISCNUMBER)"
        [[ -z "$t" ]] && t="$(flac_tag "$first" DISC)"
        if [[ "$t" =~ ^([0-9]+)(/([0-9]+))?$ ]]; then
            DISC="${BASH_REMATCH[1]}"
            [[ -z "$TOTAL_DISCS" ]] && TOTAL_DISCS="${BASH_REMATCH[3]:-}"
        fi
    fi
    if [[ -z "$TOTAL_DISCS" ]]; then
        t="$(flac_tag "$first" TOTALDISCS)"
        [[ -z "$t" ]] && t="$(flac_tag "$first" DISCTOTAL)"
        [[ "$t" =~ ^[0-9]+$ ]] && TOTAL_DISCS="$t"
    fi

    # Cover art embedded by cyanrip, reused for AAC.
    if metaflac --export-picture-to="$WORK_DIR/cover.img" "$first" 2>/dev/null; then
        COVER="$WORK_DIR/cover.img"
    fi

    # Keep the rip log and cue sheet with the master.
    mkdir -p "$WORK_DIR/extras"
    find "$stage/rip" -maxdepth 1 -type f \( -name '*.log' -o -name '*.cue' \) \
        -exec cp {} "$WORK_DIR/extras/" \; 2>/dev/null || true
    cp "$stage/cyanrip.out" "$WORK_DIR/extras/cyanrip-output.txt" 2>/dev/null || true
}

# ============================================================================
# Naming
# ============================================================================

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

is_multidisc() {
    [[ -n "$DISC" ]] || return 1
    [[ "$((10#$DISC))" -gt 1 ]] && return 0
    [[ -n "$TOTAL_DISCS" && "$((10#$TOTAL_DISCS))" -gt 1 ]] && return 0
    return 1
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
            if is_multidisc; then
                args+=(-T "DISCNUMBER=$((10#$DISC))")
                [[ -n "$TOTAL_DISCS" ]] && args+=(-T "DISCTOTAL=$((10#$TOTAL_DISCS))")
            fi
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
        if is_multidisc; then
            args+=(--disk "$((10#$DISC))${TOTAL_DISCS:+/$((10#$TOTAL_DISCS))}")
        fi
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

if [[ $FIND_OFFSET -eq 1 ]]; then
    command -v cyanrip >/dev/null || die "cyanrip not found"
    id="$(drive_id)"
    echo "Drive: ${id:-<unknown>}"
    found="$(measure_offset)"
    [[ -n "$found" ]] || die "Could not measure the offset. The inserted disc must be in the AccurateRip database."
    cache_put_offset "$id" "$found"
    echo ""
    echo "Drive offset: $found (saved to $(offset_cache_file))"
    echo "Use --offset $found to pass it explicitly."
    exit 0
fi

if [[ -n "$INPUT_DIR" ]]; then
    source_from_folder
    [[ $LOOKUP -eq 1 ]] && lookup_musicbrainz
else
    command -v cyanrip >/dev/null || die "cyanrip not found"
    source_from_disc
fi

if [[ -n "$TOTAL_DISCS" && "$((10#$TOTAL_DISCS))" -gt 1 && -z "$DISC" ]]; then
    die "This is a multi-disc release ($TOTAL_DISCS discs) but the disc number is unknown. Pass --disc <n> (e.g. --disc 2/$TOTAL_DISCS)."
fi

echo ""
echo "Artist: ${ARTIST:-<unknown>}"
echo "Album:  ${ALBUM:-<unknown>}"
echo "Year:   ${YEAR:-<unknown>}"
is_multidisc && echo "Disc:   $((10#$DISC))${TOTAL_DISCS:+ of $TOTAL_DISCS}"

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
