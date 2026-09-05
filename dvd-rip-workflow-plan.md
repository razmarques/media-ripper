# Automate the DVD ripping workflow

> **Status: built 2026-09-04.** `~/.claude/skills/rip-dvd.md` and
> `~/Videos/CLAUDE.md` created. No changes to `dvd-ripper.sh`. Multi-disc
> handling kept as a light note only (per user — uncommon).

## Context

Ripping a DVD into the Plex library is currently a manual, multi-step sequence
around `~/bin/dvd-ripper.sh` (`rip` → identify main title → `scan` → read track
indices → `encode`). Every step has judgement calls: finding the release year,
picking the real feature file out of a dozen MakeMKV titles, and selecting the
European-Portuguese + English audio/subtitle tracks. The goal is to capture this
procedure so Claude can drive it consistently, and to record the standing
preferences (pt-PT + English always, Plex folder naming, keep raw rips) so they
don't have to be restated each time.

Deliverables are **documentation only** — a skill plus a `CLAUDE.md`. No changes
to `dvd-ripper.sh`. Claude runs this inside the distrobox where the media tools
live.

## Environment (verified 2026-09-04, inside the distrobox)

All tools present and on `PATH`:
`makemkvcon`, `HandBrakeCLI` (1.9.x), `mediainfo` (v24.01), `ffprobe`,
`mkvmerge`, `lsdvd`.

- **`/home/rodolfo/bin/dvd-ripper.sh`** — subcommands `rip`, `scan`, `encode`,
  `batch`. Shared flag parser, unknown flags fatal, no config files/env vars,
  `set -e`.
  - `rip` — no flags. Hardcodes output to `./output/` in CWD. Runs
    `makemkvcon -r mkv disc:0 all output || true`. MakeMKV names the files
    (`<label>_t<NN>.mkv`), one file per DVD title; the script never renames.
    Errors only if **zero** mkv produced.
  - `scan --input <file.mkv>` — runs `HandBrakeCLI -i <file> -t 1 --scan 2>&1`
    to stdout; `--save` also tees to `<file>_scan.txt`.
  - `encode --name <name> --input <file.mkv> --audio <i,j> [--subtitle <i,j>]`
    — audio/subtitle are **comma-separated 1-based HandBrake track numbers**.
    Writes `<name>.mkv` to **CWD**. Encoder: x264 RF21, preset medium,
    `--auto-anamorphic`, `--aencoder copy` per audio track (lossless),
    `--markers`, subtitle passthrough of the listed tracks.
  - `batch` — not used by this workflow.
- **Library layout** `/home/rodolfo/Videos/`: one folder per movie named
  `Movie Title (Year)`, a `output/` subfolder with the raw MakeMKV rips, and
  the encoded file in the movie folder. Existing:
  - `Man on Fire (2004)/` — `output/C1_t00.mkv` (5.48 GB) + 5 small extras;
    encoded `ManOnFire.mkv` (name not Plex-clean).
  - `Doutor Jivago/` — folder predates the `(Year)` convention; contains
    `Doctor Zhivago (1965) - Disc 1.mkv` (note the **`- Disc N`** multi-disc
    naming) and `output/A1_t00.mkv` (6.17 GB, but only **01:54:44** — this is
    disc 1 of a ~197 min roadshow film, i.e. NOT a complete feature).
  - `TheBeautyAndTheBeast/` — empty.
- **`~/.claude/skills/rename-dvd.md`** — existing flat-file skill (TV episodes).
  New skill sits beside it in the same style.
- No `CLAUDE.md` anywhere under `/home/rodolfo/Videos` yet.

### Findings from running the tools on the existing rips

1. **`mediainfo` per-track output is the reliable source of track identity.**
   `mediainfo --Output='Audio;#%StreamKindPos% %Language% %Channel(s)% %Title%\n'`
   (and `Text;`) prints normalized ISO codes (`en`, `pt`, `cs`, `pl`, `ru`…)
   and a 1-based per-kind position. That position **exactly equals HandBrake's
   track number** (verified: mediainfo and `HandBrakeCLI --scan` list tracks in
   identical order on `C1_t00.mkv` and `A1_t00.mkv`). `ffprobe` agrees.
2. **HandBrake's `--scan` shows languages in the disc's own localized spelling**
   (`čeština`, `polski`, `Portugues`, `العربية`) and its **subtitle** entries
   carry **no ISO code** — so parsing scan text for languages is unreliable.
   Use `mediainfo` for language→index, keep `scan --save` only as an artifact.
3. **`mediainfo` does not distinguish pt-PT from pt-BR** — DVD tracks are just
   `pt`. If a track ever reports `pt-BR`/`pob`, flag it; otherwise a lone `pt`
   track is assumed European.
4. **Chapter count is unreliable** on these MakeMKV rips (both mediainfo
   `%MenuCount%` and HandBrake `+ chapters:` show 0–1 for full features). Drop
   it from the certainty heuristic — use **duration + file size** only.
5. **PAL speedup is real**: Man on Fire (146 min theatrical) rips to
   `C1_t00.mkv` at **02:20:05 (140.1 min)** — 4.3% short at 25 fps. Duration
   tolerance must be percentage-based, not a fixed minute count.
6. **Both existing discs are Central-European pressings with NO Portuguese
   audio**, only a Portuguese *subtitle*. The "no pt audio" branch is the
   common case for this collection, not an edge case — it must not hard-stop.
7. **Multi-disc films happen** but are uncommon in this collection — kept as a
   one-line note in the skill (if the longest title is well under the known
   runtime, say so and ask), not a full branch.

## Decisions (from user)

| Topic | Decision |
|---|---|
| Tools | Run inside the distrobox; all tools confirmed installed. Skill still does a `command -v` preflight and stops with a clear message if run somewhere without them. Never install. |
| Main-title certainty | `mediainfo` duration + size vs. the official runtime from the release lookup. Auto-select only on a close match that is also the largest file; otherwise show the table and ask. |
| Raw rips after encode | **Keep** `./output/` untouched. |
| Skill scope | **Global**: `~/.claude/skills/rip-dvd.md`. |
| Track identity source | `mediainfo` per-track ISO code + position (== HandBrake index). `dvd-ripper.sh scan --save` is still run, as a saved artifact. |

## Plan

### 1. Create the skill — `~/.claude/skills/rip-dvd.md`

Flat markdown, same shape as `rename-dvd.md`. Frontmatter `name: rip-dvd`,
description triggering on "rip a DVD / rip this disc / dvd-ripper / rip a movie".
Body = the procedure below.

1. **Title & year.**
   - Ask the user for the movie title (AskUserQuestion); accept an optional
     year and/or "it's a 2-disc set" note in the answer.
   - If no year: `WebSearch`, cross-check ≥2 sources (IMDb / Wikipedia / TMDB).
     Capture the **official runtime** (needed in step 5) and the common English
     title.
   - Conflicting years/titles (remake vs original, festival vs wide release) →
     stop, list each candidate + source, ask via AskUserQuestion.

2. **Preflight.** `command -v makemkvcon HandBrakeCLI mediainfo`. Any missing →
   stop, tell the user to start Claude inside the distrobox. Never install.
   Also `makemkvcon -r --cache=1 info disc:0` (or `lsdvd`) to confirm a disc is
   actually readable before the long rip; surface its output on failure.

3. **Folder.** Target name `<Title> (<Year>)` (strip/replace `:` `/` `?`).
   Case-insensitively look for an existing folder under `/home/rodolfo/Videos/`;
   reuse it or `mkdir` it. `cd` in. Show the resolved absolute path and get a
   go-ahead before ripping.

4. **Rip.** `dvd-ripper.sh rip` from inside the movie folder → `./output/*.mkv`.
   Report `ls -lh output/`. Zero files → the rip failed; surface MakeMKV output
   and stop.

5. **Identify the feature file (certainty step).**
   - For every `output/*.mkv`:
     `mediainfo --Output='General;%Duration%'` (ms) + file size + resolution.
   - Compare each duration to the official runtime.
     Tolerance = **±8%** (covers 4.3% PAL speedup + listing variance).
   - **Auto-select** only when one file is BOTH the largest AND within
     tolerance of the runtime. Always print the full table + the choice.
   - Largest ≠ best-duration-match, or nothing within tolerance → print the
     table, ask the user (AskUserQuestion).
   - **Multi-disc guard:** if the best match is < ~80% of the known runtime and
     no file is near full runtime, tell the user this looks like disc N of a
     multi-disc release; ask whether to continue and name the output
     `<Title> (<Year>) - Disc N` (matching the existing Doctor Zhivago file).

6. **Scan artifact.** `dvd-ripper.sh scan --input ./output/<file> --save`
   (writes `<file>_scan.txt`). Not parsed for decisions — kept for the record.

7. **Pick tracks — European Portuguese + English, audio and subtitle.**
   Source of truth = `mediainfo` per-track:
   ```
   mediainfo --Output='Audio;%StreamKindPos%|%Language%|%Language/String%|%Channel(s)%|%Title%\n' <file>
   mediainfo --Output='Text;%StreamKindPos%|%Language%|%Language/String%|%Format%|%Forced%\n' <file>
   ```
   The `%StreamKindPos%` value is the HandBrake `--audio` / `--subtitle` index.
   - **Portuguese** = language `pt` / `pt-PT`. `pt-BR` / `pob` → show it and ask
     (probably skip). **English** = `en`.
   - Multiple candidates for one language:
     - audio → prefer the most channels (5.1 over 2.0); if still tied, ask.
     - subtitle → prefer non-forced full subtitle; if tied, ask.
   - **No Portuguese audio** (common here) → proceed with English audio only;
     still add both Portuguese + English **subtitles**. Inform the user, don't
     stop.
   - **No Portuguese subtitle & no Portuguese audio** → note it, continue
     English-only, no prompt needed.
   - Build the lists **Portuguese first, then English**, dropping any absent
     language, e.g. `--audio 2` / `--subtitle 7,3`.

8. **Encode.** From the movie folder:
   ```
   dvd-ripper.sh encode --name "<Title> (<Year>)" \
       --input ./output/<file> \
       --audio <list> [--subtitle <list>]
   ```
   Omit `--subtitle` only if there are genuinely no wanted subtitle tracks.
   Produces `<Title> (<Year>).mkv` in the movie folder.

9. **Verify & report.** Confirm the output exists; `mediainfo` it; check
   duration ≈ source file and that the expected audio/subtitle tracks are
   present and in pt-then-en order. Report final path + size.
   **Leave `./output/` in place.**

**Skill Notes section:** disc is always `disc:0` (single drive); `-t 1` always
(one DVD title per MakeMKV file); audio is never re-encoded (script forces
`copy`); HandBrake track numbers == `mediainfo` per-kind `StreamKindPos`;
duration tolerance ±8% for PAL; keep raw rips.

### 2. Create `/home/rodolfo/Videos/CLAUDE.md`

Concise. Sections:

- **Library conventions** — one folder per movie, `Movie Title (Year)`; multi-
  disc films use `Movie Title (Year) - Disc N.mkv`; raw MakeMKV rips kept in
  `./<movie>/output/`; encoded file lives in the movie folder. `Doutor Jivago/`
  predates the `(Year)` convention — leave it unless asked.
- **Ripping a DVD** — use the `rip-dvd` skill; backbone `~/bin/dvd-ripper.sh`
  (`rip` → `scan` → `encode`); must run inside the distrobox that has
  `makemkvcon` / `HandBrakeCLI` / `mediainfo`.
- **Standing preferences** — always European Portuguese + English audio and
  subtitles, **Portuguese track listed first**; many discs in this collection
  have Portuguese *subtitles only* — that's fine, encode English audio +
  both-language subtitles; keep raw `output/` rips; encode settings are fixed
  by the script (x264 RF21, lossless audio copy, chapter markers).
- **Identifying the feature** — never trust "largest file" alone; match
  `mediainfo` duration to the official runtime (±8%, PAL runs ~4% short);
  watch for multi-disc sets.
- **`dvd-ripper.sh` quick reference** — the three commands with exact flag
  syntax; track numbers are 1-based, comma-separated, and equal
  `mediainfo` `%StreamKindPos%`; `encode` writes `<name>.mkv` to CWD.

### 3. Sync the plan copy

Overwrite `/home/rodolfo/Videos/dvd-rip-workflow-plan.md` with this updated
plan so the on-disk copy matches.

## Critical files

- `~/.claude/skills/rip-dvd.md` — new (model on `~/.claude/skills/rename-dvd.md`)
- `/home/rodolfo/Videos/CLAUDE.md` — new
- `/home/rodolfo/Videos/dvd-rip-workflow-plan.md` — refresh existing copy
- `~/bin/dvd-ripper.sh` — reference only, **not modified**

## Verification

1. **Skill loads** — appears in `/skills`; description triggers on "rip a dvd".
2. **CLAUDE.md** — picked up when Claude starts in `/home/rodolfo/Videos`
   (check `/memory` / context).
3. **Dry-run the identification + track logic now, no disc needed:**
   - `Man on Fire (2004)/output/` → step 5 must pick `C1_t00.mkv` (5.48 GB,
     140.1 min ≈ 146 min −4.3%); step 7 must find **no `pt` audio**, English
     audio track **2** (5.1) over track 4 (2.0), Portuguese subtitle **7** +
     English subtitle **3**, and produce
     `--audio 2 --subtitle 7,3` without stopping.
   - `Doutor Jivago/output/A1_t00.mkv` → step 5 must flag it as **~114 min vs a
     ~197 min runtime → likely multi-disc**, not silently accept it; step 7
     would give English audio **1** (6ch), Portuguese subtitle **10**, English
     subtitle **1**.
4. **First real disc** — run the skill end to end on one DVD; confirm it pauses
   at the folder confirmation, the feature-file table, and any ambiguous-track
   prompt, and that the final `Movie Title (Year).mkv` plays in Plex with the
   pt/en tracks in the right order.
