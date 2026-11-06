# shellcheck shell=bash
# match: find the right release for a rip / folder and show what it would change.
# update: write metadata into existing FLAC/M4A files (tags, cover, names)
#         in place, without re-encoding. Preview unless --apply.

index_for_track() { # track number -> index into TRACK_* (empty if none)
    local i
    for i in "${!TRACK_NUM[@]}"; do
        if [[ "${TRACK_NUM[$i]}" == "$1" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 0
}

file_track_number() { # file -> track number
    local f="$1" ext n=""
    ext="${f##*.}"; ext="${ext,,}"
    case "$ext" in
        flac) n="$(flac_tag "$f" TRACKNUMBER)" ;;
        m4a)  n="$(media_tag "$f" track)" ;;
    esac
    n="${n%%/*}"
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then
        parse_track_name "$(basename "$f")" 0
        n="$P_NUM"
    fi
    printf '%s' "$((10#$n))"
}

# After the tracks were renamed: point the cue sheet in extras/rip/ at the new
# names, and refresh extras/release/cover from the current cover.
refresh_extras() { # album dir
    local dir="$1" i names=() f
    if compgen -G "$dir/extras/rip/*.cue" >/dev/null && compgen -G "$dir/*.flac" >/dev/null; then
        while IFS= read -r -d '' f; do
            i="$(index_for_track "$(file_track_number "$f")")"
            [[ -n "$i" ]] && names+=("$(basename "$f")")
        done < <(find "$dir" -maxdepth 1 -type f -iname '*.flac' -print0 | sort -zV)
        if [[ ${#names[@]} -gt 0 ]]; then
            for f in "$dir"/extras/rip/*.cue; do rewrite_cue_files "$f" "${names[@]}"; done
        fi
    fi
    if [[ -n "$COVER" && -f "$COVER" && -d "$dir/extras/release" ]]; then
        rm -f "$dir"/extras/release/cover.*
        cp "$COVER" "$dir/extras/release/cover.$(cover_ext "$COVER")"
    fi
    return 0
}

# Retag and rename the FLAC/M4A files in one folder, then the folder itself.
apply_to_dir() { # dir
    local dir="$1" f ext n i newbase newpath total old_rel new_rel newdir files=()
    total=${#TRACK_SRC[@]}

    while IFS= read -r -d '' f; do files+=("$f"); done \
        < <(find "$dir" -maxdepth 1 -type f \( -iname '*.flac' -o -iname '*.m4a' \) -print0 | sort -zV)
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "  (no FLAC/M4A files in $dir)"
        return 0
    fi

    echo ""
    echo "Folder: $dir"
    for f in "${files[@]}"; do
        ext="${f##*.}"; ext="${ext,,}"
        n="$(file_track_number "$f")"
        i="$(index_for_track "$n")"
        if [[ -z "$i" ]]; then
            echo "  skip (the metadata has no track $n): $(basename "$f")"
            continue
        fi
        newbase="$(track_basename "$i")"
        newpath="$dir/$newbase.$ext"

        if [[ $APPLY -eq 1 ]]; then
            case "$ext" in
                flac) write_flac_tags "$f" "$i" "$total" ;;
                m4a)  write_m4a_tags "$f" "$i" "$total" ;;
            esac
        fi
        if [[ "$f" == "$newpath" ]]; then
            echo "  $(basename "$f")   (name unchanged)"
        elif [[ -e "$newpath" ]]; then
            echo "  $(basename "$f") -> $newbase.$ext   SKIPPED: that name already exists"
        else
            echo "  $(basename "$f") -> $newbase.$ext"
            [[ $APPLY -eq 1 ]] && mv "$f" "$newpath"
        fi
    done

    # Keep extras/ in step with the new names (cue FILE lines, cover).
    [[ $APPLY -eq 1 ]] && refresh_extras "$dir"

    newdir="$(dirname "$dir")/$(album_rel_dir)"
    if [[ "$newdir" != "$dir" && "$SRC_KIND" == "library" && $RENAME_FOLDER -eq 0 ]]; then
        echo "  folder kept: $(basename "$dir")   (add --rename-folder to rename it to $(basename "$newdir"))"
    elif [[ "$newdir" != "$dir" ]]; then
        if [[ -e "$newdir" ]]; then
            echo "  folder rename SKIPPED: $(basename "$newdir") already exists"
        else
            echo "  folder: $(basename "$dir") -> $(basename "$newdir")"
            if [[ $APPLY -eq 1 ]]; then
                if mv "$dir" "$newdir"; then
                    old_rel="${dir#"$OUT_DIR"/}"; new_rel="${newdir#"$OUT_DIR"/}"
                    rip_json_rename_output "$old_rel" "$new_rel"
                else
                    echo "  warning: could not rename the folder (is it a mount point? mount its parent instead)"
                fi
            fi
        fi
    fi
    return 0
}

show_effective_metadata() {
    echo ""
    echo "Metadata to apply:"
    printf '  %-8s %s\n' "Artist:" "${ARTIST:-<unknown>}"
    printf '  %-8s %s\n' "Album:"  "${ALBUM:-<unknown>}"
    printf '  %-8s %s\n' "Year:"   "${YEAR:-<unknown>}"
    is_multidisc && printf '  %-8s %s\n' "Disc:" "$((10#$DISC))${TOTAL_DISCS:+ of $TOTAL_DISCS}"
    return 0
}

# Run the lookup and merge the chosen release into the current state.
# Returns mb_resolve's status (0 chosen, 2 none, 3 ambiguous).
match_into_state() {
    local rc=0
    mb_resolve || rc=$?
    [[ $rc -eq 0 ]] || return "$rc"
    read_release_file "$WORK_DIR/chosen.json"
    return 0
}

save_release() { # write release.json (+ cover) into the session
    [[ -n "$SESSION_DIR" ]] || return 0
    ensure_session
    cp "$WORK_DIR/chosen.json" "$SESSION_DIR/release.json"
    rm -f "$SESSION_DIR/cover.img"      # never keep the previous release's cover
    local got=1
    if [[ "$(jq -r '.source // "musicbrainz"' "$WORK_DIR/chosen.json")" == "discogs" ]]; then
        dg_fetch_cover "$(jq -r '.cover_url // ""' "$WORK_DIR/chosen.json")" "$SESSION_DIR/cover.img" && got=0
    else
        mb_fetch_cover "$(jq -r .mb_release "$WORK_DIR/chosen.json")" "$SESSION_DIR/cover.img" && got=0
    fi
    if [[ $got -eq 0 ]]; then
        COVER="$SESSION_DIR/cover.img"
        echo "Cover art saved."
    else
        echo "No cover art found for that release."
    fi
    echo "Saved: $SESSION_DIR/release.json"
}

cmd_match() {
    need_tools jq curl ffprobe
    ALLOW_TEXT=1
    load_all
    echo "=== Match: $TARGET ==="
    local rc=0
    match_into_state || rc=$?
    case "$rc" in
        0) ;;
        3) exit 3 ;;
        *) echo ""; echo "No match. Try --barcode (back of the case), --mb-release <id>, or --artist/--album."; exit 2 ;;
    esac
    finalize_metadata
    print_match_preview "$WORK_DIR/chosen.json"

    if [[ $SAVE -eq 1 ]]; then
        [[ -n "$SESSION_DIR" ]] || die "--save needs a RIP/<id> folder or a WAV folder. For existing FLAC/M4A files use: update --apply"
        save_release
        echo "Next: cd-ripper.sh update \"$SESSION_DIR\" --apply   (fix existing files)"
        echo "  or: cd-ripper.sh encode \"$SESSION_DIR\" --format aac   (encode with this metadata)"
    else
        echo ""
        echo "Preview only. Add --save to write release.json."
    fi
    return 0
}

cmd_update() {
    need_tools jq ffprobe metaflac AtomicParsley
    load_all

    local want_match=0 rc=0 dirs=() d rel chosen=0
    if [[ -n "$ARG_MBID" || -n "$ARG_DGID" || -n "$ARG_BARCODE" || -n "$ARG_DISCID" || $LOOKUP -eq 1 ]]; then
        want_match=1
    elif [[ -n "$SESSION_DIR" && -f "$(session_json)" && ! -f "$SESSION_DIR/release.json" \
            && -n "$(jq -r '.discid // ""' "$(session_json)")" ]]; then
        want_match=1
    fi

    echo "=== Update: $TARGET ==="
    if [[ $want_match -eq 1 ]]; then
        need_tools curl
        ALLOW_TEXT=$LOOKUP
        match_into_state || rc=$?
        case "$rc" in
            0) chosen=1; finalize_metadata; print_match_preview "$WORK_DIR/chosen.json" ;;
            3) exit 3 ;;
            *) echo ""; echo "No match; nothing changed."; exit 2 ;;
        esac
    fi
    require_known_disc

    # Where are the files to change?
    if [[ "$SRC_KIND" == "library" ]]; then
        dirs=("$SRC_DIR")
    else
        while IFS= read -r rel; do
            [[ -n "$rel" && -d "$OUT_DIR/$rel" ]] && dirs+=("$OUT_DIR/$rel")
        done < <(jq -r '.outputs[]? | .dir' "$(session_json)")
    fi

    show_effective_metadata
    if [[ $chosen -eq 1 && $APPLY -eq 1 ]]; then
        save_release
    fi
    if [[ ${#dirs[@]} -eq 0 ]]; then
        echo ""
        echo "No encoded files recorded for this rip yet. Run: cd-ripper.sh encode \"$SESSION_DIR\" --format flac|aac"
    fi
    for d in "${dirs[@]}"; do
        apply_to_dir "$d"
    done

    echo ""
    if [[ $APPLY -eq 1 ]]; then
        echo "✔ Updated."
    else
        echo "Preview only, nothing was changed. Add --apply to write it."
    fi
    return 0
}
