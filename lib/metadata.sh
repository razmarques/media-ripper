# shellcheck shell=bash
# Matching a set of audio files to a MusicBrainz release.
#
# mb_resolve looks for candidates (release ID, barcode, disc ID, or artist +
# album search), checks each against the real files (track count and track
# durations), and picks one. It never touches the audio.
#
# Exit status of mb_resolve:
#   0  one release chosen -> $WORK_DIR/chosen.json
#   2  nothing usable found
#   3  several different releases fit and none can be preferred

MB_CALLS=0
ALLOW_TEXT=0                      # allow artist + album text search
DURATION_TOLERANCE=2              # seconds, per track

# Candidate evaluation, run with: --argjson n <tracks> --argjson d <disc, 0 =
# unknown> --argjson durs [seconds...] --argjson tol <seconds>
MB_EVAL_JQ='
def credit: [."artist-credit"[]? | .name + (.joinphrase // "")] | join("");
def off($tr): [$tr | to_entries[]
    | select(.value.length != null and $durs[.key] != null
             and ((.value.length / 1000 - $durs[.key]) | fabs) > $tol)] | length;
(.media // []) as $m
| ($m | length) as $nm
| ([$m[] | select((.tracks | length) == $n and ($d == 0 or .position == $d))]) as $cnt
| ([$cnt[] | select(off(.tracks) == 0)]) as $good
| (if ($cnt | length) == 0 then "count"
   elif ($good | length) == 0 then "duration"
   elif ($good | length) > 1 then "needs_disc"
   else "ok" end) as $status
| ($good[0] // $cnt[0] // null) as $med
| {id: .id, date: (.date // ""), country: (.country // ""), barcode: (.barcode // ""),
   artist: credit, album: .title,
   cover_url: (.cover_url // ""),
   label: ([."label-info"[]? | ((.label.name // "?") + " " + (."catalog-number" // ""))] | join("; ")),
   media: $nm, disc: ($med.position // null), status: $status,
   tracks: ($med.tracks // [] | map({n: .position, title: .title}))}
'

MB_FETCH_FAILED=0

mb_get() { # path, then curl args. Retries: MusicBrainz sometimes answers 503.
    local path="$1" attempt out; shift
    MB_CALLS=$((MB_CALLS + 1))
    [[ $MB_CALLS -gt 1 ]] && sleep 1   # MusicBrainz allows 1 request/second
    for attempt in 1 2 3; do
        if out="$(curl -fsS --max-time 30 -A "$UA" -G "$MB_API/$path" "$@" --data-urlencode "fmt=json" 2>/dev/null)"; then
            printf '%s' "$out"
            return 0
        fi
        sleep $((attempt * 2))
    done
    MB_FETCH_FAILED=$((MB_FETCH_FAILED + 1))
    return 1
}

MB_INC="recordings+artist-credits+labels"

# ----------------------------------------------------------------------------
# Discogs: fallback when MusicBrainz has no usable release for a barcode.
# Discogs releases are converted to the MusicBrainz shape so the same
# validation and tie-break run on them. DISCOGS_TOKEN is optional (a token
# raises the rate limit and allows cover downloads).
# ----------------------------------------------------------------------------
DG_API="https://api.discogs.com"
DISCOGS_DURATION_TOLERANCE=5      # Discogs track times are user-entered: looser than MusicBrainz

DG_TO_MB_JQ='
def clean: sub("\\s*\\(\\d+\\)$"; "");
def ms: if . == null or . == "" then null
        else (try (split(":") | map(tonumber) | reduce .[] as $x (0; . * 60 + $x) | . * 1000) catch null) end;
def mk($tl): $tl | to_entries | map({position: (.key + 1), title: .value.title, length: (.value.duration | ms)});
([.tracklist[]? | select(.type_ == "track")]) as $tl
| (if ($tl | length) > 0 and ($tl | all(.position | test("^[0-9]+-[0-9]+$")))
   then ($tl | group_by(.position | split("-")[0] | tonumber)
         | map({position: (.[0].position | split("-")[0] | tonumber), tracks: mk(.)}))
   else [{position: 1, tracks: mk($tl)}] end) as $media
| ((.released // "") | sub("(-00)+$"; "")) as $rel
| {id: ("discogs:" + (.id | tostring)),
   title: .title,
   date: (if $rel != "" then $rel elif (.year // 0) > 0 then (.year | tostring) else "" end),
   country: (.country // ""),
   barcode: $b,
   "artist-credit": [.artists[]? | {name: (.name | clean), joinphrase: (.join // "")}],
   "label-info": [.labels[]? | {label: {name: .name}, "catalog-number": .catno}],
   media: $media,
   cover_url: ([.images[]? | select(.type == "primary") | .uri][0] // .images[0].uri // "")}
'

DG_FETCH_FAILED=0
DG_CALLS=0

dg_get() { # path, then curl args
    local path="$1" attempt out hdr=(); shift
    [[ -n "${DISCOGS_TOKEN:-}" ]] && hdr=(-H "Authorization: Discogs token=$DISCOGS_TOKEN")
    DG_CALLS=$((DG_CALLS + 1))
    [[ $DG_CALLS -gt 1 ]] && sleep 1
    for attempt in 1 2 3; do
        if out="$(curl -fsS --max-time 30 -A "$UA" ${hdr[@]+"${hdr[@]}"} -G "$DG_API/$path" "$@" 2>/dev/null)"; then
            printf '%s' "$out"
            return 0
        fi
        sleep $((attempt * 2))
    done
    DG_FETCH_FAILED=$((DG_FETCH_FAILED + 1))
    return 1
}

dg_fetch_cover() { # image url, dest
    local hdr=()
    [[ -n "${DISCOGS_TOKEN:-}" ]] && hdr=(-H "Authorization: Discogs token=$DISCOGS_TOKEN")
    [[ -n "$1" ]] || return 1
    curl -fsSL --max-time 40 -A "$UA" ${hdr[@]+"${hdr[@]}"} -o "$2" "$1" 2>/dev/null \
        && [[ -s "$2" ]] || { rm -f "$2"; return 1; }
}


# Append full release objects (one JSON per line) to file $1.
mb_collect() { # out file, method
    local out="$1" method="$2" resp ids id n=0
    case "$method" in
        mbid)
            mb_get "release/$ARG_MBID" --data-urlencode "inc=$MB_INC" \
                | jq -c . >> "$out" || true
            ;;
        discid)
            mb_get "discid/$MB_DISCID" --data-urlencode "inc=$MB_INC" \
                | jq -c '.releases[]?' >> "$out" || true
            ;;
        dgid)
            dg_get "releases/$ARG_DGID" | jq -c --arg b "$ARG_BARCODE" "$DG_TO_MB_JQ" >> "$out" || true
            ;;
        discogs)
            local bn="${ARG_BARCODE#"${ARG_BARCODE%%[!0]*}"}"
            resp="$(dg_get database/search --data-urlencode "barcode=$ARG_BARCODE" --data-urlencode "type=release")" || return 0
            ids="$(printf '%s' "$resp" | jq -r --arg bn "$bn" \
                '.results[]? | select($bn != "" and any(.barcode[]?; gsub("[ -]"; "") | sub("^0+"; "") == $bn)) | .id')"
            while IFS= read -r id; do
                [[ -n "$id" ]] || continue
                n=$((n + 1)); [[ $n -gt 8 ]] && break
                dg_get "releases/$id" | jq -c --arg b "$ARG_BARCODE" "$DG_TO_MB_JQ" >> "$out" || true
            done <<< "$ids"
            ;;
        barcode|search)
            local q
            if [[ "$method" == "barcode" ]]; then
                q="barcode:$ARG_BARCODE"
            else
                q="artist:\"${MB_ARTIST//\"/}\" AND release:\"${MB_ALBUM//\"/}\""
            fi
            resp="$(mb_get release --data-urlencode "query=$q" --data-urlencode "limit=10")" || return 0
            # The barcode search is fuzzy: keep only exact barcode matches.
            # UPC-A/EAN-13/GTIN-14 are the same number padded with leading zeros
            # to different lengths, so strip those before comparing. A release
            # with no barcode field must not break the filter.
            ids="$(printf '%s' "$resp" | jq -r --arg b "$([[ $method == barcode ]] && printf '%s' "$ARG_BARCODE")" \
                '($b | sub("^0+"; "")) as $bn
                 | .releases[]?
                 | select($b == "" or ($bn != "" and ((.barcode // "") | sub("^0+"; "")) == $bn))
                 | .id')"
            while IFS= read -r id; do
                [[ -n "$id" ]] || continue
                n=$((n + 1)); [[ $n -gt 8 ]] && break
                mb_get "release/$id" --data-urlencode "inc=$MB_INC" | jq -c . >> "$out" || true
            done <<< "$ids"
            ;;
    esac
    return 0
}

print_candidates() { # eval file
    echo "  Candidates:"
    jq -r '"    " + .id + "  " + (if .date == "" then "no date" else .date end) + "  " + (if .country == "" then "-" else .country end)
           + "  " + (if .label == "" then "-" else .label end) + "  barcode " + (if .barcode == "" then "-" else .barcode end)
           + "  [" + .status + "]"' "$1"
}

mb_fetch_cover() { # release id, dest
    curl -fsSL --max-time 40 -A "$UA" -o "$2" "https://coverartarchive.org/release/$1/front-1200" 2>/dev/null \
        && [[ -s "$2" ]] || { rm -f "$2"; return 1; }
}

mb_resolve() {
    local total=${#TRACK_SRC[@]} d method methods=() cands evalf ok durs tol
    d="${ARG_DISC:-${FILE_DISC:-0}}"
    MB_CALLS=0; MB_FETCH_FAILED=0; DG_CALLS=0; DG_FETCH_FAILED=0

    need_tools curl jq
    cands="$WORK_DIR/cands.ndjson"; evalf="$WORK_DIR/eval.ndjson"; ok="$WORK_DIR/ok.ndjson"

    MB_DISCID="${ARG_DISCID:-}"
    if [[ -z "$MB_DISCID" && -n "$SESSION_DIR" && -f "$(session_json)" ]]; then
        MB_DISCID="$(jq -r '.discid // ""' "$(session_json)")"
    fi
    MB_ARTIST="${ARG_ARTIST:-$FILE_ARTIST}"
    MB_ALBUM="${ARG_ALBUM:-$FILE_ALBUM}"

    [[ -n "$ARG_MBID" ]]    && methods+=(mbid)
    [[ -n "$ARG_DGID" ]]    && methods+=(dgid)
    [[ -n "$ARG_BARCODE" ]] && methods+=(barcode)
    [[ -n "$MB_DISCID" ]]   && methods+=(discid)
    # Last resort for a barcode MusicBrainz cannot place: Discogs.
    [[ -n "$ARG_BARCODE" && -z "$ARG_DGID" ]] && methods+=(discogs)
    if [[ $ALLOW_TEXT -eq 1 && -n "$MB_ARTIST" && -n "$MB_ALBUM" ]]; then methods+=(search); fi
    if [[ ${#methods[@]} -eq 0 ]]; then
        echo "No way to look the release up. Give --mb-release, --discogs-release, --barcode, --discid, or artist and album (--lookup)."
        return 2
    fi

    # Track durations in track-number order, as a JSON array.
    durs="$(for i in "${!TRACK_SRC[@]}"; do printf '%s %s\n' "${TRACK_NUM[$i]}" "${TRACK_DUR[$i]:-null}"; done \
        | sort -n | awk '{print $2}' | jq -s -c 'map(if . == "null" then null else tonumber end)')"

    for method in "${methods[@]}"; do
        : > "$cands"
        case "$method" in
            mbid)    echo "Looking up release $ARG_MBID ..." ;;
            barcode) echo "Looking up barcode $ARG_BARCODE ..." ;;
            discid)  echo "Looking up disc ID $MB_DISCID ..." ;;
            dgid)    echo "Looking up Discogs release $ARG_DGID ..." ;;
            discogs) echo "Not usable on MusicBrainz; trying Discogs for barcode $ARG_BARCODE ..." ;;
            search)  echo "Searching MusicBrainz for: $MB_ARTIST - $MB_ALBUM ..." ;;
        esac
        mb_collect "$cands" "$method"
        [[ $MB_FETCH_FAILED -gt 0 ]] && echo "  warning: $MB_FETCH_FAILED MusicBrainz request(s) failed after retries; the result may be incomplete."
        [[ $DG_FETCH_FAILED -gt 0 ]] && echo "  warning: $DG_FETCH_FAILED Discogs request(s) failed after retries (rate limit? set DISCOGS_TOKEN); the result may be incomplete."
        [[ -s "$cands" ]] || { echo "  nothing returned."; continue; }

        tol="$DURATION_TOLERANCE"; [[ "$method" == "discogs" || "$method" == "dgid" ]] && tol="$DISCOGS_DURATION_TOLERANCE"
        jq -c --argjson n "$total" --argjson d "$d" --argjson durs "$durs" \
            --argjson tol "$tol" "$MB_EVAL_JQ" "$cands" > "$evalf"
        jq -c 'select(.status == "ok")' "$evalf" > "$ok"

        if [[ ! -s "$ok" ]]; then
            if [[ -n "$(jq -r 'select(.status == "needs_disc") | .id' "$evalf")" ]]; then
                echo "  Matching release has several discs that fit these files; pass --disc <n>."
                print_candidates "$evalf"
                return 2
            fi
            echo "  none of the ${method} results fit these files (track count $total, durations within ${tol}s):"
            print_candidates "$evalf"
            continue
        fi

        # Same artist, album and titles = the same record in different editions.
        local groups
        groups="$(jq -s -r 'group_by((.artist + "|" + .album + "|" + (.tracks | map(.title) | join("|"))) | ascii_downcase | gsub("[^\\p{L}\\p{N}|]"; "")) | length' "$ok")"
        if [[ "$groups" -gt 1 && -z "$ARG_PICK" ]]; then
            echo "  Several different releases fit these files:"
            print_candidates "$ok"
            if [[ "$method" == "discogs" ]]; then
                echo "  Pass --discogs-release <number after discogs:> to choose one, or --pick earliest."
            else
                echo "  Pass --mb-release <id> to choose one, or --pick earliest."
            fi
            return 3
        fi

        jq -s -c --arg method "$method" --arg barcode "$ARG_BARCODE" --arg discid "$MB_DISCID" '
            sort_by(if .date == "" then "9999" else .date end)
            | . as $all | .[0] as $c
            | {version: 1, method: $method, mb_release: $c.id,
               source: (if $method == "discogs" or $method == "dgid" then "discogs" else "musicbrainz" end),
               cover_url: $c.cover_url,
               barcode: ($c.barcode // $barcode), discid: $discid,
               artist: $c.artist, album: $c.album, year: ($c.date[0:4]),
               date: $c.date, country: $c.country, label: $c.label,
               disc: (if $c.media > 1 then $c.disc else null end),
               total_discs: (if $c.media > 1 then $c.media else null end),
               tracks: $c.tracks,
               others: [$all[1:][] | .id]}' "$ok" > "$WORK_DIR/chosen.json"

        local others
        others="$(jq -r '.others | length' "$WORK_DIR/chosen.json")"
        echo "  Matched: $(jq -r '.artist + " - " + .album + " (" + (if .date == "" then "no date" else .date end) + ", " + (if .country == "" then "-" else .country end) + ", " + (if .label == "" then "-" else .label end) + ")"' "$WORK_DIR/chosen.json")"
        echo "  Release ID: $(jq -r .mb_release "$WORK_DIR/chosen.json")"
        if [[ "$others" -gt 0 ]]; then
            echo "  $others other edition(s) have the same tracks (titles differ only in case/punctuation); took the earliest dated one."
            print_candidates "$ok"
        fi
        return 0
    done

    echo "No release matched."
    return 2
}

# Show what the chosen release would change, compared with the current
# (already merged) metadata.
print_match_preview() { # chosen json
    local f="$1" i n t cur
    echo ""
    printf '  %-8s %s\n' "Artist:" "$(jq -r .artist "$f")${FILE_ARTIST:+   (files say: $FILE_ARTIST)}"
    printf '  %-8s %s\n' "Album:"  "$(jq -r .album "$f")${FILE_ALBUM:+   (files say: $FILE_ALBUM)}"
    printf '  %-8s %s\n' "Year:"   "$(jq -r .year "$f")${FILE_YEAR:+   (files say: $FILE_YEAR)}"
    if [[ "$(jq -r '.disc // ""' "$f")" != "" ]]; then
        printf '  %-8s %s of %s\n' "Disc:" "$(jq -r .disc "$f")" "$(jq -r .total_discs "$f")"
    fi
    echo "  Tracks:"
    for i in "${!TRACK_SRC[@]}"; do
        n="${TRACK_NUM[$i]}"
        t="$(jq -r --argjson n "$n" '.tracks[]? | select(.n == $n) | .title' "$f")"
        cur="${FILE_TITLE[$i]}"
        printf '    %02d  %s%s\n' "$n" "${t:-<no title>}" "${cur:+   (was: $cur)}"
    done
    return 0
}
