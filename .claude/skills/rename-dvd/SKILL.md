---
name: rename-dvd
description: >-
  Rename video files in the current directory to Plex-compatible names based
  on a DVD or release title, by looking up the episode list online and
  matching files in order. Use when the user wants to rename ripped/encoded
  video files to match episode titles, or mentions renaming a DVD/series
  output.
---

# rename-dvd

Automates renaming video files in the current directory to be Plex-compatible, based on a DVD or release title.

## Steps

1. Ask the user: "What is the title of the DVD or release?" using AskUserQuestion.

2. Search the web for the episode list of that DVD/release. Use sources like the Shaun the Sheep Fandom wiki, epguides.com, IMDb, or similar databases. Find:
   - The **show name** (e.g. "Shaun the Sheep")
   - The **season number** for each episode
   - The **episode number** for each episode
   - The **episode title** for each episode

3. List the video files in the current working directory (mkv, mp4, avi, etc.), sorted by filename.

4. Match each file to an episode in the order they appear (first file = first episode on the DVD, etc.), cross-checking the episode number and title.

5. Rename each file using the Plex naming convention:
   `Show Name - SXXEXX - Episode Title.ext`
   Example: `Shaun the Sheep - S01E01 - Off the Baa!.mkv`

6. Show the user the final list of renamed files and confirm success.

## Notes
- If episode order on the DVD is ambiguous, note it and ask the user to verify.
- Preserve the original file extension.
- If a file count doesn't match the episode count found, warn the user.
