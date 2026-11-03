# Familiar

Your Mac, searchable and listening. Three things, all running on your Mac, with nothing you have, say or ask leaving it:

- **Search**: describe a file in your own words and Familiar finds the document, PDF page, picture, recording or
  video moment that matches, even what was said in a recording.
- **Ask**: questions answered from your files and meetings, with the sources to click through to.
- **Speak**: hold a key and talk to type in any app; record meetings (your microphone and the call's sound, any meeting
  app, no bot joining) with a transcript, your notes and who said what.

Familiar's file search was inspired by [DigUp](https://github.com/ARahim3/DigUp) by Abdur Rahim, the open-source
search that first put EmbeddingGemma 2 to work on the files on your computer.

## Download and install

**Needs** an Apple Silicon Mac (M1 or later; Intel Macs aren't supported) with macOS 13 Ventura or later; speech (push
to talk and meetings) needs macOS 14 Sonoma or later. About 5 GB of downloads on first launch, and 8 GB of memory or
more. Speech is English only for now.

1. Download `Familiar.dmg` from the [latest release](../../releases/latest), open it, and drag Familiar to
   Applications.
2. Open Familiar. It isn't notarized by Apple yet, so the first time macOS says it can't check the app for malicious
   software:
   - **macOS 15 Sequoia and later:** click **Done**, open **System Settings → Privacy & Security**, scroll down to
     "Familiar was blocked…" and click **Open Anyway**, then **Open Anyway** again and enter your password.
   - **macOS 13 and 14:** right-click Familiar in Applications, choose **Open**, then **Open**.

   Or install from Terminal, which skips the warning (curl doesn't mark downloads as from the internet):
   `curl -L <link to Familiar.dmg> -o /tmp/Familiar.dmg && hdiutil attach /tmp/Familiar.dmg` and drag it across.
3. Follow the four short steps: **Get Started** (the models start downloading), the folders to search, the
   Microphone and Accessibility permissions (for speech; you can skip them), and a first try of push to talk.

**After an update**, macOS asks again for Accessibility (push to talk), because each version is signed on its own:
Familiar says so when it opens. Choose **Allow Again** and turn Familiar on in the list. Microphone and folder
access may be asked again too.

### Shortcuts from any app

| Key | What it does |
|---|---|
| ⌥Space | Search your files; press Tab to ask a question instead |
| Hold right ⌥ | Type by talking (let go to finish; tap twice for hands-free, press again to finish; Esc cancels) |

Meetings are recorded from the menu-bar icon (or ⌘R in the Familiar window). Settings → General changes the
shortcuts (and can give recording one); Settings → Push to talk changes its key to right ⌘ or fn.

## Build from source

```sh
./build.sh                      # → build/Familiar.app and build/Familiar.dmg
open build/Familiar.dmg      # drag Familiar to Applications
```

Building needs the Xcode Command Line Tools (Swift 5.10+), CMake and Ninja (`brew install cmake ninja`). The models are
downloaded by the app from Hugging Face, each at a pinned revision and checked against its SHA-256; a broken download
resumes where it stopped.

## Choosing what to search

Settings → **What to search** lists the folders and single files Familiar reads. Add them with **Add…** (folders and
files), by dropping them on the list, or with the suggestions (Desktop, Documents, Downloads…). Each row shows what's
in it (files by kind) and how it's doing: searchable, reading 120 of 353, waiting (and why), not allowed by macOS, or
not found. Click a row to open it in Finder; its ⋯ menu has Show in Finder, Check Again and Remove (which asks first and
never touches the files).

Something you add is read right away, even in Low Power Mode (at full speed on the charger, slowly on battery; a very
hot Mac still pauses). A folder waiting on power has an **Index Anyway** button that does the same.

## Using it

| Key | What it does |
|---|---|
| ⌥Space | Opens the search panel from any app (Tab switches to Ask) |
| ↓ ↑ | Moves through results |
| ↩ | Opens the result: recordings and videos in QuickTime at the moment that matched |
| Space (after moving) | Big preview: PDFs at the page with your words highlighted, media playing from the moment |
| ⌘↩ | Shows it in Finder |
| ⌘C | Copies the file |
| ⌘1 – ⌘5 | All, Documents, Pictures, Audio, Videos |

The menu-bar icon has the indexing status, Pause/Resume, and Settings.

Indexing keeps the GPU busy, so it watches power and heat (searching never slows down):

| Situation | Indexing |
|---|---|
| Low Power Mode on | paused |
| Mac very hot (macOS thermal state "critical") | paused |
| Mac hot ("serious") | slow |
| On battery | Settings → On battery: normally, slowly (default) or paused |
| Plugged in, normal temperature | full speed |

New files don't wait: a few new or changed files (up to 50) are read at full speed even while indexing is paused or
slow. A big pass that's held back makes way for them and resumes afterwards (30 s later when slow; when power allows
when paused). Pausing by hand still pauses everything.

Slow means one file at a time with a rest twice as long as the file took: about 5× slower than full speed (72
pictures: 59 s instead of 11 s). Changes in pace are logged to `Logs/app.log`.

## What it reads

- **Documents:** txt, md, rst, org, tex, csv, log; rtf, doc, docx, odt, html, webarchive (via `textutil`); xlsx, pptx,
  ods, odp (sheets' strings, slides' text and notes); Pages, Keynote and Numbers (their preview PDF)
- **PDFs:** page by page (up to 1,000 pages). A scanned page with no text layer is embedded as a picture and its text
  is read with Vision OCR
- **Pictures:** jpg, png, heic, webp, gif, tiff and more, by what they show. Screenshots also have their text read
  (OCR), so exact codes and error messages match
- **Audio:** mp3, m4a, wav, aac, aiff, flac, caf in overlapping 10-second windows, a new one every 5 s, so a match
  points to its moment. Chosen with `fam eval` over 30 s every 25 s: first-place hits 0.93 vs 0.80 on 15 audio
  queries, for the same GPU time
- **Video:** mp4, mov, m4v: a frame every few seconds (skipping frames that look like the last one), plus the
  soundtrack like audio

It never reads keys, certificates, credentials or password files: by name (`id_rsa`, `.pem`, "credentials",
"password", "recovery codes", …) and by content (a private-key block or a cloud access key in any text it reads: a
document, a PDF or slide, the text in a picture or screenshot, a recording's transcript). Such a file stores nothing
and is listed as skipped. csv, tsv and log files are read only with Settings → "Read data files" on. It skips hidden folders, app bundles and libraries (Photos, Music), dependency and build folders (`node_modules`,
`.venv`, `build/` in code projects), folders with 3,000+ files (datasets), and iCloud files that aren't downloaded
(it never downloads them). It only reads files; it never changes, moves or uploads them.

## How it works

```
your folders ─► FolderScanner (what changed since last time)
             ─► readers: text chunks, PDF pages, pictures sized for the vision encoder,
                16 kHz mono 10 s audio windows, video frames
             ─► llama-server (bundled, Metal) running EmbeddingGemma 2 + its image/audio encoder
             ─► index.sqlite: a vector per chunk/page/picture/frame/window + an FTS5 keyword index
your words   ─► "task: search result | query: …" ─► the same model ─► cosine against every vector
             (Accelerate; 8-bit: NEON SDOT) + exact-word boost ─► best piece of each file ranks the file
```

- **Engine** (`Sources/FamiliarCore`): `EmbeddingModelFiles` (pinned download + checksum), `EmbeddingService` (runs the
  bundled `llama-server` on a private localhost port: an indexing server with the text and image & audio parts, which
  stops after 5 idle minutes, and, with Settings → "Keep a search model loaded" (on by default), a text-only search
  server, ~200–330 MB and always loaded, so searches don't wait behind indexing: 17 ms instead of 286 ms while
  indexing pictures), `FolderScanner`, `Extractors` / `Media` (readers), `Ingestor` (3 files at a time), `Catalog`
  (SQLite + FTS5), `Lookup` (hybrid ranking; keeps every vector in memory and, as the index changes, reads only
  the new rows and marks deleted ones, instead of reloading: ~9 ms instead of ~140 ms per search at 100k vectors),
  `VectorKernels` (the scoring arithmetic: Accelerate for 32-bit floats; for 8-bit vectors the C kernel in
  `Sources/Int8Kernels`, which uses the NEON int8 dot-product instruction, SDOT).
- **Int8 kernel** (`Sources/Int8Kernels`): C, because Swift can't reach SDOT; four rows at a time, the dot products
  summed exactly as 32-bit integers, so results are the same as plain arithmetic. A million 8-bit vectors on one core:
  10.6 ms instead of 25.5 ms for the Swift loop it replaced (M4 Max, `fam bench-vectors --threads 1`).
- **App** (`Sources/FamiliarApp`): AppKit + SwiftUI menu-bar app: search panel, preview, setup/settings, FSEvents
  folder watcher (new files are searchable seconds after they land), Carbon global hotkey.
- **CLI** (`Sources/fam`): the same engine from the terminal:

  ```sh
  swift build -c release
  .build/release/fam download                 # the model
  .build/release/fam index ~/Documents        # index a folder
  .build/release/fam search "the clause about pets in the lease"
  .build/release/fam status
  .build/release/fam latency ~/Pictures [--shared]   # search speed while indexing, with or without the search server
  .build/release/fam selftest                        # incremental vector loading vs full reloads, on temporary indexes
  .build/release/fam bench-vectors [--threads 1]      # 8-bit vs 32-bit search speed and agreement, synthetic vectors
  ```
  `FAMILIAR_INDEX=/tmp/test.sqlite` points it at a separate index for testing.

Documents are embedded with the model card's prompt `title: {file name} | text: {chunk}`, queries with
`task: search result | query: {words}`; pictures and sound take no prompt.

## Memory

Settings → Memory use: Automatic picks **Low** on Macs with 12 GB or less, **Standard** otherwise.

| | Standard | Low |
|---|---|---|
| Indexing model (while indexing, then unloaded) | 4 slots × 2,048 tokens, peak ~2.6 GB, unloads after 5 idle min | 2 slots × 1,024 tokens, peak ~1.85 GB, unloads after 1 idle min |
| Search model (~0.2–0.3 GB, always loaded) | on by default | off by default |
| Vectors in memory | 32-bit floats (100k pieces: 293 MB) | 8-bit, best 1,000 rescored exactly (100k: 74 MB, same top results; scored with SDOT, faster than 32-bit) |

The app itself peaks around 330 MB while indexing and settles near 100 MB. Measured on an M4 Max; a Mac with fewer
graphics cores indexes proportionally slower (a base M1 roughly 4–5× slower, estimated, not measured).

## Evals

`scripts/make-test-collection.sh` builds a test collection with known answers in `build/testbed` (93 files: macOS's own account
pictures, drawn screenshots and ID cards, documents, PDFs with facts on known pages, a scanned receipt, slides,
spoken audio and video with topics at known seconds, five other languages, and traps: duplicates, odd names, a hidden
folder, `node_modules`, an app bundle, a tiny icon, build output). Nothing personal, no downloads.

```sh
scripts/make-test-collection.sh
.build/release/fam eval evals/core.json --json /tmp/now.json                          # score search
.build/release/fam eval evals/core.json --json /tmp/after.json --baseline /tmp/now.json  # compare with an earlier run
```

`fam eval` reports Recall@1/5/10, MRR, nDCG@10, the margin (best right answer minus best wrong one), whether the page
or moment is right, and files that must not appear, per tag; then every miss with what came first instead. Settings for
A/B runs come from the environment: `FAMILIAR_BUDGET_PHOTO|SCREENSHOT|PAGE|FRAME`,
`FAMILIAR_AUDIO_WINDOW` / `FAMILIAR_AUDIO_HOP`, `FAMILIAR_MEMORY`. Give each its own `--index`. A query can point
at a part of a recording by number (`audio/radio-show.m4a@seg3`): the generator writes each recording's parts to
`<file>.segments.json`.

Picture detail (soft tokens) was chosen this way: photo 140, screenshot 280, scanned page 280, video frame 70 ranked
all 99 queries the same as 280 / 280 / 560 / 140 and read pictures about twice as fast.

`analysis/` (Python, not part of the app) holds what `fam` doesn't do. It tests the 8-bit C kernel against exact
NumPy arithmetic, keeps a separate copy of the 8-bit search, and measures how much of the exact top 10 survives each
shortlist size. It also compares `--json` reports query by query, with 95% intervals, so a change can be told apart
from noise. See [analysis/README.md](analysis/README.md).

## When things go wrong

- **A folder macOS won't open** (privacy settings): Settings lists it with a button to the Privacy settings; its files
  aren't searchable until access is allowed.
- **A damaged index**: found when it's opened, while it's used, or by a full check in the background after each launch.
  The damaged file is kept as `index.damaged.sqlite` (the latest only), a fresh index is started and every folder is
  read again. Your files are never touched.
- **Other programs** can't use the model: each server start makes a random password, handed over in a file only you
  can read (removed once the server is up), and every request must carry it.
- **Logs** (`Logs/`) roll over at 1 MB, keeping one older file each; the model servers log only warnings and errors.
- **New, changed and deleted files**: the folder watcher passes the exact paths, and only those are checked. Every
  folder is checked at launch, every 30 minutes, and whenever macOS says it lost track of changes.

`fam selftest` and `fam selftest-changes` (needs the model) check these, plus incremental vector loading.

Testing the app without touching the one you use: `scripts/make-test-app.sh` makes `build/FamiliarTest.app` with its
own bundle id (so its own settings and no hand-over to your copy). Launch it with `FAMILIAR_INDEX` (a test index),
`FAMILIAR_LOGS` (test logs) and `FAMILIAR_NO_HOTKEY=1`, and test-only switches such as `-debugPower lowpower`,
`-debugAdd <path>`, `-debugSettings YES`, `-debugIndexAnyway YES`. Each copy's model servers are tracked per owning
process, so copies never stop each other's.

## Data and removal

Settings → Storage shows what each part takes on disk (about 0.8 GB for search, 2.6 GB for Ask, 1.1 GB for speech, plus
the index and meeting audio at about 30 MB an hour) and removes the Ask or speech models if you don't use them (they
download again when turned back on). **Keep meeting audio** (Always, 30 days, 90 days, 1 year) deletes older
recordings; their transcripts and notes stay.

Everything lives in `~/Library/Application Support/Familiar`: `Models/` (the models), `index.sqlite` (the index),
`Logs/`. Meetings are saved in `~/Documents/Familiar Meetings` (their recordings in its hidden `.recordings`
folder). Settings are in `~/Library/Preferences/io.github.kaushicaravind2000.Familiar.plist`. To remove Familiar, quit it,
delete the app and those, and remove it from System Settings → Privacy & Security → Accessibility.

## Sharing the app

`build.sh` signs ad-hoc unless there's a signing certificate. Every Mac but the one that built it says the app can't
be checked the first time (see Download and install). Two ways to do better:

- **Keep permissions across updates (free):** `scripts/make-signing-identity.sh` makes a certificate of your own, and
  `build.sh` signs with it from then on. macOS then keeps Accessibility, Microphone and folder permissions from one
  version to the next. Keep the `.p12` it leaves somewhere safe and never commit it: anyone with it can sign as you.
- **No warning at all:** an Apple Developer ID ($99 a year) and notarization: `SIGN_ID="Developer ID Application: …"
  ./build.sh`, then `xcrun notarytool submit build/Familiar.dmg …` and `xcrun stapler staple build/Familiar.dmg`.

## Credits

The models and libraries Familiar uses, with their licenses, are in [CREDITS.md](CREDITS.md) and in the app's
About box. In short: EmbeddingGemma 2 (Google DeepMind, Apache 2.0), Qwen3.5-4B (Qwen team, Apache 2.0), Parakeet
Unified 0.6B (licensed by NVIDIA Corporation under the NVIDIA Open Model License), LocalVQE (Apache 2.0), pyannote
community-1 with WeSpeaker and BUT Speech@FIT (CC BY 4.0), Core ML conversions by Fluid Inference, llama.cpp (MIT),
FluidAudio (Apache 2.0). Gemma is a trademark of Google LLC.
