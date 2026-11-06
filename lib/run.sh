# shellcheck shell=bash
# run: the whole workflow (rip -> match -> encode). Matching never blocks or
# repeats the rip: if it fails, the files are encoded with placeholder names
# and the exact `update` command is printed.

cmd_run() {
    local attempt=0 rc=0

    if [[ -z "$TARGET" ]]; then
        cmd_rip
        TARGET="$SESSION_DIR"
        attempt=1
    elif [[ -n "$ARG_MBID" || -n "$ARG_DGID" || -n "$ARG_BARCODE" || -n "$ARG_DISCID" || $LOOKUP -eq 1 ]]; then
        attempt=1
    fi

    if [[ $attempt -eq 1 ]]; then
        need_tools curl jq ffprobe
        ALLOW_TEXT=$LOOKUP
        load_all
        echo ""
        echo "=== Match ==="
        match_into_state || rc=$?
        if [[ $rc -eq 0 ]]; then
            finalize_metadata
            print_match_preview "$WORK_DIR/chosen.json"
            save_release
        else
            echo ""
            echo "Metadata not matched (the rip is safe). Encoding with placeholder names; fix it later with:"
            echo "  cd-ripper.sh update \"$SESSION_DIR\" --barcode <digits> --apply"
            echo "  (or --mb-release <id>; leave out --apply to preview)"
        fi
    fi

    cmd_encode
}
