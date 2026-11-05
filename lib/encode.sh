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

# Copy the rip evidence into <album folder>/extras/ so it travels with the music
# when the folder is moved into a library. Only for disc rips. The originals stay
# in RIP/<id>/. For FLAC the cue sheet's FILE names are rewritten to the final
# track names (one level up, "../"); for AAC the cue is copied unchanged because
# it describes the lossless rip, not the .m4a files.
write_extras() { # album dir, ext (flac|m4a)
    local dir="$1" ext="$2" ex="$1/extras" i raw new cue
    [[ "$SRC_KIND" == "flac" && -d "$SESSION_DIR/raw" ]] || return 0
    mkdir -p "$ex"
    [[ -f "$SESSION_DIR/raw/rip.log" ]] && cp "$SESSION_DIR/raw/rip.log" "$ex/rip.log"
    [[ -f "$SESSION_DIR/cyanrip-output.txt" ]] && cp "$SESSION_DIR/cyanrip-output.txt" "$ex/cyanrip-output.txt"
    if [[ -f "$SESSION_DIR/raw/rip.cue" ]]; then
        cue="$(<"$SESSION_DIR/raw/rip.cue")"
        if [[ "$ext" == "flac" ]]; then
            for i in "${!TRACK_SRC[@]}"; do
                raw="$(basename "${TRACK_SRC[$i]}")"
                new="$(track_basename "$i").flac"
                cue="${cue//\"$raw\"/\"../$new\"}"
            done
        fi
        printf '%s\n' "$cue" > "$ex/rip.cue"
    fi
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
    write_extras "$dir" flac
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
    write_extras "$dir" m4a
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
        echo "AAC:  $OUT_DIR/$AAC_REL"
        [[ $DISCARD_MASTER -eq 1 ]] || echo "FLAC: $OUT_DIR/$MASTER_REL"
    else
        echo "FLAC: $OUT_DIR/$MASTER_REL"
    fi
    echo "Rip folder: $SESSION_DIR"
    return 0
}
