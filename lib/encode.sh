# shellcheck shell=bash
# Encode stage: raw rip (or WAV folder) -> FLAC master and/or AAC.
# Metadata comes from release.json + flags + file names; if there is none the
# files still get encoded with placeholder names and can be fixed afterwards
# with `update`, with no re-encode.

SESSION_MARKER=".cd-ripper-session"

# Relative path (under OUT_DIR) for this release's folder under FLAC or AAC.
# If another session already owns that name (e.g. two unknown discs), append
# this session's id so nothing is overwritten.
deliverable_rel() { # top folder name: FLAC | AAC
    local top="$1" rel dir me
    rel="$top/$(album_rel_dir)"
    dir="$OUT_DIR/$rel"
    me="$(basename "$SESSION_DIR")"
    if [[ -f "$dir/$SESSION_MARKER" && "$(cat "$dir/$SESSION_MARKER")" != "$me" ]]; then
        rel="$rel ($me)"
    fi
    printf '%s' "$rel"
}

# Remove what an earlier encode of this session left for a format, so a
# re-encode with better metadata does not leave stale folders behind.
clean_previous_outputs() { # format (flac|aac)
    local fmt="$1" d me
    [[ -f "$(session_json)" ]] || return 0
    me="$(basename "$SESSION_DIR")"
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        if [[ -f "$OUT_DIR/$d/$SESSION_MARKER" && "$(cat "$OUT_DIR/$d/$SESSION_MARKER")" == "$me" ]]; then
            rm -rf "${OUT_DIR:?}/$d"
            echo "Removed previous output: $d"
        fi
        rip_json_remove_output "$d"
    done < <(jq -r --arg f "$fmt" '.outputs[]? | select(.format == $f) | .dir' "$(session_json)")
    return 0
}

# Rewrite the FILE lines of a cue sheet by position: the i-th FILE line becomes
# "../../<i-th name>", the track beside extras/rip/. Works on the first encode and
# on every later rename, because it never depends on the old names.
rewrite_cue_files() { # cue file, final track file names...
    local cue="$1" line out="" i=0; shift
    local names=("$@")
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $i -lt ${#names[@]} && "$line" =~ ^([[:space:]]*FILE[[:space:]]+)\"[^\"]*\"(.*)$ ]]; then
            line="${BASH_REMATCH[1]}\"../../${names[$i]}\"${BASH_REMATCH[2]}"
            i=$((i + 1))
        fi
        out+="$line"$'\n'
    done < "$cue"
    printf '%s' "$out" > "$cue"
}

cover_ext() { # cover file -> png | jpg
    case "${1,,}" in *.png) printf png ;; *) printf jpg ;; esac
}

# Store the rip evidence ONCE, inside an album folder, so it travels with the
# music: extras/rip/ (log, cue, cyanrip output, disc info) and extras/release/
# (cover). The session originals are removed by remove_raw, only once the
# FLAC master is verified, so a failed run never loses them. For a FLAC
# folder the cue's FILE names are pointed at the tracks; for the AAC folder
# (only when the FLAC is discarded) the cue is kept as it is.
write_extras() { # album dir, flac|m4a
    local dir="$1" ext="$2" ex="$1/extras" f names=() i cue
    [[ "$SRC_KIND" == "flac" && $RAW_GONE -eq 0 ]] || return 0
    mkdir -p "$ex/rip"
    while IFS= read -r -d '' f; do cp "$f" "$ex/rip/$(basename "$f")"; done < <(report_files)
    if [[ "$ext" == "flac" ]]; then
        for i in "${!TRACK_SRC[@]}"; do names+=("$(track_basename "$i").flac"); done
        for cue in "$ex"/rip/*.cue; do
            [[ -f "$cue" ]] && rewrite_cue_files "$cue" "${names[@]}"
        done
    fi
    if [[ -n "$COVER" && -f "$COVER" ]]; then
        mkdir -p "$ex/release"
        cp "$COVER" "$ex/release/cover.$(cover_ext "$COVER")"
    fi
}

# Everything that documents the rip: every non-audio file cyanrip left next to
# the tracks (log, cue, whatever it calls them) plus its console output and the
# disc info. NUL-separated. Matching by "not a .flac" rather than by name means a
# different file name on a real drive cannot make a report get left behind.
report_files() {
    local f
    if [[ -d "$SESSION_DIR/raw" ]]; then
        find "$SESSION_DIR/raw" -maxdepth 1 -type f ! -iname '*.flac' -print0
    fi
    for f in cyanrip-output.txt disc-info.txt; do
        if [[ -f "$SESSION_DIR/$f" ]]; then printf '%s\0' "$SESSION_DIR/$f"; fi
    done
    return 0
}

# Delete the raw FLACs once every track has a verified FLAC in the master
# folder, together with the originals of the reports copied by write_extras.
# --keep-raw skips it.
remove_raw() {
    local n_out f
    [[ "$SRC_KIND" == "flac" && $RAW_GONE -eq 0 && $KEEP_RAW -eq 0 ]] || return 0
    n_out="$(find "$OUT_DIR/$MASTER_REL" -maxdepth 1 -type f -name '*.flac' | wc -l)"
    if [[ "$((n_out))" -ne "${#TRACK_SRC[@]}" ]]; then
        echo "Keeping the raw rip: expected ${#TRACK_SRC[@]} FLAC files in $MASTER_REL, found $((n_out))."
        return 0
    fi
    local reports=()
    while IFS= read -r -d '' f; do reports+=("$f"); done < <(report_files)
    rm -f "${TRACK_SRC[@]}" ${reports[@]+"${reports[@]}"}
    rmdir "$SESSION_DIR/raw" 2>/dev/null || true
    echo "Removed the raw FLAC copy (the verified FLAC in $MASTER_REL replaces it)."
}

encode_flac_master() {
    local rel dir total i dst
    total=${#TRACK_SRC[@]}
    clean_previous_outputs flac
    rel="$(deliverable_rel FLAC)"
    dir="$OUT_DIR/$rel"
    mkdir -p "$dir"
    printf '%s' "$(basename "$SESSION_DIR")" > "$dir/$SESSION_MARKER"

    echo ""
    echo "=== Encoding FLAC (flac -8 --verify) -> $dir ==="
    MASTER_FILES=()
    for i in "${!TRACK_SRC[@]}"; do
        dst="$dir/$(track_basename "$i").flac"
        echo "  $(basename "$dst")"
        flac "${FLAC_ARGS[@]}" -o "$dst" "${TRACK_SRC[$i]}"
        write_flac_tags "$dst" "$i" "$total"
        MASTER_FILES+=("$dst")
    done
    MASTER_REL="$rel"
    rip_json_add_output flac "$rel"
}

encode_aac_from_master() {
    local rel dir total i dst
    total=${#MASTER_FILES[@]}
    clean_previous_outputs aac
    rel="$(deliverable_rel AAC)"
    dir="$OUT_DIR/$rel"
    mkdir -p "$dir"
    printf '%s' "$(basename "$SESSION_DIR")" > "$dir/$SESSION_MARKER"

    echo ""
    echo "=== Encoding AAC from the FLAC master (fdkaac VBR 5) -> $dir ==="
    for i in "${!MASTER_FILES[@]}"; do
        dst="$dir/$(track_basename "$i").m4a"
        echo "  $(basename "$dst")"
        flac -d -c -s "${MASTER_FILES[$i]}" | fdkaac "${FDK_ARGS[@]}" -o "$dst" -
        write_m4a_tags "$dst" "$i" "$total"
    done
    AAC_REL="$rel"
    rip_json_add_output aac "$rel"
}

discard_master() {
    echo ""
    echo "=== Discarding the FLAC master (--discard-master) ==="
    rm -rf "${OUT_DIR:?}/$MASTER_REL"
    rip_json_remove_output "$MASTER_REL"
    # Remove the now-empty FLAC/ folder, if it is.
    rmdir "$OUT_DIR/FLAC" 2>/dev/null || true
}

cmd_encode() {
    need_tools flac metaflac jq ffprobe
    [[ "$FORMAT" == "aac" ]] && need_tools fdkaac AtomicParsley
    if [[ $DISCARD_MASTER -eq 1 && "$FORMAT" != "aac" ]]; then
        die "--discard-master only makes sense with --format aac"
    fi

    load_all
    [[ "$SRC_KIND" != "library" ]] || die "encode needs a RIP/<id> folder or a folder of WAV files, not already-encoded files. To fix tags on those, use: update"
    [[ "$SRC_KIND" == "flac" && ! -f "$(session_json)" ]] && die "Not a rip folder (no rip.json): $SRC_DIR"
    ensure_session
    require_known_disc

    if [[ "$SRC_KIND" == "flac" ]] \
        && [[ "$(jq -r '.verify // ""' "$(session_json)")" == "failed" && $ALLOW_UNVERIFIED -eq 0 ]]; then
        die "This rip did not verify against AccurateRip. Re-rip, or encode it anyway with --allow-unverified."
    fi

    echo "=== Encode: $SESSION_DIR ==="
    echo "Artist: ${ARTIST:-<unknown>}"
    echo "Album:  ${ALBUM:-<unknown>}"
    echo "Year:   ${YEAR:-<unknown>}"
    is_multidisc && echo "Disc:   $((10#$DISC))${TOTAL_DISCS:+ of $TOTAL_DISCS}"
    if [[ -z "$ARTIST" || -z "$ALBUM" ]]; then
        echo ""
        echo "No artist/album known: using placeholder names. Fix later without re-encoding:"
        echo "  cd-ripper.sh update \"$SESSION_DIR\" --barcode <digits> --apply"
    fi

    MASTER_FILES=(); MASTER_REL=""; AAC_REL=""
    if [[ $RAW_GONE -eq 1 ]]; then
        # The raw rip was removed earlier: the FLAC master already exists and is
        # the only lossless copy. Never re-encode (or delete) it here.
        [[ "$FORMAT" == "aac" ]] || die "The FLAC master already exists in $SRC_DIR. To change its tags or names use: update"
        [[ $DISCARD_MASTER -eq 0 ]] || die "--discard-master must be given in the run that encodes the AAC, while the rip evidence can still move to the AAC folder."
        MASTER_FILES=("${TRACK_SRC[@]}")
        MASTER_REL="${SRC_DIR#"$OUT_DIR"/}"
        echo ""
        echo "Using the existing FLAC master: $SRC_DIR"
        encode_aac_from_master
    else
        encode_flac_master
        [[ "$FORMAT" == "aac" ]] && encode_aac_from_master
        if [[ $DISCARD_MASTER -eq 1 ]]; then
            write_extras "$OUT_DIR/$AAC_REL" m4a
        else
            write_extras "$OUT_DIR/$MASTER_REL" flac
        fi
        remove_raw
        [[ $DISCARD_MASTER -eq 1 ]] && discard_master
    fi

    echo ""
    echo "=========================================="
    echo "✔ Done"
    echo "=========================================="
    if [[ "$FORMAT" == "aac" ]]; then
        echo "AAC:  $OUT_DIR/$AAC_REL"
        [[ $DISCARD_MASTER -eq 1 ]] || echo "FLAC: $OUT_DIR/$MASTER_REL"
    else
        echo "FLAC: $OUT_DIR/$MASTER_REL"
    fi
    echo "Rip state: $SESSION_DIR  (rip.json / release.json only; the audio and reports are in the album folder)"
    return 0
}
