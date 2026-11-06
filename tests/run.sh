#!/bin/bash
# End-to-end checks for cd-ripper.sh, run in Docker. Fully self-contained: the
# audio is synthesised (sine tones, no files to commit), `cyanrip` is
# tests/fake-cyanrip and `curl` is tests/fake-curl serving the recorded
# MusicBrainz responses in tests/fixtures/. No network, no drive, no audio files.
# The real drive path is NOT covered here.
#
#   docker build -t media-ripper-cd:latest -f Containerfile.cd .
#   tests/run.sh

set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-media-ripper-cd:latest}"
BARCODE="042281827129"                               # Gerry Mulligan - Night Lights
NIGHT_RELEASE="b2c36d53-7454-4d03-91b7-a119a20af1cb" # fixture whose track lengths we synthesise
NUS_RELEASE="84a7f799-67f6-4f30-8230-a4d554d81a7f"   # Mão Morta - Nus (different durations)

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
OUT="$T/music"; IN="$T/in"; mkdir -p "$OUT" "$IN/album"
FAIL=0

pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }
check() { # description, command...
    local d="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi
}

# MusicBrainz / Cover Art Archive stand-in, mounted over curl.
FAKE_NET=(-e FIXTURES=/fixtures -v "$PWD/tests/fake-curl":/usr/local/bin/curl:ro -v "$PWD/tests/fixtures":/fixtures:ro)

# Synthesise 7 mono 8 kHz tones with the track lengths of the Night Lights
# fixture, so match validation (track count + durations) sees a real-looking disc.
docker run --rm --entrypoint bash -v "$PWD/tests/fixtures":/fx:ro -v "$IN":/in "$IMAGE" -c '
    i=0
    while read -r secs; do
        i=$((i + 1))
        ffmpeg -nostdin -v error -y -f lavfi -i "sine=frequency=$((200 + i * 60)):sample_rate=8000:duration=$secs" \
            -ac 1 -c:a pcm_s16le "/in/album/Track $i.wav"
    done < <(jq -r ".media[0].tracks[] | (.length / 1000 | floor)" /fx/release-'"$NIGHT_RELEASE"'.json)
    cp -R /in/album "/in/Gerry Mulligan - Night Lights [WAV]"' \
    || { echo "could not synthesise test audio"; exit 1; }

# cdr <args>: run the image with the fake cyanrip, our inputs and output.
cdr() {
    docker run --rm "${FAKE_NET[@]}" -e FAKE_SRC=/in/album -e CD_DRIVE_ID="TEST - DRIVE" -e CD_OFFSET=6 \
        -e FAKE_LOG=/music/fake-calls.log \
        -v "$PWD/tests/fake-cyanrip":/usr/local/bin/cyanrip:ro \
        -v "$IN":/in:ro -v "$OUT":/music "$IMAGE" "$@"
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

echo "== 2. match: preview, wrong release rejected, then save"
cdr match "$RIP" --barcode "$BARCODE" >"$T/m1.log" 2>&1
check "match finds Night Lights"           grep -q 'Night Lights' "$T/m1.log"
check "edition without a barcode field did not break the search" grep -q 'Matched: Gerry Mulligan' "$T/m1.log"
check "preview writes nothing"             test ! -f "$RIPDIR/release.json"
cdr match "$RIP" --barcode "0$BARCODE" >"$T/m1b.log" 2>&1
check "zero-padded barcode still matches"  grep -q 'Night Lights' "$T/m1b.log"
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
check "reports stored in the FLAC folder's extras/rip/" bash -c "test -f '$FLACDIR/extras/rip/rip.log' -a -f '$FLACDIR/extras/rip/rip.cue' -a -f '$FLACDIR/extras/rip/cyanrip-output.txt'"
check "AAC folder has no extras (no duplicate)"  test ! -e "$AACDIR/extras"
check "cover saved in extras/release/"           test -f "$FLACDIR/extras/release/cover.jpg"
check "cue points at the renamed tracks"         grep -q '"\.\./\.\./01 - ' "$FLACDIR/extras/rip/rip.cue"
check "raw FLACs removed after verified encode"  bash -c "! ls '$RIPDIR'/raw/*.flac"
check "no report copies left in RIP/"            bash -c "test ! -e '$RIPDIR/raw/rip.log' -a ! -e '$RIPDIR/cyanrip-output.txt'"
check "rip.json and release.json kept"           test -f "$RIPDIR/rip.json" -a -f "$RIPDIR/release.json"
check "rip.json lists both outputs"        bash -c "[ \$(grep -c '\"dir\"' '$RIPDIR/rip.json') -eq 2 ]"

echo "== 3b. raw already removed: a second encode still works and leaves the FLAC alone"
FSUM="$(sums "$FLACDIR")"
cdr encode "$RIP" --format aac >"$T/e2.log" 2>&1
check "AAC rebuilt from the existing FLAC"       bash -c "[ \$(ls '$AACDIR'/*.m4a | wc -l) -eq 7 ]"
check "FLAC folder byte-identical (not re-encoded)" test "$FSUM" = "$(sums "$FLACDIR")"
cdr encode "$RIP" --format flac >"$T/e3.log" 2>&1
check "--format flac refuses, points to update"  grep -q 'already exists' "$T/e3.log"
check "FLAC still intact after the refusal"      test "$FSUM" = "$(sums "$FLACDIR")"

echo "== 4. fix metadata without touching audio or reports"
LOG_BEFORE="$(shasum "$FLACDIR/extras/rip/rip.log" | cut -d' ' -f1)"
FLAC1="$(ls "$FLACDIR"/01*.flac)"; A_BEFORE="$(audio_md5 "/music/FLAC/Gerry Mulligan - Night Lights/$(basename "$FLAC1")")"
cdr update "$RIP" --artist "Gerry Mulligan Quartet" >"$T/u1.log" 2>&1
check "update preview changes nothing"     test -d "$FLACDIR"
cdr update "$RIP" --artist "Gerry Mulligan Quartet" --apply >"$T/u2.log" 2>&1
NEWF="$OUT/FLAC/Gerry Mulligan Quartet - Night Lights"
check "folder renamed on --apply"          test -d "$NEWF"
check "AAC folder renamed too"             test -d "$OUT/AAC/Gerry Mulligan Quartet - Night Lights"
A_AFTER="$(audio_md5 "/music/FLAC/Gerry Mulligan Quartet - Night Lights/$(basename "$FLAC1")")"
check "audio stream byte-identical after update" test "$A_BEFORE" = "$A_AFTER"
check "extras/ moved with the folder"      test -f "$NEWF/extras/rip/rip.cue"
check "rip.log byte-identical"             test "$LOG_BEFORE" = "$(shasum "$NEWF/extras/rip/rip.log" | cut -d' ' -f1)"
check "cue FILE names follow the new names" grep -q '"\.\./\.\./01 - ' "$NEWF/extras/rip/rip.cue"
check "AAC gapless info survived"          bash -c "docker run --rm --entrypoint bash -v '$OUT':/m:ro $IMAGE -c 'ffprobe -v error -show_entries format_tags=iTunSMPB -of default=nw=1 /m/AAC/*Quartet*/01*.m4a | grep -q iTunSMPB'"

echo "== 5. update a plain library folder (no rip folder)"
LIB="$OUT/lib"; mkdir -p "$LIB"; cp -R "$OUT/AAC/Gerry Mulligan Quartet - Night Lights" "$LIB/messy folder"
for f in "$LIB/messy folder"/*.m4a; do mv "$f" "$LIB/messy folder/$(basename "$f" | sed 's/^\([0-9]*\) - .*/\1 x.m4a/')"; done
docker run --rm "${FAKE_NET[@]}" -v "$OUT":/music "$IMAGE" update "/music/lib/messy folder" --barcode "$BARCODE" --artist "Gerry Mulligan" --apply >"$T/u3.log" 2>&1
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
docker run --rm --network none -v "$IN":/in:ro -v "$OUT":/music "$IMAGE" \
    -i "/in/Gerry Mulligan - Night Lights [WAV]" -f aac >"$T/l1.log" 2>&1
check "flat Artist - Album folders"        test -d "$OUT/FLAC/Gerry Mulligan - Night Lights" -a -d "$OUT/AAC/Gerry Mulligan - Night Lights"
check "Track NN names (no titles in files)" test -f "$OUT/AAC/Gerry Mulligan - Night Lights/Track 01.m4a"

echo "== 9. multi-disc"
rm -rf "$OUT/RIP" "$OUT/FLAC" "$OUT/AAC"
docker run --rm --network none -v "$IN":/in:ro -v "$OUT":/music "$IMAGE" \
    encode "/in/Gerry Mulligan - Night Lights [WAV]" --disc 2/3 >"$T/d1.log" 2>&1
check "Disc suffix only on multi-disc"     test -d "$OUT/FLAC/Gerry Mulligan - Night Lights - Disc 2"

echo "== 10. --keep-raw keeps the raw rip; --discard-master moves the reports to the AAC folder"
rm -rf "$OUT/RIP" "$OUT/FLAC" "$OUT/AAC"
cdr run --format aac --barcode "$BARCODE" --keep-raw >"$T/k1.log" 2>&1
check "raw FLACs kept with --keep-raw"     bash -c "ls '$OUT'/RIP/*/raw/01.flac"
check "reports also stored in extras/rip/" test -f "$FLACDIR/extras/rip/rip.log"
rm -rf "$OUT/RIP" "$OUT/FLAC" "$OUT/AAC"
cdr run --format aac --barcode "$BARCODE" --discard-master >"$T/k2.log" 2>&1
check "FLAC folder discarded"              test ! -d "$OUT/FLAC/Gerry Mulligan - Night Lights"
check "reports kept in the AAC folder"     test -f "$AACDIR/extras/rip/rip.log" -a -f "$AACDIR/extras/rip/rip.cue"
check "no raw audio left"                  bash -c "! ls '$OUT'/RIP/*/raw/*.flac"

echo ""
if [[ $FAIL -eq 0 ]]; then echo "All checks passed."; else echo "$FAIL check(s) FAILED. Logs kept in $T"; trap - EXIT; exit 1; fi
