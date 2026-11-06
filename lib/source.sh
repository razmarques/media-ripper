# shellcheck shell=bash
# Sessions (RIP/<id>/), reading the audio that is there, and combining
# metadata from files, release.json and flags into one answer.
#
#   <out>/RIP/<id>/
#     raw/            lossless rip + rip.log + rip.cue; after a verified encode the
#                     audio is removed and the reports move to extras/rip/ of the
#                     FLAC album folder (see encode.sh)
#     cyanrip-output.txt, disc-info.txt   (also moved to extras/rip/)
#     rip.json        facts about the rip + list of deliverable folders
#     release.json    metadata (written by `match --save`)
#     cover.img       cover art fetched for release.json

wav_fingerprint() { # folder -> 8 hex chars from the names and sizes of its WAV files
    find "$1" -maxdepth 1 -type f -iname '*.wav' -printf '%f\t%s\n' | LC_ALL=C sort | sha1sum | cut -c1-8
}

has_ext() { # dir ext...
    local dir="$1" e; shift
    for e in "$@"; do
        if find "$dir" -maxdepth 1 -type f -iname "*.$e" -print -quit | grep -q .; then
            return 0
        fi
    done
    return 1
}

session_json() { printf '%s/rip.json' "$SESSION_DIR"; }

# Replace a file's contents with jq output, safely.
jq_edit() { # file, jq args...
    local f="$1" tmp; shift
    tmp="$(mktemp)"
    jq "$@" "$f" > "$tmp" && mv "$tmp" "$f"
}

ensure_session() {
    [[ -n "$SESSION_DIR" ]] || return 0
    mkdir -p "$SESSION_DIR"
    if [[ ! -f "$(session_json)" ]]; then
        jq -n --arg p "$SRC_DIR" --arg d "$(date -u +%FT%TZ)" \
            '{version: 1, source: "wav", source_path: $p, created: $d, outputs: []}' \
            > "$(session_json)"
    fi
}

rip_json_add_output() { # format, rel dir (relative to OUT_DIR)
    [[ -n "$SESSION_DIR" && -f "$(session_json)" ]] || return 0
    jq_edit "$(session_json)" --arg f "$1" --arg d "$2" \
        '.outputs = ((.outputs // []) | map(select(.dir != $d)) + [{format: $f, dir: $d}])'
}

rip_json_remove_output() { # rel dir
    [[ -n "$SESSION_DIR" && -f "$(session_json)" ]] || return 0
    jq_edit "$(session_json)" --arg d "$1" '.outputs = ((.outputs // []) | map(select(.dir != $d)))'
}

rip_json_rename_output() { # old rel dir, new rel dir
    [[ -n "$SESSION_DIR" && -f "$(session_json)" ]] || return 0
    jq_edit "$(session_json)" --arg o "$1" --arg n "$2" \
        '.outputs = ((.outputs // []) | map(if .dir == $o then .dir = $n else . end))'
}

# ----------------------------------------------------------------------------
# Work out what TARGET is. Sets SESSION_DIR, SRC_KIND and SRC_DIR.
#   - a RIP/<id> session folder (has rip.json)
#   - a folder of WAV files (its session folder is RIP/<name>, made on demand)
#   - a library folder of FLAC/M4A files (no session)
# ----------------------------------------------------------------------------
resolve_target() {
    local t="$TARGET" kind rel
    [[ -n "$t" ]] || die "No folder given. Pass a folder, or use --input-dir."
    [[ -d "$t" ]] || die "Folder not found: $t"
    t="$(cd "$t" && pwd)"

    if [[ -f "$t/rip.json" ]]; then
        SESSION_DIR="$t"
        kind="$(jq -r '.source // ""' "$t/rip.json")"
        case "$kind" in
            disc)
                SRC_KIND="flac"; SRC_DIR="$t/raw"
                if [[ ! -d "$t/raw" ]] || ! has_ext "$t/raw" flac; then
                    # The raw audio was removed after a verified encode: the FLAC
                    # master in the output tree is the lossless source now.
                    rel="$(jq -r '[.outputs[]? | select(.format == "flac") | .dir][0] // ""' "$t/rip.json")"
                    [[ -n "$rel" && -d "$OUT_DIR/$rel" ]] \
                        || die "No raw rip in $t and no FLAC folder recorded for it (was it moved or discarded?)."
                    SRC_DIR="$OUT_DIR/$rel"; RAW_GONE=1
                fi ;;
            wav)
                SRC_KIND="wav"
                SRC_DIR="${INPUT_DIR:-$(jq -r '.source_path // ""' "$t/rip.json")}"
                [[ -d "$SRC_DIR" ]] || die "The WAV folder for this session is not available ($SRC_DIR). Mount it and pass --input-dir."
                ;;
            *) die "Unknown source '$kind' in $t/rip.json" ;;
        esac
    elif has_ext "$t" wav; then
        SRC_KIND="wav"; SRC_DIR="$t"
        # Name + a fingerprint of the files, so two different discs that both sit in a
        # folder called "album" never share a session (release.json, outputs).
        SESSION_DIR="$OUT_DIR/RIP/$(sanitize "$(basename "$t")")-$(wav_fingerprint "$t")"
    elif has_ext "$t" flac m4a; then
        SRC_KIND="library"; SRC_DIR="$t"; SESSION_DIR=""
    else
        die "No audio files (.wav, .flac, .m4a) or rip.json found in $t"
    fi
    [[ -d "$SRC_DIR" ]] || die "Source folder not found: $SRC_DIR"
    return 0
}

# ----------------------------------------------------------------------------
# Read the audio files in SRC_DIR into the TRACK_* arrays, plus whatever
# album-level information their tags / names hold (FILE_*).
# ----------------------------------------------------------------------------
load_tracks() {
    local files=() f idx=0 n t ext first=1 tag key a
    local -A seen=()

    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(
        case "$SRC_KIND" in
            wav)     find "$SRC_DIR" -maxdepth 1 -type f -iname '*.wav' -print0 ;;
            flac)    find "$SRC_DIR" -maxdepth 1 -type f -iname '*.flac' -print0 ;;
            library) find "$SRC_DIR" -maxdepth 1 -type f \( -iname '*.flac' -o -iname '*.m4a' \) -print0 ;;
        esac | sort -zV
    )
    [[ ${#files[@]} -gt 0 ]] || die "No audio files found in $SRC_DIR"

    for f in "${files[@]}"; do
        idx=$((idx + 1))
        ext="${f##*.}"; ext="${ext,,}"
        n=""; t=""
        case "$ext" in
            flac) n="$(flac_tag "$f" TRACKNUMBER)"; t="$(flac_tag "$f" TITLE)" ;;
            m4a)  n="$(media_tag "$f" track)";      t="$(media_tag "$f" title)" ;;
        esac
        n="${n%%/*}"
        if [[ ! "$n" =~ ^[0-9]+$ ]]; then
            parse_track_name "$(basename "$f")" "$idx"
            n="$P_NUM"
            [[ -z "$t" ]] && t="$P_TITLE"
        fi
        TRACK_SRC+=("$f")
        TRACK_NUM+=("$((10#$n))")
        FILE_TITLE+=("$t")
        TRACK_DUR+=("$(media_duration "$f")")
        case "$ext" in
            flac) FILE_TRACK_ARTIST+=("$(flac_tag "$f" ARTIST)") ;;
            m4a)  FILE_TRACK_ARTIST+=("$(media_tag "$f" artist)") ;;
            *)    FILE_TRACK_ARTIST+=("") ;;
        esac
        key="$ext:$((10#$n))"
        if [[ -n "${seen[$key]:-}" ]]; then
            die "Two .$ext files have track number $((10#$n)): '$(basename "${seen[$key]}")' and '$(basename "$f")'.
  Is this more than one disc in the same folder? Put each disc in its own folder."
        fi
        seen[$key]="$f"

        if [[ $first -eq 1 ]]; then
            first=0
            case "$ext" in
                flac)
                    FILE_ALBUM="$(flac_tag "$f" ALBUM)"
                    FILE_ARTIST="$(flac_tag "$f" ALBUMARTIST)"
                    [[ -z "$FILE_ARTIST" ]] && FILE_ARTIST="$(flac_tag "$f" ALBUM_ARTIST)"
                    tag="$(flac_tag "$f" DATE)"; FILE_YEAR="${tag:0:4}"
                    tag="$(flac_tag "$f" DISCNUMBER)"
                    if [[ "$tag" =~ ^([0-9]+)(/([0-9]+))?$ ]]; then
                        FILE_DISC="${BASH_REMATCH[1]}"; FILE_TOTAL_DISCS="${BASH_REMATCH[3]:-}"
                    fi
                    if [[ -z "$FILE_TOTAL_DISCS" ]]; then
                        tag="$(flac_tag "$f" DISCTOTAL)"
                        [[ -z "$tag" ]] && tag="$(flac_tag "$f" TOTALDISCS)"
                        [[ "$tag" =~ ^[0-9]+$ ]] && FILE_TOTAL_DISCS="$tag"
                    fi
                    ;;
                m4a)
                    FILE_ALBUM="$(media_tag "$f" album)"
                    FILE_ARTIST="$(media_tag "$f" album_artist)"
                    tag="$(media_tag "$f" date)"; FILE_YEAR="${tag:0:4}"
                    tag="$(media_tag "$f" disc)"
                    if [[ "$tag" =~ ^([0-9]+)(/([0-9]+))?$ ]]; then
                        FILE_DISC="${BASH_REMATCH[1]}"; FILE_TOTAL_DISCS="${BASH_REMATCH[3]:-}"
                    fi
                    ;;
            esac
            [[ "$FILE_YEAR" =~ ^[0-9]{4}$ ]] || FILE_YEAR=""
        fi
    done

    # No album artist tag: the track artists decide. One artist = that artist;
    # several different ones = a compilation.
    if [[ -z "$FILE_ARTIST" ]]; then
        for a in "${FILE_TRACK_ARTIST[@]}"; do
            [[ -n "$a" ]] || continue
            if [[ -z "$FILE_ARTIST" ]]; then FILE_ARTIST="$a"
            elif [[ "$a" != "$FILE_ARTIST" ]]; then FILE_ARTIST="Various Artists"; break
            fi
        done
    fi

    # Raw rips live in a folder called "raw": nothing to learn from its name.
    [[ "$SRC_KIND" == "flac" ]] || parse_folder_name "$SRC_DIR"
    [[ "$SRC_KIND" == "flac" ]] || find_cover "$SRC_DIR"
    return 0
}

# ----------------------------------------------------------------------------
# release.json -> RJ_* (the matched MusicBrainz release, if one was saved)
# ----------------------------------------------------------------------------
read_release_file() { # file -> RJ_*
    local f="$1" n t a
    RJ_TITLE=(); RJ_ARTIST_OF=()

    RJ_ARTIST="$(jq -r '.artist // ""' "$f")"
    RJ_ALBUM="$(jq -r '.album // ""' "$f")"
    RJ_YEAR="$(jq -r '.year // ""' "$f")"
    RJ_DISC="$(jq -r '.disc // ""' "$f")"
    RJ_TOTAL_DISCS="$(jq -r '.total_discs // ""' "$f")"
    RJ_MBID="$(jq -r '.mb_release // ""' "$f")"
    RJ_BARCODE="$(jq -r '.barcode // ""' "$f")"
    RJ_METHOD="$(jq -r '.method // ""' "$f")"
    while IFS=$'\t' read -r n t a; do
        [[ -n "$n" ]] || continue
        RJ_TITLE[$n]="$t"
        [[ -n "$a" ]] && RJ_ARTIST_OF[$n]="$a"
    done < <(jq -r '.tracks[]? | "\(.n)\t\(.title)\t\(.artist // "")"' "$f")
    return 0
}

# Track lengths of the files in track-number order, as a JSON array.
files_durations_json() {
    local i
    for i in "${!TRACK_SRC[@]}"; do printf '%s %s\n' "${TRACK_NUM[$i]}" "${TRACK_DUR[$i]:-null}"; done \
        | sort -n | awk '{print $2}' | jq -s -c 'map(if . == "null" then null else tonumber end)'
}

# Does a saved release.json belong to these files? Same track count, and track
# lengths within tolerance where the release recorded them (loose: Discogs
# times are user-entered).
RELEASE_FIT_TOLERANCE=6
release_fits_files() { # release.json
    jq -e --argjson n "${#TRACK_SRC[@]}" --argjson durs "$(files_durations_json)" --argjson tol "$RELEASE_FIT_TOLERANCE" '
        (.tracks // []) as $t
        | ($t | length) == $n
          and ([$t | to_entries[]
                | select(.value.len != null and $durs[.key] != null
                         and ((.value.len - $durs[.key]) | fabs) > $tol)] | length) == 0' "$1" >/dev/null 2>&1
}

load_release_json() {
    [[ -n "$SESSION_DIR" && -f "$SESSION_DIR/release.json" ]] || return 0
    if ! release_fits_files "$SESSION_DIR/release.json"; then
        echo "Note: ignoring $SESSION_DIR/release.json: it does not fit these files (track count or lengths differ). Run match again for them." >&2
        return 0
    fi
    read_release_file "$SESSION_DIR/release.json"
    [[ -f "$SESSION_DIR/cover.img" ]] && COVER="$SESSION_DIR/cover.img"
    return 0
}

# Combine file info, release.json and flags: flags win, then release.json,
# then what the files say.
finalize_metadata() {
    local i n a
    ARTIST="${ARG_ARTIST:-${RJ_ARTIST:-$FILE_ARTIST}}"
    ALBUM="${ARG_ALBUM:-${RJ_ALBUM:-$FILE_ALBUM}}"
    YEAR="${ARG_YEAR:-${RJ_YEAR:-$FILE_YEAR}}"
    DISC="${ARG_DISC:-${RJ_DISC:-$FILE_DISC}}"
    TOTAL_DISCS="${ARG_TOTAL_DISCS:-${RJ_TOTAL_DISCS:-$FILE_TOTAL_DISCS}}"
    TRACK_TITLE=(); TRACK_ARTIST=()
    for i in "${!TRACK_SRC[@]}"; do
        n="${TRACK_NUM[$i]}"
        TRACK_TITLE+=("${RJ_TITLE[$n]:-${FILE_TITLE[$i]}}")
        # --artist beats the release, which beats what the file already says.
        a="${FILE_TRACK_ARTIST[$i]:-}"
        [[ -n "${RJ_ARTIST_OF[$n]:-}" ]] && a="${RJ_ARTIST_OF[$n]}"
        [[ -n "$ARG_ARTIST" ]] && a="$ARG_ARTIST"
        TRACK_ARTIST+=("$a")
    done
    return 0
}

require_known_disc() {
    if [[ -n "$TOTAL_DISCS" && "$((10#$TOTAL_DISCS))" -gt 1 && -z "$DISC" ]]; then
        die "This is a multi-disc release ($TOTAL_DISCS discs) but the disc number is unknown. Pass --disc <n> (e.g. --disc 2/$TOTAL_DISCS)."
    fi
}

load_all() { # resolve target, read files, read release.json, merge metadata
    reset_state
    resolve_target
    load_tracks
    load_release_json
    finalize_metadata
}
