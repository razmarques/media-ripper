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

# Does this file already carry exactly the tags we would write? Reads the tags
# cd-ripper owns (see FLAC_OWNED_TAGS); anything else, comments included, is
# not looked at. Used to leave conforming files untouched.
tags_conform() { # file ext track-index track-total
    local f="$1" ext="$2" i="$3" total="$4" ta="${TRACK_ARTIST[$3]:-$ARTIST}"
    local disc="" dtot="" want keys
    if is_multidisc; then
        disc="$((10#$DISC))"
        [[ -n "$TOTAL_DISCS" ]] && dtot="$((10#$TOTAL_DISCS))"
    fi
    case "$ext" in
        flac)
            keys='["title","artist","albumartist","album_artist","album","date","tracknumber","tracktotal","totaltracks","discnumber","disctotal","totaldiscs","disc"]'
            want="$(jq -n -c --arg title "${TRACK_TITLE[$i]}" --arg artist "$ta" --arg aa "$ARTIST" \
                --arg album "$ALBUM" --arg date "$YEAR" --arg tn "$((10#${TRACK_NUM[$i]}))" --arg tt "$total" \
                --arg dn "$disc" --arg dt "$dtot" \
                '{title: $title, artist: $artist, albumartist: $aa, album: $album, date: $date,
                  tracknumber: $tn, tracktotal: $tt, discnumber: $dn, disctotal: $dt}')" ;;
        m4a)
            # a single-disc file may carry a disc atom from elsewhere; we never remove it
            keys='["title","artist","album_artist","album","date","track","disc"]'
            [[ -n "$disc" ]] || keys='["title","artist","album_artist","album","date","track"]'
            want="$(jq -n -c --arg title "${TRACK_TITLE[$i]}" --arg artist "$ta" --arg aa "$ARTIST" \
                --arg album "$ALBUM" --arg date "$YEAR" --arg tr "$((10#${TRACK_NUM[$i]}))/$total" \
                --arg dc "${disc:+$disc${dtot:+/$dtot}}" \
                '{title: $title, artist: $artist, album_artist: $aa, album: $album, date: $date,
                  track: $tr, disc: $dc}')" ;;
        *) return 1 ;;
    esac
    ffprobe -v error -show_entries format_tags -of json "$f" 2>/dev/null \
        | jq -e --argjson want "$want" --argjson keys "$keys" '
            ((.format.tags // {}) | with_entries(.key |= ascii_downcase)) as $cur
            | all($keys[]; ($cur[.] // "") == ($want[.] // ""))' >/dev/null 2>&1
}

has_picture() { # file
    case "${1##*.}" in
        flac|FLAC) metaflac --list --block-type=PICTURE "$1" 2>/dev/null | grep -q PICTURE ;;
        *)         ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$1" 2>/dev/null | grep -q video ;;
    esac
}

# Library files whose release has artwork but which have none: take the cover
# from the matched release. A file that already has artwork keeps it.
fetch_library_cover() {
    [[ "$SRC_KIND" == "library" && -z "$COVER" && -f "$WORK_DIR/chosen.json" ]] || return 0
    local f lacking=0 dest="$WORK_DIR/cover.img"
    for f in "${TRACK_SRC[@]}"; do has_picture "$f" || lacking=$((lacking + 1)); done
    [[ $lacking -gt 0 ]] || return 0
    if [[ $APPLY -ne 1 ]]; then
        echo "  cover art: ${lacking} file(s) have none; it would be added from the release."
        return 0
    fi
    local got=1
    if [[ "$(jq -r '.source // "musicbrainz"' "$WORK_DIR/chosen.json")" == "discogs" ]]; then
        dg_fetch_cover "$(jq -r '.cover_url // ""' "$WORK_DIR/chosen.json")" "$dest" && got=0
    else
        mb_fetch_cover "$(jq -r .mb_release "$WORK_DIR/chosen.json")" "$dest" && got=0
    fi
    if [[ $got -eq 0 ]]; then
        COVER="$dest"; COVER_FETCHED=1
        echo "  cover art: added to the ${lacking} file(s) that had none."
    else
        echo "  cover art: none found for that release."
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

    [[ $FIX_MODE -eq 1 ]] || { echo ""; echo "Folder: $dir"; }
    local tags_ok cover_needed saved_cover changed_files=0 conform_files=0 line
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

        # Library files that already conform are left alone (not rewritten).
        tags_ok=0; cover_needed=0
        if [[ "$SRC_KIND" == "library" ]]; then
            tags_conform "$f" "$ext" "$i" "$total" && tags_ok=1
            if [[ -n "$COVER" ]]; then
                if [[ $COVER_FETCHED -eq 1 ]]; then has_picture "$f" || cover_needed=1; else cover_needed=1; fi
            fi
        fi

        if [[ $APPLY -eq 1 && ( $tags_ok -eq 0 || $cover_needed -eq 1 ) ]]; then
            saved_cover="$COVER"
            [[ $COVER_FETCHED -eq 1 && $cover_needed -eq 0 ]] && COVER=""
            case "$ext" in
                flac) write_flac_tags "$f" "$i" "$total" ;;
                m4a)  write_m4a_tags "$f" "$i" "$total" ;;
            esac
            COVER="$saved_cover"
        fi

        line=""
        if [[ "$f" == "$newpath" ]]; then
            if [[ "$SRC_KIND" == "library" && $tags_ok -eq 1 && $cover_needed -eq 0 ]]; then
                conform_files=$((conform_files + 1))
                [[ $FIX_MODE -eq 1 ]] || line="  $(basename "$f")   (already conforms)"
            elif [[ "$SRC_KIND" == "library" ]]; then
                line="  $(basename "$f")   (tags$([[ $APPLY -eq 1 ]] && echo " updated" || echo " would change"))"
                changed_files=$((changed_files + 1))
            else
                line="  $(basename "$f")   (name unchanged)"
            fi
        elif [[ -e "$newpath" ]]; then
            line="  $(basename "$f") -> $newbase.$ext   SKIPPED: that name already exists"
        else
            line="  $(basename "$f") -> $newbase.$ext"
            changed_files=$((changed_files + 1))
            [[ $APPLY -eq 1 ]] && mv "$f" "$newpath"
        fi
        [[ -z "$line" ]] || echo "$line"
    done
    if [[ $FIX_MODE -eq 1 ]]; then
        echo "  ${changed_files} file(s) $([[ $APPLY -eq 1 ]] && echo changed || echo "would change"), ${conform_files} already conform."
        [[ $changed_files -eq 0 ]] || printf 'x%.0s' $(seq 1 "$changed_files") >> "$WORK_DIR/fix-changed"
    fi

    # Keep extras/ in step with the new names (cue FILE lines, cover).
    [[ $APPLY -eq 1 && $COVER_FETCHED -eq 0 ]] && refresh_extras "$dir"

    # A rip output moves to FLAC|AAC/Artist/Album[/Disc N]. A library folder is
    # only ever renamed in place (we do not know where its Artist folder is).
    local shown_old shown_new
    if [[ "$SRC_KIND" == "library" ]]; then
        newdir="$(dirname "$dir")/$(basename "$(album_rel_dir)")"
        shown_old="$(basename "$dir")"; shown_new="$(basename "$newdir")"
    else
        old_rel="${dir#"$OUT_DIR"/}"
        newdir="$OUT_DIR/${old_rel%%/*}/$(album_rel_dir)"
        shown_old="$old_rel"; shown_new="${newdir#"$OUT_DIR"/}"
    fi
    if [[ "$newdir" != "$dir" && "$SRC_KIND" == "library" && $RENAME_FOLDER -eq 0 ]]; then
        echo "  folder kept: $shown_old   (add --rename-folder to rename it to $shown_new)"
    elif [[ "$newdir" != "$dir" ]]; then
        if [[ -e "$newdir" ]]; then
            echo "  folder rename SKIPPED: $shown_new already exists"
        else
            echo "  folder: $shown_old -> $shown_new"
            if [[ $APPLY -eq 1 ]]; then
                mkdir -p "$(dirname "$newdir")"
                if mv "$dir" "$newdir"; then
                    if [[ "$SRC_KIND" != "library" ]]; then
                        new_rel="${newdir#"$OUT_DIR"/}"
                        rip_json_rename_output "$old_rel" "$new_rel"
                        prune_empty_parents "$old_rel"
                    fi
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

# One album: look the release up, then retag / rename its files. Called for a
# single folder by `update`, and once per album folder (in a subshell) by `fix`.
# Exit status: 0 done, 2 no match (update only), 3 several releases fit,
# 4 several discs fit, 5 skipped (fix: nothing to go on).
update_album() {
    load_all

    local want_match=0 soft=0 rc=0 dirs=() d rel chosen=0
    if [[ -n "$ARG_MBID" || -n "$ARG_DGID" || -n "$ARG_BARCODE" || -n "$ARG_DISCID" || $LOOKUP -eq 1 ]]; then
        want_match=1
    elif [[ -n "$SESSION_DIR" && -f "$(session_json)" && ! -f "$SESSION_DIR/release.json" \
            && -n "$(jq -r '.discid // ""' "$(session_json)")" ]]; then
        want_match=1
    elif [[ -n "$FILE_MBID$FILE_BARCODE$FILE_DISCID$FILE_DGID" ]]; then
        # IDs left in the tags by another tagger: use them, but never fail on them.
        want_match=1; soft=1
    fi

    if [[ $FIX_MODE -eq 1 ]]; then echo "--- ${TARGET#"$FIX_ROOT"/}"; else echo "=== Update: $TARGET ==="; fi
    if [[ $want_match -eq 1 ]]; then
        need_tools curl
        ALLOW_TEXT=$LOOKUP
        match_into_state || rc=$?
        case "$rc" in
            0)
                chosen=1; finalize_metadata
                [[ $FIX_MODE -eq 1 ]] || print_match_preview "$WORK_DIR/chosen.json"
                jq -r '.source // "musicbrainz"' "$WORK_DIR/chosen.json" > "$WORK_DIR/fix-result" ;;
            3|4) exit "$rc" ;;
            *)
                if [[ $FIX_MODE -eq 1 || $soft -eq 1 ]]; then
                    echo "  No release found online: using what the files and folder names say (unverified)."
                    echo names > "$WORK_DIR/fix-result"
                else
                    echo ""; echo "No match; nothing changed."; exit 2
                fi ;;
        esac
    fi
    if [[ $FIX_MODE -eq 1 && ( -z "$ARTIST" || -z "$ALBUM" ) ]]; then
        echo "  Skipped: no release found, and the artist or album cannot be told from the tags or folder names."
        echo "  Name the folder 'Artist - Album', or run: update <folder> --artist <...> --album <...> --apply"
        exit 5
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
    [[ $chosen -eq 1 ]] && fetch_library_cover
    if [[ ${#dirs[@]} -eq 0 ]]; then
        echo ""
        echo "No encoded files recorded for this rip yet. Run: cd-ripper.sh encode \"$SESSION_DIR\" --format flac|aac"
    fi
    for d in "${dirs[@]}"; do
        apply_to_dir "$d"
    done
    return 0
}

cmd_update() {
    need_tools jq ffprobe metaflac AtomicParsley
    update_album

    echo ""
    if [[ $APPLY -eq 1 ]]; then
        echo "✔ Updated."
    else
        echo "Preview only, nothing was changed. Add --apply to write it."
    fi
    return 0
}

# fix <folder>: bring a whole library folder to the standard cd-ripper writes.
# Every folder that holds FLAC/M4A files is one album, handled exactly like
# `update <album> --lookup`: MusicBrainz (IDs in the tags, then searches),
# Discogs second, the tags and folder names last. Only the tags cd-ripper
# owns are touched; comments and any other tags stay as they are. One album
# that cannot be decided never stops the others: they are listed at the end.
cmd_fix() {
    need_tools jq ffprobe metaflac AtomicParsley curl
    [[ -n "$TARGET" ]] || die "No folder given. Usage: cd-ripper.sh fix <library folder> [--apply]"
    [[ -d "$TARGET" ]] || die "Folder not found: $TARGET"
    if [[ -n "$ARG_ARTIST$ARG_ALBUM$ARG_YEAR$ARG_DISC$ARG_BARCODE$ARG_MBID$ARG_DGID$ARG_DISCID" ]]; then
        die "fix works on many albums, so it takes no --artist/--album/--year/--disc/--barcode/--mb-release/--discogs-release/--discid.
  For one album use: update <album folder> ... --apply"
    fi
    FIX_MODE=1; LOOKUP=1
    FIX_ROOT="$(cd "$TARGET" && pwd)"

    local dirs=() d n=0 total rc res
    local mb=0 dg=0 names=0 skipped=0 attention=() changed=0
    while IFS= read -r -d '' d; do dirs+=("$d"); done < <(
        find "$FIX_ROOT" \( -name RIP -o -name extras -o -name '.cd-ripper' \) -prune -o \
             -type f \( -iname '*.flac' -o -iname '*.m4a' \) -printf '%h\0' | sort -zu)
    total=${#dirs[@]}
    [[ $total -gt 0 ]] || die "No FLAC/M4A files under $FIX_ROOT"

    echo "=== Fix: $FIX_ROOT ($total album folder(s)) ==="
    for d in "${dirs[@]}"; do
        n=$((n + 1))
        [[ -d "$d" ]] || continue
        echo ""
        find "$WORK_DIR" -mindepth 1 -delete 2>/dev/null || true
        TARGET="$d"
        if has_ext "$d" flac && has_ext "$d" m4a; then
            echo "--- ${d#"$FIX_ROOT"/}"
            echo "  Skipped: FLAC and M4A files in the same folder (the track count would be wrong). Put each format in its own folder."
            attention+=("${d#"$FIX_ROOT"/}   (FLAC and M4A mixed in one folder)")
            continue
        fi
        # Not inside "if"/"&&": that would switch errexit off inside update_album.
        set +e
        ( set -e; update_album )
        rc=$?
        set -e
        case "$rc" in
            0)
                res="$(cat "$WORK_DIR/fix-result" 2>/dev/null || true)"
                case "$res" in
                    musicbrainz) mb=$((mb + 1)) ;;
                    discogs)     dg=$((dg + 1)) ;;
                    *)           names=$((names + 1)) ;;
                esac
                if [[ -f "$WORK_DIR/fix-changed" ]]; then changed=$((changed + $(wc -c < "$WORK_DIR/fix-changed"))); fi ;;
            5) skipped=$((skipped + 1)); attention+=("${d#"$FIX_ROOT"/}   (artist/album unknown)") ;;
            3) attention+=("${d#"$FIX_ROOT"/}   (several releases fit: choose with update <folder> --mb-release <id> or --pick earliest)") ;;
            4) attention+=("${d#"$FIX_ROOT"/}   (several discs fit: update <folder> --disc N/TOTAL)") ;;
            *) attention+=("${d#"$FIX_ROOT"/}   (failed, see above)") ;;
        esac
        # one request per second to MusicBrainz / Discogs, also between albums
        if [[ -e "$WORK_DIR/.rate-mb" || -e "$WORK_DIR/.rate-dg" ]]; then sleep "${CD_HTTP_PAUSE:-1}"; fi
    done

    echo ""
    echo "=== Fix summary ==="
    echo "  $total album folder(s): $mb matched on MusicBrainz, $dg on Discogs, $names from the file/folder names only (unverified)."
    echo "  $changed file(s) $([[ $APPLY -eq 1 ]] && echo changed || echo "would change")."
    if [[ ${#attention[@]} -gt 0 ]]; then
        echo "  Need your decision (${#attention[@]}):"
        for d in "${attention[@]}"; do echo "    $d"; done
    fi
    if [[ $APPLY -ne 1 ]]; then echo "  Preview only, nothing was changed. Add --apply to write it."; fi
    [[ ${#attention[@]} -eq 0 ]] || exit 3
    return 0
}
