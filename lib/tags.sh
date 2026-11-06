# shellcheck shell=bash
# Writing tags into FLAC and M4A files. One code path used by both `encode`
# (fresh files) and `update` (existing files), so they can never disagree.
# Reads the merged metadata globals: ARTIST ALBUM YEAR DISC TOTAL_DISCS
# TRACK_NUM TRACK_TITLE COVER.

# Tags we own; anything else (e.g. ReplayGain from cyanrip) is left alone.
FLAC_OWNED_TAGS=(TITLE ARTIST ALBUMARTIST ALBUM_ARTIST ALBUM DATE TRACKNUMBER
                 TRACKTOTAL TOTALTRACKS DISCNUMBER DISCTOTAL TOTALDISCS DISC)

write_flac_tags() { # file, track index, track total
    local f="$1" i="$2" total="$3" t ta="${TRACK_ARTIST[$2]:-$ARTIST}"
    local rm=() set=()

    for t in "${FLAC_OWNED_TAGS[@]}"; do rm+=(--remove-tag="$t"); done
    metaflac "${rm[@]}" "$f"

    set+=(--set-tag="TRACKNUMBER=$((10#${TRACK_NUM[$i]}))" --set-tag="TRACKTOTAL=$total")
    [[ -n "${TRACK_TITLE[$i]}" ]] && set+=(--set-tag="TITLE=${TRACK_TITLE[$i]}")
    [[ -n "$ta" ]]     && set+=(--set-tag="ARTIST=$ta")
    [[ -n "$ARTIST" ]] && set+=(--set-tag="ALBUMARTIST=$ARTIST")
    [[ -n "$ALBUM" ]]  && set+=(--set-tag="ALBUM=$ALBUM")
    [[ -n "$YEAR" ]]   && set+=(--set-tag="DATE=$YEAR")
    if is_multidisc; then
        set+=(--set-tag="DISCNUMBER=$((10#$DISC))")
        [[ -n "$TOTAL_DISCS" ]] && set+=(--set-tag="DISCTOTAL=$((10#$TOTAL_DISCS))")
    fi
    metaflac "${set[@]}" "$f"

    if [[ -n "$COVER" && -f "$COVER" ]]; then
        metaflac --remove --block-type=PICTURE "$f"
        metaflac --import-picture-from="$COVER" "$f"
    fi
}

write_m4a_tags() { # file, track index, track total
    local f="$1" i="$2" total="$3" ta="${TRACK_ARTIST[$2]:-$ARTIST}"
    local args=(--tracknum "$((10#${TRACK_NUM[$i]}))/$total")

    args+=(--title "${TRACK_TITLE[$i]}")
    args+=(--artist "$ta" --albumArtist "$ARTIST")
    args+=(--album "$ALBUM")
    args+=(--year "$YEAR")
    if is_multidisc; then
        args+=(--disk "$((10#$DISC))${TOTAL_DISCS:+/$((10#$TOTAL_DISCS))}")
    fi
    AtomicParsley "$f" "${args[@]}" --overWrite >/dev/null

    if [[ -n "$COVER" && -f "$COVER" ]]; then
        AtomicParsley "$f" --artwork REMOVE_ALL --overWrite >/dev/null
        AtomicParsley "$f" --artwork "$COVER" --overWrite >/dev/null
    fi
}
