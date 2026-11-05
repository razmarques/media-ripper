#!/bin/bash
# End-to-end checks for cd-ripper.sh, run in Docker with a stand-in cyanrip.
# Needs: docker, the image built (tag below), and a folder of WAVs for the
# Gerry Mulligan "Night Lights" CD (barcode 042281827129) in inputs/album.
# Uses the network (MusicBrainz). The real drive path is NOT covered here.
#
#   docker build -t media-ripper-cd:latest -f Containerfile.cd .
#   tests/run.sh

set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-media-ripper-cd:latest}"
SRC="inputs/album"
BARCODE="042281827129"
NUS_RELEASE="84a7f799-67f6-4f30-8230-a4d554d81a7f"   # Mão Morta - Nus (different durations)

[[ -d "$SRC" ]] || { echo "SKIP: $SRC not found"; exit 0; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
OUT="$T/music"; mkdir -p "$OUT"
FAIL=0

pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }
check() { # description, command...
    local d="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi
}

# cdr <args>: run the image with the fake cyanrip, our inputs and output.
cdr() {
    docker run --rm -e FAKE_SRC=/in/album -e CD_DRIVE_ID="TEST - DRIVE" -e CD_OFFSET=6 \
        -e FAKE_LOG=/music/fake-calls.log \
        -v "$PWD/tests/fake-cyanrip":/usr/local/bin/cyanrip:ro \
        -v "$PWD/inputs":/in:ro -v "$OUT":/music "$IMAGE" "$@"
}
# tool <cmd...>: run a tool from the image against $OUT.
tool() { docker run --rm --entrypoint "$1" -v "$OUT":/music:ro "$IMAGE" "${@:2}"; }
sums() { (cd "$1" && find . -type f ! -name '.DS_Store' -print0 | sort -z | xargs -0 shasum | shasum | cut -d' ' -f1); }
audio_md5() { tool ffmpeg -v error -i "$1" -map 0:a -f md5 -; }

echo "== 1. rip: raw lossless + facts, no metadata lookup"
cdr rip >"$T/rip.log" 2>&1
RIPDIR="$(find "$OUT/RIP" -mindepth 1 -maxdepth 1 -type d | head -1)"; RIP="/music/RIP/$(basename "$RIPDIR")"
check "raw FLACs written"                  test -f "$RIPDIR/raw/01.flac"
check "rip.log and rip.cue kept in raw/"   test -f "$RIPDIR/raw/rip.log" -a -f "$RIPDIR/raw/rip.cue"
check "rip.json says disc / verified"      grep -q '"verify": "verified"' "$RIPDIR/rip.json"
check "disc ID recorded"                   grep -q 'AAAAAAAAAAAAAAAAAAAAAAAAAAA-' "$RIPDIR/rip.json"
check "rip never asked for a lookup"       bash -c "! grep -q 'MusicBrainz lookup' '$T/rip.log'"
RAW_BEFORE="$(sums "$RIPDIR/raw")"

echo "== 2. match: preview, wrong release rejected, then save"
cdr match "$RIP" --barcode "$BARCODE" >"$T/m1.log" 2>&1
check "match finds Night Lights"           grep -q 'Night Lights' "$T/m1.log"
check "preview writes nothing"             test ! -f "$RIPDIR/release.json"
cdr match "$RIP" --mb-release "$NUS_RELEASE" >"$T/m2.log" 2>&1
check "release with other durations is rejected" grep -q 'duration' "$T/m2.log"
cdr match "$RIP" --barcode "$BARCODE" --save >"$T/m3.log" 2>&1
check "--save writes release.json"         test -f "$RIPDIR/release.json"
check "release.json has 7 tracks"          bash -c "[ \$(grep -o '\"title\"' '$RIPDIR/release.json' | wc -l) -eq 7 ]"

echo "== 3. encode from the rip, using release.json"
cdr encode "$RIP" --format aac >"$T/e1.log" 2>&1
FLACDIR="$OUT/FLAC/Gerry Mulligan - Night Lights"; AACDIR="$OUT/AAC/Gerry Mulligan - Night Lights"
check "flat FLAC folder, named tracks"     bash -c "ls '$FLACDIR'/01\ -\ *.flac"
check "AAC folder with 7 tracks"           bash -c "[ \$(ls '$AACDIR'/*.m4a | wc -l) -eq 7 ]"
check "FLAC tagged with title"             bash -c "docker run --rm --entrypoint metaflac -v '$OUT':/m:ro $IMAGE --show-tag=TITLE '/m/FLAC/Gerry Mulligan - Night Lights/01 - Night Lights (1963 version).flac' | grep -q 'Night Lights'"
check "rip.json lists both outputs"        bash -c "[ \$(grep -c '\"dir\"' '$RIPDIR/rip.json') -eq 2 ]"

echo "== 4. fix metadata without touching raw rip or audio"
FLAC1="$(ls "$FLACDIR"/01*.flac)"; A_BEFORE="$(audio_md5 "/music/FLAC/Gerry Mulligan - Night Lights/$(basename "$FLAC1")")"
cdr update "$RIP" --artist "Gerry Mulligan Quartet" >"$T/u1.log" 2>&1
check "update preview changes nothing"     test -d "$FLACDIR"
cdr update "$RIP" --artist "Gerry Mulligan Quartet" --apply >"$T/u2.log" 2>&1
NEWF="$OUT/FLAC/Gerry Mulligan Quartet - Night Lights"
check "folder renamed on --apply"          test -d "$NEWF"
check "AAC folder renamed too"             test -d "$OUT/AAC/Gerry Mulligan Quartet - Night Lights"
A_AFTER="$(audio_md5 "/music/FLAC/Gerry Mulligan Quartet - Night Lights/$(basename "$FLAC1")")"
check "audio stream byte-identical after update" test "$A_BEFORE" = "$A_AFTER"
check "raw rip, log and cue untouched"     test "$RAW_BEFORE" = "$(sums "$RIPDIR/raw")"
check "AAC gapless info survived"          bash -c "docker run --rm --entrypoint bash -v '$OUT':/m:ro $IMAGE -c 'ffprobe -v error -show_entries format_tags=iTunSMPB -of default=nw=1 /m/AAC/*Quartet*/01*.m4a | grep -q iTunSMPB'"

echo "== 5. update a plain library folder (no rip folder)"
LIB="$OUT/lib"; mkdir -p "$LIB"; cp -R "$OUT/AAC/Gerry Mulligan Quartet - Night Lights" "$LIB/messy folder"
for f in "$LIB/messy folder"/*.m4a; do mv "$f" "$LIB/messy folder/$(basename "$f" | sed 's/^\([0-9]*\) - .*/\1 x.m4a/')"; done
docker run --rm -v "$OUT":/music "$IMAGE" update "/music/lib/messy folder" --barcode "$BARCODE" --artist "Gerry Mulligan" --apply >"$T/u3.log" 2>&1
check "library folder renamed from metadata" test -d "$LIB/Gerry Mulligan - Night Lights"
check "library files renamed with titles"  bash -c "ls '$LIB/Gerry Mulligan - Night Lights'/01\ -\ Night*.m4a"

echo "== 6. run with no match: encodes, never re-rips, prints the fix"
rm -rf "$OUT/RIP" "$OUT/FLAC" "$OUT/AAC"; : > "$OUT/fake-calls.log"
cdr run --format flac >"$T/r1.log" 2>&1
check "placeholder folder used"            test -d "$OUT/FLAC/Unknown Artist - Unknown Album"
check "Track NN names"                     test -f "$OUT/FLAC/Unknown Artist - Unknown Album/Track 01.flac"
check "fix-later command printed"          grep -q 'cd-ripper.sh update' "$T/r1.log"
check "disc ripped exactly once"           bash -c "[ \$(grep -c 'off=\[6\] find=0 info=0' '$OUT/fake-calls.log') -eq 1 ]"

echo "== 7. run with a barcode, then fix metadata later without re-ripping"
rm -rf "$OUT/RIP" "$OUT/FLAC" "$OUT/AAC"
cdr run --format flac --barcode "$BARCODE" >"$T/r2.log" 2>&1
check "run matched and named by artist"    test -d "$OUT/FLAC/Gerry Mulligan - Night Lights"

echo "== 8. legacy call: WAV folder, no subcommand"
rm -rf "$OUT/RIP" "$OUT/FLAC" "$OUT/AAC"
docker run --rm --network none -v "$PWD/inputs":/in:ro -v "$OUT":/music "$IMAGE" \
    -i "/in/Gerry Mulligan - Night Lights [WAV]" -f aac >"$T/l1.log" 2>&1
check "flat Artist - Album folders"        test -d "$OUT/FLAC/Gerry Mulligan - Night Lights" -a -d "$OUT/AAC/Gerry Mulligan - Night Lights"
check "Track NN names (no titles in files)" test -f "$OUT/AAC/Gerry Mulligan - Night Lights/Track 01.m4a"

echo "== 9. multi-disc"
rm -rf "$OUT/RIP" "$OUT/FLAC" "$OUT/AAC"
docker run --rm --network none -v "$PWD/inputs":/in:ro -v "$OUT":/music "$IMAGE" \
    encode "/in/Gerry Mulligan - Night Lights [WAV]" --disc 2/3 >"$T/d1.log" 2>&1
check "Disc suffix only on multi-disc"     test -d "$OUT/FLAC/Gerry Mulligan - Night Lights - Disc 2"

echo ""
if [[ $FAIL -eq 0 ]]; then echo "All checks passed."; else echo "$FAIL check(s) FAILED. Logs kept in $T"; trap - EXIT; exit 1; fi
