# shellcheck shell=bash
# Rip stage: read the disc into <out>/RIP/<id>/ and record the facts.
# It never looks anything up, so a metadata failure can never cost a rip.

# Best effort: the MusicBrainz disc ID, from `cyanrip -I` (info only, no rip).
# Prints the ID, or nothing if cyanrip does not show one. Output kept in $1.
capture_discid() {
    local out_file="$1" out
    out="$(timeout 90 cyanrip -d "$DEVICE" -I 2>&1)" || true
    printf '%s\n' "$out" > "$out_file"
    printf '%s' "$out" | grep -aoiE 'disc ?id[^A-Za-z0-9]{1,4}[A-Za-z0-9._-]{28}([^A-Za-z0-9._-]|$)' \
        | head -n 1 | grep -aoE '[A-Za-z0-9._-]{28}' | head -n 1 || true
}

cmd_rip() {
    need_tools cyanrip flac metaflac jq ffprobe
    echo "=== Rip: optical drive ($DEVICE) ==="
    resolve_offset

    local info="$WORK_DIR/disc-info.txt" discid id args f n=0 dur
    discid="$(capture_discid "$info")"
    id="${discid:-$(date +%Y%m%d-%H%M%S)}"
    SESSION_DIR="$OUT_DIR/RIP/$id"
    [[ -e "$SESSION_DIR" ]] && SESSION_DIR="$SESSION_DIR-$(date +%H%M%S)"
    mkdir -p "$SESSION_DIR"
    cp "$info" "$SESSION_DIR/disc-info.txt" 2>/dev/null || true
    echo "Rip folder: $SESSION_DIR"
    [[ -n "$discid" ]] && echo "Disc ID: $discid"

    # -N: no MusicBrainz lookup, so metadata can never make the rip fail.
    args=(-d "$DEVICE" -s "$OFFSET" -o flac -D raw -F "{track}" -L rip -M rip -N)
    [[ -n "$ARG_DISC" && -n "$ARG_TOTAL_DISCS" ]] && args+=(-c "$ARG_DISC/$ARG_TOTAL_DISCS")
    if ! (cd "$SESSION_DIR" && cyanrip "${args[@]}") 2>&1 | tee "$SESSION_DIR/cyanrip-output.txt"; then
        die "cyanrip failed. Output is in $SESSION_DIR/cyanrip-output.txt"
    fi

    local flacs=()
    while IFS= read -r -d '' f; do flacs+=("$f"); done \
        < <(find "$SESSION_DIR/raw" -maxdepth 1 -type f -name '*.flac' -print0 2>/dev/null | sort -zV)
    [[ ${#flacs[@]} -gt 0 ]] || die "cyanrip produced no FLAC files (see $SESSION_DIR/cyanrip-output.txt)"

    echo ""
    check_verification "$SESSION_DIR/cyanrip-output.txt"

    local tracks_json
    tracks_json="$(for f in "${flacs[@]}"; do
        n=$((n + 1)); dur="$(media_duration "$f")"
        printf '%s\t%s\t%s\n' "$n" "$(basename "$f")" "${dur:-0}"
    done | jq -R -s -c 'split("\n") | map(select(. != "") | split("\t") | {n: (.[0] | tonumber), file: .[1], duration: (.[2] | tonumber)})')"

    jq -n --arg device "$DEVICE" --arg drive "$(drive_id)" --arg offset "$OFFSET" \
        --arg osrc "$OFFSET_SOURCE" --arg verify "$VERIFY_STATUS" --arg discid "$discid" \
        --arg created "$(date -u +%FT%TZ)" --argjson tracks "$tracks_json" \
        '{version: 1, source: "disc", device: $device, drive: $drive,
          offset: ($offset | tonumber), offset_source: $osrc, verify: $verify,
          discid: $discid, created: $created, tracks: $tracks, outputs: []}' \
        > "$SESSION_DIR/rip.json"

    if [[ "$VERIFY_STATUS" == "failed" && $ALLOW_UNVERIFIED -eq 0 ]]; then
        die "AccurateRip did not verify every track, so the rip is not trusted.
  Likely causes: wrong drive offset (used $OFFSET, from $OFFSET_SOURCE), a damaged disc,
  or a different pressing than the database holds.
  The rip is kept in $SESSION_DIR. Try --find-offset, clean the disc and rip again,
  or accept it: cd-ripper.sh encode $SESSION_DIR --allow-unverified"
    fi
    if [[ "$VERIFY_STATUS" == "verified" && "$OFFSET_SOURCE" == "db" ]]; then
        cache_put_offset "$(drive_id)" "$OFFSET"
    fi

    echo ""
    echo "✔ Rip saved: $SESSION_DIR  (${#flacs[@]} tracks, AccurateRip: $VERIFY_STATUS)"
    return 0
}

cmd_find_offset() {
    need_tools cyanrip
    local id found
    id="$(drive_id)"
    echo "Drive: ${id:-<unknown>}"
    found="$(measure_offset)"
    [[ -n "$found" ]] || die "Could not measure the offset. The inserted disc must be in the AccurateRip database."
    cache_put_offset "$id" "$found"
    echo ""
    echo "Drive offset: $found (saved to $(offset_cache_file))"
    echo "Use --offset $found to pass it explicitly."
}
