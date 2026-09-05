#!/bin/bash

# ============================================================================
# MKV Encode
# ============================================================================
# Modular tool for ripping DVDs with MakeMKV and encoding to H.264 MKV.
#
# Commands:
#   rip    - Rip all titles from DVD losslessly via MakeMKV
#   scan   - Scan a MakeMKV-produced MKV with HandBrake to identify tracks
#   encode - Encode a scanned MKV to H.264 with selected tracks
#
# Each command is fully independent and can be re-run without repeating others.
#
# Track numbers come from HandBrake scan output (1-based).
# Language metadata is preserved automatically from the source MKV.
# Subtitles are passed through HandBrake directly.
#
# Dependencies:
#   makemkvcon   - MakeMKV CLI (rip stage)
#                  https://www.makemkv.com
#   HandBrakeCLI - HandBrake CLI (scan and encode stages)
#                  https://handbrake.fr
#
# ============================================================================

set -e

# ============================================================================
# Configuration and Global Variables
# ============================================================================
MOVIE_NAME=""
INPUT_FILE=""
AUDIO_TRACKS=""
SUBTITLE_TRACKS=""
SAVE_SCAN=""

# ============================================================================
# Helper Functions
# ============================================================================

show_usage() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
  rip     Rip all titles from DVD losslessly using MakeMKV
  scan    Scan a MKV file with HandBrake to identify track numbers
  encode  Encode a MKV file to H.264 with selected tracks

Options (for scan):
  -i, --input <file>         MKV file to scan
      --save                 Save scan output to <input>_scan.txt (default: stdout only)

Options (for encode):
  -n, --name <name>          Output file name (no extension)
  -i, --input <file>         Input MKV file (from MakeMKV rip)
  -a, --audio <tracks>       Comma-separated HandBrake track numbers (e.g. 1 or 1,2)
  -s, --subtitle <tracks>    Comma-separated HandBrake track numbers (e.g. 1 or 1,11)
                             Optional — omit to encode with no subtitles

Notes:
  - Always scan after ripping to identify correct track numbers
  - Track numbers from HandBrake scan are 1-based
  - Language metadata is copied automatically from the source MKV
  - Video: H.264 RF21, medium preset
  - Audio: lossless copy (no re-encoding)

Examples:
  # Step 1: Rip all titles from DVD
  $0 rip

  # Step 2: Scan the main title MKV to identify tracks
  $0 scan --input output/title_t00.mkv

  # Step 3: Encode with selected tracks
  $0 encode --name FindingNemo --input title_t00.mkv \\
      --audio 1,2 --subtitle 1,11

  # Encode with no subtitles
  $0 encode --name FindingNemo --input title_t00.mkv \\
      --audio 1
EOF
}

parse_flags() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name)
                MOVIE_NAME="$2"; shift 2 ;;
            -i|--input)
                INPUT_FILE="$2"; shift 2 ;;
            -a|--audio)
                AUDIO_TRACKS="$2"; shift 2 ;;
            -s|--subtitle)
                SUBTITLE_TRACKS="$2"; shift 2 ;;
            --save)
                SAVE_SCAN=1; shift ;;
            *)
                echo "Error: Unknown option: $1"
                echo ""
                show_usage
                exit 1 ;;
        esac
    done
}

require_var() {
    local flag="$1"
    local var_value="$2"
    if [[ -z "$var_value" ]]; then
        echo "Error: $flag is required"
        echo ""
        show_usage
        exit 1
    fi
}

# ============================================================================
# Stage Functions
# ============================================================================

rip_disc() {
    local OUTPUT_DIR="output"

    echo "=== Stage 1: Ripping DVD with MakeMKV ==="
    echo "Output dir: $OUTPUT_DIR"
    echo ""
    echo "Ripping all titles losslessly. This may take a while..."
    echo ""

    mkdir -p "$OUTPUT_DIR"

    # makemkvcon exits non-zero on warnings (e.g. disc not perfect); allow this
    makemkvcon -r mkv disc:0 all "$OUTPUT_DIR" || true

    local FILE_COUNT
    FILE_COUNT=$(find "$OUTPUT_DIR" -name "*.mkv" | wc -l)

    if [ "$FILE_COUNT" -eq 0 ]; then
        echo "Error: No MKV files found in $OUTPUT_DIR. Rip may have failed."
        exit 1
    fi

    echo ""
    echo "=========================================="
    echo "✔ Rip complete: $FILE_COUNT title(s) in $OUTPUT_DIR"
    echo "=========================================="
    echo ""
    echo "Files ripped:"
    ls -lh "$OUTPUT_DIR"/*.mkv
    echo ""
    echo "Next step: scan the main title to identify track numbers."
    echo "  $0 scan --input $OUTPUT_DIR/<title_file>.mkv"
}

scan_mkv() {
    require_var "--input" "$INPUT_FILE"

    echo "=== Scanning MKV ==="
    echo "Input: $INPUT_FILE"
    echo ""

    if [ ! -f "$INPUT_FILE" ]; then
        echo "Error: Input file not found: $INPUT_FILE"
        exit 1
    fi

    local SCAN_FILE="${INPUT_FILE%.mkv}_scan.txt"
    if [ -n "$SAVE_SCAN" ]; then
        HandBrakeCLI -i "$INPUT_FILE" -t 1 --scan 2>&1 | tee "$SCAN_FILE"
        echo ""
        echo "=========================================="
        echo "✔ Scan complete. Output saved to: $SCAN_FILE"
        echo "=========================================="
    else
        HandBrakeCLI -i "$INPUT_FILE" -t 1 --scan 2>&1
        echo ""
        echo "=========================================="
        echo "✔ Scan complete."
        echo "=========================================="
    fi
    echo ""
    echo "Look for:"
    echo "  - Audio track numbers and languages"
    echo "  - Subtitle track numbers and languages"
    echo ""
    echo "Next step: encode with selected tracks."
    echo "  $0 encode --name <n> --input $INPUT_FILE --audio <tracks> [--subtitle <tracks>]"
}

encode_mkv() {
    require_var "--name"   "$MOVIE_NAME"
    require_var "--input"  "$INPUT_FILE"
    require_var "--audio"  "$AUDIO_TRACKS"

    echo "=========================================="
    echo "MKV Encode"
    echo "=========================================="
    echo "Name:        $MOVIE_NAME"
    echo "Input:       $INPUT_FILE"
    echo "Audio:       $AUDIO_TRACKS"
    echo "Subtitles:   ${SUBTITLE_TRACKS:-none}"
    echo "=========================================="
    echo ""

    if [ ! -f "$INPUT_FILE" ]; then
        echo "Error: Input file not found: $INPUT_FILE"
        exit 1
    fi

    local FINAL_OUTPUT="${MOVIE_NAME}.mkv"

    # Build aencoder string: one 'copy' per audio track
    local TRACK_COUNT
    TRACK_COUNT=$(echo "$AUDIO_TRACKS" | tr ',' '\n' | wc -l)
    local AENCODER
    AENCODER=$(printf 'copy,%.0s' $(seq 1 "$TRACK_COUNT") | sed 's/,$//')

    # Build subtitle argument
    local SUBTITLE_ARG=""
    if [ -n "$SUBTITLE_TRACKS" ]; then
        SUBTITLE_ARG="--subtitle $SUBTITLE_TRACKS"
    fi

    echo "=== Encoding ==="
    echo ""

    HandBrakeCLI -i "$INPUT_FILE" -t 1 -o "$FINAL_OUTPUT" \
        --encoder x264 \
        --quality 21 \
        --encoder-preset medium \
        --auto-anamorphic \
        --audio "$AUDIO_TRACKS" \
        --aencoder "$AENCODER" \
        --markers \
        $SUBTITLE_ARG

    if [ ! -f "$FINAL_OUTPUT" ]; then
        echo "Error: Encoding failed."
        exit 1
    fi

    echo ""
    echo "=========================================="
    echo "=== ENCODING COMPLETE ==="
    echo "=========================================="
    echo "✔ Final output: $FINAL_OUTPUT"
    ls -lh "$FINAL_OUTPUT"
    echo ""
}

# ============================================================================
# Main Script Logic
# ============================================================================

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

COMMAND=$1
shift

case "$COMMAND" in
    rip)
        parse_flags "$@"
        rip_disc
        ;;

    scan)
        parse_flags "$@"
        scan_mkv
        ;;

    encode)
        parse_flags "$@"
        encode_mkv
        ;;

    *)
        echo "Error: Unknown command: $COMMAND"
        echo ""
        show_usage
        exit 1
        ;;
esac
