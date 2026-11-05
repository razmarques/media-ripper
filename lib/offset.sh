# shellcheck shell=bash
# Drive offset resolution and AccurateRip verification (rip stage only).
# Sourced by cd-ripper.sh. Needs: DEVICE, OUT_DIR, OFFSET, OFFSET_SOURCE, die().

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
