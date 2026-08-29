# Roadmap progress

Completed work only. Items move here from `roadmap.md` when done — they are
removed from the roadmap, not left checked off in both places.

These two files are the only work-tracking documents in the project.

## Entry format

```
### YYYY-MM-DD — Short title
**Phase:** N
**What:** One or two lines on what actually landed.
**Rationale:** Only if a decision was made or reversed. Otherwise omit.
**Follow-on:** Anything this created that now belongs in roadmap.md.
```

Keep entries short. The rationale field is the valuable part — it is where a
reversed decision gets explained, and it is the reason this file exists rather
than a git log.

---

### 2026-08-29 — Tailwind for the layout, React Aria kept

**Phase:** 6

**What:** `ui/src/styles.css` goes from 1548 lines to 320. Every component
carries its own appearance as utility classes; the palette moves into a
Tailwind `@theme` block, and twelve looks worn by more than one element
(button, field, hint, warning, popover card, focus ring) are declared once as
`@utility`. What is left in the file is the two rules that must outrank
MapLibre's own stylesheet, the loading bar's keyframes, and the reduced-motion
block. React Aria Components stay exactly where they were — the plugin
`tailwindcss-react-aria-components` turns their data attributes into variants,
so `selected:`, `expanded:` and `focus-visible:` are written beside the thing
they restyle.

**Rationale:** Reverses the React Spectrum adoption of the previous day, at
the user's instruction: it worked and it shipped offline, but it looked wrong
for this application. Eight commits were reset rather than reverted (they were
unpushed) and are kept at the tag `spectrum-attempt`.

The measurement that started the first attempt was right and the remedy was
wrong. The stylesheet held twenty-two distinct spacing values, twelve font
sizes and nine border radii — the layout read as rough because nothing lined
up, not because the controls were homemade. Spectrum replaced the controls and
left every gap between them untouched, which is why it did not fix the
complaint. A scale does.

Two things could not be moved to a class list and the reasons are worth
keeping. `.map-wrap > .map` must stay a two-class CSS selector: MapLibre sets
`position: relative` with no height on the same element from a stylesheet that
loads after this one, and a Tailwind utility is one class, so it would lose
the same race the bare `.map` rule lost. `.maplibregl-ctrl-*` is MapLibre's
own element — there is nothing of ours to put a class on.

Colour is now a prop rather than a class on `IconButton`, and the concealed
address is a conditional rather than a modifier class. Two utilities setting
the same property do not resolve by the order they appear in the markup; they
resolve by where Tailwind put them in the sheet. A state a control can be in
must not be decided there.

**Follow-on:** `test/contrast.mjs` reads the `@theme` block and now scans the
components as well as the stylesheet — a colour written as an arbitrary value
on an element is still rendered, and the old check would have read that as
deleting it. The gate payload is 193 KB against 189 before Tailwind and 265
under Spectrum.

### 2026-08-28 — One file per region

**Phase:** 6

**What:** A download writes its own archive rather than merging into
`map.pmtiles`. `Tile_set` lists the basemap directory instead of naming three
files, remembers each archive's header, and opens only the ones whose bounds
could hold the tile asked for. Each region file carries its own one-entry
ledger, so the list the user sees is the union of what is on disk; removing a
region is an unlink, and exporting one is handing over a file that already
exists. The search index is built across every archive, sharing one table so a
city held by two overlapping regions resolves to one row.

**Rationale:** Asked how CoMaps and Organic Maps handle this. They do not
stream and they do not merge: one file per country, downloaded whole, read
alongside the others. The tile path here was already generic over a list of
archives — `open_tile_archives` took names and `serve_tile` walked them with
`find_map` — so the list being a directory rather than three constants was a
smaller change than the merge it replaces. What it buys is that export stops
existing as work: the wait between "downloaded" and "can I have the file" was
the cost of undoing a merge. What it costs is dedup across regions, which is
the trade Organic Maps makes too.

Two decisions were reversed while writing it. The record is published with
every part rather than only the last, so a cancelled download leaves a region
that can be named and removed instead of tiles stranded in the shared archive.
But dating it only on the last part — so an unfinished download would read as
"age unknown" — was wrong: parts overlap at their seams and the last part of a
finished download routinely writes nothing, so it dated finished downloads as
unfinished. Every part dates the entry; what an interrupted region is missing
is a question the map's coverage shading already answers.

An estimate for a region no longer refuses a source whose compression differs
from what is on disk, because nothing merges them: each archive is read
through its own header, so two regions in two compressions are two files that
both draw. A browse still refuses — it writes into the cache, and the cache is
folded into `map.pmtiles`.

**Follow-on:** `map.pmtiles` is read but no longer written by the downloader.
A migration that split it into region files on first run would retire the
export path, the prune-on-remove path, and the last reason `Merge.prune`
exists. Recorded in `roadmap.md`.

---

### 2026-08-28 — The end-to-end suite gets its own port

**Phase:** 6

**What:** The app under test moved off `$(PORT)` (7373) onto `$(E2E_PORT)`
(7379). Every other server the suite starts already had a port of its own --
fixture, multipart, mismatch, cancel, proxy, 7374-7378 -- and this one shared
with `make run` and the new `make dev`.

**Rationale:** Found by leaving the development stack up and running the
suite. The collision does not announce itself: the server dies on bind, the
run continues against nothing, and what surfaces is four unrelated map
download checks failing. A conflict that reads as a product bug costs more
than one that stops the run outright.

---

### 2026-08-28 — dune-project declares what the dune files actually use

**Phase:** 6

**What:** Twelve libraries were named in a `dune` file and absent from
`(depends)`: `uunf`, `stdint`, `ppx_deriving`, `ppx_deriving_yojson`, `eio`,
`tls-eio`, `mirage-crypto-rng`, `ca-certs-nss`, `domain-name`, `uri`,
`bigstringaf`, and `http` (tests only). `tools/check-deps.sh` compares the two
lists and now runs in `make test-core`.

**Rationale:** Found by building this project on a machine that had never
built it: `tools/setup.sh` completes, reports everything present, and then
`dune build` fails on four separate missing libraries. Some of the twelve were
being satisfied transitively and so worked by accident; the rest had simply
never been needed by anyone whose switch was old enough.

CI cannot see this. Its switch is restored from cache, so it holds whatever an
earlier solve happened to install, and `opam install . --deps-only` is a no-op
against it. The only person who meets the bug is someone setting up from
nothing -- which is exactly the audience `tools/setup.sh` exists for. A check
that diffs the two lists costs no network and no switch, and catches the whole
class rather than these twelve.

### 2026-08-28 — Maps can be carried to a machine with no internet

**Phase:** 6

**What:** Three things, which together make an offline machine's map library
maintainable without ever giving it a network.

A downloaded region can be written out as a file (`basemap-export`), listed
and saved from the download card, and deleted when it has been copied away.
The exported archive carries a ledger of its own holding just that entry, so
the far side reads the region, the granted depth and the name out of the file
rather than having them typed in.

A map file can be added through the browser's own file picker
(`POST /import`, then `basemap-import`). The upload streams to disk under a
new route, is described back to the user before anything is merged, and is
then handed to the ordinary download path as its source — so the merge, the
ledger entry, the browse-cache prune and the search-index rebuild are the
same code that a networked download runs.

Download progress is now per region. `Merge.write` hands the blob index to
its copy callback, the download attributes each fresh blob to the pick that
asked for it, and `Basemap_job.Fetching` carries a row per region. The rows
live in the side panel rather than the download card, so closing the card
does not hide an hour of work.

**Rationale:** Import is deliberately not a new kind of download.
`Pmtiles_source.open_url` already falls through to a plain file, and
`run_download` already merges from whatever source it is given, so pointing
it at an uploaded file reuses every downstream guarantee instead of growing a
second path that would drift. The machine using this feature is the one with
no way to fetch a fix, which makes "no second path" worth more here than
anywhere else in the project.

The upload gets its own route rather than an `/api/` endpoint because every
`/api/` body is read whole under a 4 MiB bound. That bound is right for every
other endpoint and wrong for a country. `Api_guard.check_stream` keeps the
same-origin check and requires `application/octet-stream`, which is off the
CORS safelist for the same reason `application/json` is — a form post cannot
reach it.

A browser file picker rather than a path box or a server-side file browser:
it is the only one of the three that works under Flatpak, where the app has
no filesystem permission at all and the browser is outside the sandbox. It is
also the only one that reaches a USB stick without this app knowing what a
USB stick is.

Per-region bytes count what the network delivered, not archive bytes written.
A merge copies the whole base archive forward, and crediting Tokyo with the
gigabyte of London already on disk would read as Tokyo downloading a gigabyte
it never asked for. A tile two picks both wanted is charged to the earlier
one, so the rows cannot sum past what was fetched.

**Follow-on:** Six items in roadmap.md, Phase 6: no release job publishes the
packages any of this assumes someone can install; the `tessarium-basemap` CLI
still replaces rather than merges, and the shipped `README.txt` claims
otherwise; a hand-copied archive still gets no search index; an export
duplicates its region with no free-space check; an imported file is trusted on
its face where a download is not; and exports are one region at a time.

### 2026-08-26 — Built packages are installed and run before they ship

**Phase:** 6 · **Branches:** test/install-smoke, build/arch-from-binary

**What:** `tools/test-install.sh` unpacks a built package into a throwaway
root, launches it through the installed launcher from an empty directory with
a private data home, and checks it serves the application, a world tile,
label glyphs and map icons from the packaged map alone. Wired into
`make test-install` and into the CI job that already produces packages.
`tools/target-arch.sh` reads the ELF machine type out of the built binary, so
the tarball, `.deb` and AppImage name the architecture they were actually
built for instead of `uname -m`, `amd64` and `x86_64` respectively.

**Rationale:** Every other test in this project runs against the source tree.
The failures that matter after installation cannot be seen from there: the
map installs read-only under `/usr`, the launcher is the only thing that
redirects the app somewhere writable, and a menu entry starts it in an
arbitrary directory. A package could pass every existing check, build
bit-identically, and still open on a blank planet.

Architecture had the same shape of hole. All three packagers were correct
until the first cross-compile and then silently wrong: a package labelled
amd64 that installs cleanly and cannot execute a byte of what is inside it.
Reading it from the binary is right for native and cross builds alike, and an
architecture the helper does not know is an error rather than a guess.

**Falsified:** five broken packages — map removed, launcher stripped of its
redirect, desktop entry naming a command not shipped, icons removed,
architecture field rewritten. Each failed exactly the checks that name it.
The helper was falsified against a synthetic aarch64 header, a RISC-V one and
a non-ELF file; the last exposed the same `pipefail` trap
`check-glibc-floor.sh` hit, where the script dies at the assignment and the
explanation is never reached.

**Follow-on:** The check pulls a package apart rather than installing it. A
real `dpkg -i` or `dnf install` — scriptlets, desktop database, icon cache —
still needs a container.

---

### 2026-08-26 — An .rpm, built and verified

**Phase:** 6 · **Branches:** feat/package-rpm

**What:** `tools/package-rpm.sh` builds the same payload the `.deb` installs,
for Fedora, RHEL and its rebuilds, and openSUSE. `%_topdir` inside the tree
so it needs no root. 18 MB, and byte-identical across rebuilds. The install
check reads `.rpm` as well as `.deb`, and CI installs `rpm` and `file` and
builds it alongside the other two.

**Rationale:** Three settings decide determinism and none of them defaults
usefully: `%_buildhost` (rpm records the machine's hostname),
`use_source_date_epoch_as_buildtime` (rpm stamps wall-clock time and defaults
this off), and `%_binary_payload`. xz for the payload rather than rpm's
newer zstd default, which RHEL 8 and older cannot read — and it is also the
smallest of the three tried, 18 MB against 24 for zstd and 28 for gzip.

Unlike the `.deb`, the glibc requirement is not written down: rpm derives it
per symbol version from the binaries. That is finer than a single floor, and
it fails in a way a written number cannot — if rpm does not recognise the
binaries as ELF it says nothing and produces a package declaring no
dependencies at all, which installs happily on a system far too old to run
it. So the packager reads its own output back and refuses to hand over an
rpm with no glibc requirement. `check-glibc-floor.sh` still runs, because its
job is to catch the floor DRIFTING, which a dependency generated from
whatever it was handed cannot notice.

**Falsified:** dependency generation switched off with rpmbuild still
succeeding — the packager refused, naming the likely cause. An rpm built
with `--target aarch64` around x86_64 binaries — the install check caught the
mismatch. rpm refuses to mislabel this way without `--target`, which is why
the end-to-end tamper for the shared architecture check is the `.deb` one.

**Follow-on:** None.

### 2026-08-25 — The system floor is measured, not assumed

**Phase:** 6 · **Branches:** build/glibc-floor-check

**What:** Which systems the binaries will actually run on was decided by the
build host and written down nowhere a release builder would see.
`tools/check-glibc-floor.sh` now reads the floor back out of the finished
binaries, fails the build if it exceeds what the project declares, and prints
what that floor excludes. All three packagers call it.

The tarball's README used to say "a 64-bit Linux system. Nothing else", which
was false — it needs glibc 2.35. It now names the version and the distributions
that are therefore out, with the number substituted from the measurement rather
than typed, and the build fails if the substitution did not happen.

**Rationale:** The check cannot lower the floor; only a different build host
can. What it prevents is the floor drifting upward unnoticed when a build image
is updated, and that matters most for the one format that cannot warn anybody:
a .deb refuses to install and says why, while an AppImage or a tarball simply
dies on launch. "Runs anywhere" is the whole of what an AppImage is for, and it
carries no metadata that could catch the mistake.

**Falsified** twice, on exit codes rather than on messages. Declaring a floor
of 2.30 while the binaries need 2.35 stops packaging with exit 1. Pointing the
check at a file objdump cannot read stops it too — that one first died at the
assignment with only objdump's own complaint, because `pipefail` swallowed the
branch that explains it; it now reaches its own message.

**Follow-on:** the roadmap item is narrowed to what is left, which is a build
host old enough to lower the floor.

---

### 2026-08-25 — Shipped builds carry no source maps

**Phase:** 4 · **Branches:** build/no-sourcemaps

**What:** `vite.config.ts` set `sourcemap: true`, so two `.map` files were
compiled into the server binary and travelled in every package. No visitor
ever downloaded one — a browser fetches a source map only with developer
tools open — so this was package weight rather than load time. Now off.

| | before | after |
|---|---|---|
| `ui/dist` | 9.3 MB | 3.3 MB |
| server binary | 24.4 MB | 23.1 MB |
| tarball | 29 MB | 28 MB |
| .deb | 23 MB | 22 MB |

**Rationale:** The decision the old roadmap item asked for is whether a
shipped build should be debuggable at all. It should not: debugging happens
against a development build, where `vite dev` emits maps whatever this
setting says, and anyone who wants a debuggable release has the source and
one line to change.

Worth recording that the saving is smaller than the raw figures suggested.
The maps were 6.1 MB of 8.1 MB of raw assets — three quarters — but they are
gzipped into the binary and source maps compress extremely well, so the
binary lost 1.3 MB rather than 6. The roadmap item quoted the raw share,
which was true and misleading; the compressed number is the one a user pays.

---

### 2026-08-25 — The map follows the interface language

**Phase:** 6 · **Branches:** fix/map-follows-language

**What:** Choosing French translated the controls and left the map in English
until something else happened to rebuild the style — a download or a removal.
The style asks Protomaps for labels in the interface language, and it reads
that language once, when it is built. A language change now rebuilds it, the
same way a download does.

**Rationale:** Skipped on the first render, because the map was created with
the current language already and rebuilding on mount would throw away the
style it just loaded. The comment above `basemapLayers` promising that place
names follow the interface language now describes the behaviour rather than
the intent.

**Falsified**, and the first attempt was wrong in an instructive way. It
checked that the style stopped asking for English after the switch; Protomaps
keeps `name:en` in every style as the fallback for a place with no name in the
chosen language, so that assertion was about the library rather than about
this project. The check is now the absence of French before the switch and its
presence after, which fails with the rebuild removed.

---

### 2026-08-25 — The README and the FE1 write-up are true again

**Phase:** 6 · **Branches:** docs/refresh-readme-and-fe1

**What:** An accuracy pass over both documents, with tightening as the smaller
half of it.

Corrected in `docs/fe1-security.md`: the oracle arithmetic still quoted 81 µs
per encode, which is the HMAC-SHA256 figure from mapping v1, in a document
that names keyed BLAKE2s two paragraphs earlier. It is 56 µs, so an
unthrottled oracle answers a million queries in under a minute rather than
under two. The limiter figures downstream of it were already right.

Corrected in `README.md`: 8 extracted modules is 10; 227 vector checks is
231; the two hand-written shims are 142 and 133 lines, not 130 and ~118; and
the extraction was watched by "three checks" in one paragraph and "four legs"
in another. The `fstar/low/` section still described the machine-integer port
as "now underway" with the grid, table and codec stages yet to come — all of
it landed on 2026-08-20, and both hosts have answered from the emitted C
since.

Removed: the "Name" section, which warned that the Cryptomeria cipher was a
near-neighbour with an awkwardly shared round count. The rename to Tessarium
made the names unalike, and sixteen rounds made the round count unshared.

**Rationale:** The prose in both places had drifted the way prose does — each
individual claim was true when written. What makes that dangerous here is
that these are the two documents a reader uses to decide what to believe
about the proofs, so a stale number in them is worth more than a stale number
in a comment.

Tightening was deliberately the smaller half: the FE1 write-up lost 9% of its
words, the README 3%. Most of the README's length is the section that says
exactly what is and is not proved, and thinning that to hit a word count
would trade the property the document exists for. What did change there is
shape — two walls of text became lists, which is what the writing rule in
CLAUDE.md is actually asking for.

---

### 2026-08-25 — The detail source stops asking for tiles nobody has

**Phase:** 6 · **Branches:** fix/detail-source-asks-honestly

**What:** `/tiles.json`'s `maxzoom` was answering two questions at once. It
tells MapLibre how deep to request, and the browser was clamping the coverage
query to it as well — so an archive holding no detail had to advertise depth
15, and the cost was a viewport of empty tile fetches on every pan. Measured
at 11 across three street-level pans in the test's small viewport.

The clamp moved to the server, where it is taken against the archives that
actually hold detail rather than against a number the client reads off a
document. `/tiles.json` can then say what is true: with nothing downloaded it
advertises an empty range, which is a source that requests nothing at all.
The browser sends the zoom it is really looking at and stops inspecting the
source.

**Rationale:** The clamp itself is real and had to stay somewhere — past an
archive's depth MapLibre overzooms the deepest tiles it has instead of asking
for more, so a query at the camera zoom would report a blank that is not on
screen. What was wrong was where it lived. Only the server knows how deep the
downloaded archives go, and making the browser derive it from a served
document forced that document to lie.

The clamp counts the DETAIL archives only. Counting the world overview too is
the obvious-looking version of this change and is wrong: it drags every
question down to the overview's own zoom, where the answer is "present" and
the offer to download the area on screen never appears — in the one state
where offering it is the entire point.

Urgent because of the packaging work earlier the same day: every fresh
install now starts with an overview and no region, so what used to need a
deliberate command-line fetch to reach became the state every new user began
in.

**Falsified** four ways. Restoring the advertised 0-15 fetches 11 empty tiles
across three pans. Removing the clamp entirely answers a street-zoom question
about tiles no archive holds. Clamping against every archive rather than the
detail ones — the naive version of this fix — passes every other check in the
suite and fails exactly one: the note offering to download the area
disappears. And the same substitution fails the two server checks about an
overview-only directory.

---

### 2026-08-25 — The icons ship with the licence they are under

**Phase:** 6 · **Branches:** docs/sprite-licence

**What:** The bundled map icons were conveyed as "under that project's own
terms", which named nothing. Confirmed upstream: protomaps/basemaps-assets
states in its README that its sprites are derived from the MIT-licensed
tangrams/icons project, (c) 2017 Mapzen.

MIT requires its notice to travel with the copies, and neither upstream
project ships a licence file beside the icons — so `tools/stage-bundle.sh`
writes one into the payload, saying where the icons came from and reproducing
the MIT text. The .deb's copyright file and the tarball's README now name the
licence and the holder instead of gesturing at them.

Staging refuses to produce a package if either notice — the fonts' `OFL.txt`
or the icons' `LICENSE.txt` — is missing or empty. Redistribution is the
whole of what a package does, and a missing notice is invisible until
somebody goes looking for it.

**Rationale:** The notice is written by us rather than copied because there
is no file upstream to copy. That is stated in the notice itself: it says
which project it reproduces the terms of and why the file is ours, so nobody
later reads it as a licence upstream granted us directly.

---

### 2026-08-25 — The world overview gets its own archive

**Phase:** 6 · **Branches:** feat/world-own-archive

**What:** The in-app "whole world" download merged into `map.pmtiles`
alongside every region, so the floor the map falls back to everywhere was
reachable by a Remove button meant for a city. It now writes `world.pmtiles`,
merging with whatever overview is already there — which after the packaging
work is the shipped zoom 4, so deepening it to zoom 6 costs only the levels
in between.

A download now says which archive it joins (`"world": true`), and the server
checks the claim: a box short of the edges is a region however large it is.
The estimate carries the same flag, because a quote taken against the wrong
archive would price a planet the user already mostly has, and would then
report it uncovered forever — an offer that never goes away however often it
is accepted.

**Rationale:** No ledger entry, which is what makes it un-removable by
construction rather than by a rule someone has to remember. The ledger is a
list of regions you downloaded, each with a name and a Remove button; the
overview belongs to no place, and half of it now arrives in the package. An
overview with no entry was always possible — the extraction tool writes none
— so nothing downstream needed teaching.

The cost is that it no longer appears in the downloaded-maps list. That is
the right trade: a row you cannot act on is worse than no row, and `held`
already counts the overview, so the "no basemap" banner stays correct.

**Falsified.** Routing world downloads back to `map.pmtiles` fails four
browser checks, including that a region removal leaves the overview alone —
a removal rewrites the detail archive end to end, which is exactly the loss
this prevents. Loosening the whole-planet guard to +/-170 deg / +/-80 deg
fails the server check that a large region is still a region.

**Follow-on:** `map_name_world` is gone from the six catalogues; nothing
names an entry that is never written. The "one field, two jobs" roadmap item
is now the state every fresh install starts in rather than a rare one, and
says so.

---

### 2026-08-25 — Every package ships the map it opens on

**Phase:** 6 · **Branches:** feat/bundled-world-map

**What:** A map application that opens on a blank planet is not one. The
tarball, the .deb and the AppImage now all carry a world overview at zoom 4
(5.8 MB), the glyphs its labels are drawn from and the sprites its icons come
from — 21 MB of payload — so a fresh install draws a planet with no network
and nothing read first.

`tools/stage-bundle.sh` assembles that payload and is the single place all
three packages get it from. It EXTRACTS the overview to a fixed depth from a
local archive rather than copying whatever the developer has, so the shipped
depth does not depend on who built it and packaging needs no network; the
extract is byte-identical for a given source, and the tarball and .deb still
double-build to the same sha256. It refuses to produce a package when the
inputs are missing, and checks what landed — a header with no tiles, or an
empty assets directory, is a build failure rather than a discovery someone
makes after installing.

`ocaml/server/bundled.ml` copies the bundle into the directory the app writes
to, the first time it finds an entry missing. The .deb installs the payload
read-only under `/usr/share/tessarium/basemap` and its new `/usr/bin/tessarium`
launcher points the server at the user's data home, which is what the AppImage
already did; `tessarium-server` run directly keeps its documented `./basemap`
default, which is what the tarball needs.

**Rationale:** Copied into the writable directory rather than read where it
lies. A second read-only root would have to be threaded through the tile
lookup, the floor measurement, the coverage query and the static file route,
and "which archive answered" is load-bearing in every one of them. Seeding
costs the user 21 MB once and leaves all four untouched.

Zoom 4 rather than deeper: it draws countries, coastlines and capitals, which
is enough that the download card is an offer instead of a rescue, and each
further level roughly triples the package. A deeper overview is a download the
user chooses.

Verified against a real .deb rather than a staged directory: unpacked, run
against an empty map directory, seeded all three entries, and served tile
0/0/0 (93 KB), a glyph range and a sprite sheet, with `/world.json` reporting
a measured floor of zoom 4. The tarball runs the same way with no seeding at
all, because its map sits where the server already looks.

**Falsified.** The seeding suite (17 checks) fails when the overwrite guard
goes — the user's own deeper overview is destroyed on the next restart — when
a torn `.seeding` directory is published instead of discarded, when the copy
takes whatever is in the bundle rather than the entries it names, and when it
follows a link out of the bundle. That last check first pointed its link at
`/etc`, where it passed because the copy failed rather than because the link
was refused; it now points somewhere readable. The packaging guards fail a
build with an assets directory holding no glyphs, and with no overview to
cut.

**Follow-on:** The sprites' licence is named as "that project's own terms",
which is not a licence; a roadmap item now blocks a release on reading it.
`tools/check-suites.sh` also gained the two suites it was missing — the new
one and `test_words` from yesterday, which had never been registered.

---

### 2026-08-25 — Arriving at an address selects its square

**Phase:** 6 · **Branches:** fix/select-on-arrival

**What:** Typing an address flew the camera to the square it names and left
the panel showing whatever was selected before, so the user had to find and
click the square they had just asked about. The fly-to effect now runs the
same encode-and-select path a click runs.

**Rationale:** Selected at once rather than when the flight lands. The panel
is then right from the moment the answer is known, and interrupting the
flight -- by dragging, or by asking for somewhere else -- leaves the square
that was asked for rather than whichever one the camera passed over. It goes
through `selectAt` rather than trusting the typed address because a decoded
point re-encodes to the address it came from under ANY key: taking the string
at its word would put a cell in the panel that nothing had confirmed.

A place pick still only moves the camera. A town is somewhere to look at; an
address is a square to be told about.

**Falsified**, and the first attempt was worthless. The check ran where the
panel already named that address from an earlier click, so it passed with the
selection deleted -- vacuously true. It now selects a different square first,
which is also what the neighbouring "Enter selects the centre square" check
was missing: that one had the same hole and would have passed with the key
handler removed.

---

### 2026-08-25 — The word lookup, cross-examined on both sides

**Phase:** 1-3 · **Branches:** test/cross-examine-words

**What:** `Tessarium.Words` was the widest gap in the tree: two theorems about
ALL typed spellings against ALL lists, and extracted code exercised on three
spellings. Closed from both directions.

`fstar/check/Tessarium.Check.Words` puts F\*'s own evaluator against the
extracted binary over a 38-spelling corpus and a 16-word fixture, with the
fixture, the corpus and the answers all coming from Expected so there is no
second copy of the data to drift. `ocaml/test/test_words.ml` holds the SHIPPED
lookup to the proved one over the real 2048 words and all 13,343 partial
spellings of them, which is the part the evaluator leg cannot reach cheaply.

**Rationale:** Two legs rather than one because they answer different
questions. The evaluator leg asks whether extraction was faithful, and its
corpus is small on purpose -- the code path does not depend on list length and
the normalizer would otherwise walk 2048 byte lists per spelling. The OCaml
leg asks whether the SHIPPED resolver agrees with the proved one, which is a
live question that no proof touches: `resolve_word` answers a fully spelled
word from a hashtable because walking the list costs 25x, so the common path
is not the proved path at all. The guard that keeps them together was one
string comparison and an argument.

Falsified three ways. Changing `min_abbrev` in the extracted OCaml from 4 to 3
fails the evaluator leg. Truncating the typed word to four bytes -- the
comparison that actually shipped once -- fails the OCaml leg on four spellings
including "cannot" reading as "cannon". An off-by-one in the hashtable path
fails it on six.

`Tessarium.word_count` and `word_at` are new, and are the only reason the test
can walk the list: `Wordlist` is not reachable through the library's namespace
and an accessor pair is a smaller opening than exposing the array.

**Follow-on:** `Tessarium.Check.UrlPath` is what is left of the item; the
roadmap entry is narrowed to it rather than closed.

### 2026-08-25 — A promised length is now a promise, and the grid says its name

**Phase:** 6/8 · **Branches:** fix/serve-file-open-first,
test/settle-before-select, feat/show-grid-version

**What:** `serve_file` stat'd a NAME, sent `content-length`, and then opened the
same name again inside the body callback. A file renamed in between gave the
client `200 OK, content-length: N` followed by a closed socket with nothing in
it. It now opens the file first and takes size, kind and ETag from the handle,
which pins the inode; the handle is closed on every path. Falsified against the
old code: 2 of 300 requests truncated, 0 with the fix. The e2e check moves the
file away and back for 600 rounds and holds every 200 to what it promised.

The panel now names the grid and derivation versions.

**Rationale:** Two reversals worth recording.

The first is `serve_file`'s: the probe and the stat were deliberately shared
(2026-08-22) to close the window between them, which was right and did not go
far enough -- the third look, the one in the body callback, was the one that
mattered, because by then the promise had already gone out. An fd was always
the answer; what stopped it was that the handle has to outlive the callback,
so it now comes from the server switch. That leaves one case unclosed: cohttp
writes the response header before calling the body, and if THAT write raises
the body never runs and the handle lives until the server stops. Stated in the
code rather than fixed -- closing it needs a per-connection switch the callback
is not given.

The second is the panel's: the grid and derivation versions were deliberately
NOT shown, on the grounds that the end-to-end suite checks them against the
vectors. That is still true and is no longer the whole question. An address is
three words and four digits with no room for a version inside it, so a code
issued under an older grid is not refused -- it decodes to a different and
entirely plausible square with nothing to say why. Reported from use the same
day. Naming the epoch cannot make an old code work; it lets someone label the
codes they keep.

Also: `inspectAt` in the browser suite was racing. Waiting for `.address`
returned immediately while the previous square was still on screen, and under
`make test` a click could land before the map settled and select nothing at
all. The panel's own coordinates now decide when it has caught up.

**Follow-on:** Refusing an out-of-epoch address outright is the expensive half
and stays undone -- there is no room in the address for a version. Not added to
roadmap.md as an item, because nothing about the format is changing.

### 2026-08-25 — A saved address, held to its place across a re-entered phrase

**Phase:** 6 · **Branches:** test/same-phrase-same-place

**What:** Reported from use: save two addresses, lock, type the same phrase
back in, and they no longer land where they were saved from -- inconsistently,
so one lookup looked fine and only repeating it showed the drift. The browser
suite now saves two addresses, then locks and re-enters the SAME phrase three
times, checking both where the address takes the camera and what the square at
the original point is still called. Tolerance 1e-6 degrees, about 11 cm, far
tighter than the ~3 m cell so it cannot pass by naming a neighbour. Falsified
against a worker whose key changes on every unlock.

**Rationale:** The suite could not have caught this. It unlocked once and
locked once, to a DIFFERENT phrase, so "the same phrase twice" was never
asked -- and js/worker-differential.mjs cannot ask it either, since a key that
changed across a lock is invisible from inside the worker that holds it. Two
checks rather than one because a changed key decodes an address to a new place
and re-encodes that place back to the same words: the camera check alone is
satisfiable by a wrong key.

No code fault was found. The core is deterministic across lock/unlock (six
cycles at the worker level, identical), decode lands on the cell centre and
re-encodes to the same address, and nothing time-varying, build-varying or
random reaches the codec. The committed vectors, generated at the 17:36 rename,
still reproduce 69 commits later. The best-supported account of the report is
the constants rename itself: it moved every address, and the server serves a UI
embedded at build time, so page loads either side of that rebuild disagreed.
Circumstantial -- the older builds are gone -- and recorded as such rather than
as a diagnosis.

**Follow-on:** An address carries no version, so one issued under an older grid
decodes silently to a plausible wrong place. Added to roadmap.md.

### 2026-08-24 — Three of the review's findings enforced rather than tested

**Phase:** 6 · **Branches:** feat/checked-request, test/doc-drift,
feat/prove-word-lookup

**What:** Asked whether the review's fixes could be made structural instead
of test-guarded. Three could.

**The /api/ guard is now unskippable by type.** The origin, content-type and
size checks were three branches sitting in the right place in one match --
correct until someone reorders it, adds a route below them, or writes a
second dispatch. They moved behind an abstract type in `api_guard.mli` that
`handle_api` and `handle_basemap` demand, so a route that skips them fails to
compile. Shown: passing a raw string is a type error, and the record field
is not even in scope to forge one. Draining moved in with them, because that
is the part that was got wrong twice while these checks were written -- and,
per the comment already in test_server.ml, once before that, where an undrained
body turned every later poll on the connection into a 405.

**The documents are held to the code.** `tools/check-doc-constants.mjs`
derives the message length and byte counter from the constants themselves and
checks every claim about them across the tracked tree. It fails if it matches
nothing, which is how a check like this dies quietly. Skips
roadmap-progress.md on purpose: an entry records what was true on its date,
and 47 was true on 2026-08-20.

**The abbreviation rule is proved.** `fstar/Tessarium.Words.fst`:
`theorem_spelled` says nothing resolves to a word the typing does not spell
the beginning of, and `theorem_unambiguous` says an abbreviation resolves only
when one word could have been meant. Both falsified first -- the theorem stops
verifying against the four-letter comparison that shipped, and a false variant
("four letters always resolve") is rejected against the correct code.

**Rationale:** The proof works on BYTE LISTS, not strings, and this is the
reason: F*'s string operations are specified only by the LENGTH of what they
return, so nothing relates the contents of a slice to the string it came from
and the claim cannot even be stated against them. The missing fact could be
assumed; `--report_assumes error` correctly forbids that. Tessarium.UrlPath
had already taken the same route for the same reason.

The word list crosses as a parameter, like the band table. The guarantee comes
from counting the matches, so nothing has to be proved about the 2048 words --
which is what keeps this cheap. The expensive statement (no two share four
letters) is four million comparisons and is not needed.

**Measured, and it changed the design.** Going through the proved lookup for
every word made a pasted address 25x slower in the browser -- 3.1 to 78.8
microseconds -- because an exact match walked 2048 byte lists instead of
hitting a hashtable. The table is back as a fast path, carrying the theorem's
property as a one-comparison runtime check instead of a proof, over a
load-time check that the list holds no duplicate so the two paths cannot give
different answers. Back to 2.8 microseconds. The abbreviation path costs 249
against 70, and the per-keystroke place-name check 32 against 11; both are
rare or off the main thread, and both now share one prefix predicate instead
of two hand-written ones, only one of which was ever right.

**Follow-on:** none. `CLAUDE.md` was brought up to date with the user's
consent: the proved-and-not-proved paragraph now names the abbreviation rule
AND says its exact-match fast path is not proved, and the `ocaml/server/`
entry records that the /api/ guard is a type rather than a convention.

### 2026-08-24 — An adversarial review, and the fifteen things it found

**Phase:** 6 · **Branches:** twenty-one, one per fix

**What:** A whole-repo adversarial review plus a diff-scoped one. Fifteen
findings held up under checking and were fixed on their own branches; two
were dismissed with reasons, below. Every fix landed with a check shown to
fail without it.

The four that gave wrong answers or let something else drive the server:

- `resolve_word` compared the input's FIRST FOUR letters, so `cannot`
  resolved to `cannon` and decoded a different square with no error. An
  abbreviation must now be a prefix of the word. The js oracle had the
  identical bug, so it could never have reported it.
- Every `/api/` endpoint was reachable from any page the user happened to
  have open: no Origin check, no Sec-Fetch-Site check, no content type. A
  visited page could start a planet-sized download, delete a map, or switch
  on the network cache. It could not read the answers; every side effect
  landed.
- CI started ONE server and passed ONE URL to a suite that needs five and
  four. `base3`/`base4`/`base5` pointed at dead ports, so every check past
  the first download section had been failing on a refused connection —
  the resume, mismatch and cancel guarantees were not being exercised at
  all. CI now runs `make test-ui`, which owns the servers and the teardown.
- `Ledger.of_metadata` returned `Ok []` for a record written under a name
  this version does not use, so a pre-rename archive read as having no
  downloads. The next download would rewrite the ledger naming only itself,
  and the removal after that would prune tiles nothing remembered. It is
  now an error — matched on the `_ledger` suffix, so this file need not
  carry old spellings to recognise them.

Hardening, all reachable from a downloaded archive or an unauthenticated
POST: request bodies bounded (4 MiB against a real ceiling near 250 KB);
the PMTiles directory entry count bounded before `Array.make` believes it
(a five-byte blob claiming 2^28 entries allocated two gigabytes first);
inflated gzip bounded as it is produced (64 MiB); every tar header field
validated instead of trusted, so a dropped connection reports an
incomplete archive rather than `Invalid_argument`; and the band-table index
bounded in both C shims, where KaRaMeL had erased the refinement and a
probe just past the table returned `0` and kept going.

Three that were quietly lying: the access log recorded `200` for every
`/api/` answer, so its `>= 500 -> Error` rule had never once fired;
`accepts_gzip` searched for four letters anywhere and so served gzip to a
client writing `gzip;q=0`; and the search index re-read AND re-inflated a
run's blob once per tile id under a comment saying it read it once.

Two counting bugs and a race: indexing progress counted whole runs whenever
the first id was in range, and a run can span the max_zoom edge, so the bar
could never arrive; and the grid overlay had no sequence guard, so a slower
answer for a viewport already left painted over a faster newer one — the
hazard `refreshCoverage` twenty lines away already guarded.

Documentation: the message length read 43 in three places and 47 in two,
in the one file where that number is the whole load-bearing fact; five
files called the current digest convention "the v2 protocol"; the roadmap
tied both prefix bumps to round-function changes when only the first was
one; and the oracle's "the three protocol constants, here" comment sat
above one of them, with the other two buried as literals in the functions
that use them.

**Rationale:** Two findings were dismissed rather than fixed. The review
called editing `CLAUDE.md` a violation of its own first rule — the user
authorised it directly, which is recorded here because the document says
to. And it noted that eliding the old constants leaves nothing anywhere
able to name them, so no migration or diagnostic can ever be written for an
archive or address made under them. That is true, it is the cost of what
was asked for, and it is accepted.

Two fixes broke something the unit tests could not see, and the browser
suite caught both: refusing a request without draining its body left the
body on the socket, so the next request on a keep-alive connection began
parsing mid-JSON; and a body over the bound cannot be drained at all, so
that response has to close the connection. Both are the same lesson —
a refusal is still a full HTTP transaction.

The 16-byte constant lengths that `fstar/low/Tessarium.Low.Blake2s.fst`
transcribes as literal words were documented in five files and enforced
nowhere. A bumped length would have left OCaml and the oracle computing
one MAC while the proved core, the vendored C and the wasm computed
another — both halves building, both verifying. Now `crypto.ml` refuses to
load and `round_fn` refuses to hash anything that is not 43 bytes.

**Follow-on:** none open. The README claimed the 10,061,490-point deep sweep
was "earned under what ships"; the rename had moved all three hashed
constants and only 32,298 points had been redone under them. Rather than
soften the sentence the sweep was re-run in full — 5 x 2,012,298 points,
zero disagreements — so the claim is true again rather than merely smaller.
Re-earning it is now stated as the price of touching a constant.

### 2026-08-24 — The old name leaves the git history and the downloaded archive

**Phase:** 6 · **Branch:** direct on master, plus a history rewrite

**What:** The rename left the working tree clean but the name still stood
in 223 commits and 53 branch names, and inside a 6.4 GB archive already on
disk. Both are now gone. `git filter-branch`, not `git filter-repo`:
fetching the latter needs network authorisation that had not been given,
and the slower tool was already present. One blob resisted — an unstripped
`wasm/core.wasm` carrying the name in DWARF — and had its custom sections
dropped (705,913 → 15,686 bytes; still validates, same eight exports, same
answers, no hit in any standard section). The rename commit's own subject
was special-cased so it did not become "rename tessarium to tessarium".

The basemap archive's metadata turned out to be plaintext JSON, 1,229 bytes
at offset 9,329. Patched at the BYTE level rather than by a JSON round
trip, so nothing but the key could move: 1,227 bytes, freed slack zeroed,
the uint64 length field at offset 32 updated, header and metadata region
backed up first and the result read back before anything else ran. One
entry, France, intact. `world.pmtiles` held `{}` and needed nothing.

Historical constants in this ledger were ELIDED, never substituted. An
earlier bulk sweep had rewritten two of them into strings that never
existed on any date, which is how a ledger stops being a record.

**Rationale:** Erasing history means the history is now a coherent fiction.
Old commits name constants that were not in use on those dates, so an old
checkout's `vectors/vectors.json` will not reproduce — the addresses in it
were computed under the real old strings while the code beside them now
names the new ones. HEAD is fully consistent; only historical checkouts are
affected. That is inherent to the request, not a defect to be fixed later.

The verification worth keeping: `grep` on PATH here is **ugrep**, which
silently skips hidden files and gitignored directories. It called the tree
clean while GNU grep found the name in `fstar/.depend`, a paraglide cache,
a `.pyc`, two `_build` trees and two npm hidden lockfiles. Three "clean"
reports were wrong before that surfaced. Any "is this really gone" sweep
needs `/usr/bin/grep`.

**Follow-on:** none. A copy of the pre-rewrite `.git` was kept in a
scratch directory for the session only; it is not part of the repository
and will not survive.

### 2026-08-23 — The project is renamed to Tessarium, constants and all

**Phase:** 6 · **Branch:** rename/tessarium

**What:** The project is renamed, including the four constants that carry
its name into what the software computes. 1,359 occurrences across 136
files: nine F* modules and their extraction, the KaRaMeL C emission and its
vendored copy, every OCaml library and binary, the js_of_ocaml export and
the worker that reads it, the differential oracle, the UI in all six
locales, the packaging app IDs, the opam package and switch, the docs.

*Tessarium* is Latin `-arium`, the place a thing is kept, on *tessera*, one
tile of a mosaic — an *aquarium* holds water, a *tabularium* held Rome's
records, this holds tiles.

The constants, version numbers bumped rather than reused so an old address
can never be silently reread as a new one:

Each was the old project name carrying the version number in the left
column; each is now the new name carrying the one on the right.

| | was | now |
|---|---|---|
| Feistel tweak | `…-grid-2` | `tessarium-grid-3` |
| Round-function domain prefix | `…/v2/fe1` | `tessarium/v3/fe1` |
| Argon2id salt | `…-kdf-3` | `tessarium-kdf-4` |
| Archive metadata key | `…_ledger` | `tessarium_ledger` |

**Every address on Earth changed.** That was affordable only because
nothing is deployed — the same reason the `w3wx/*` rename was free on
2026-08-15, and the last time it will be.

**Rationale:** the two length-bearing ones. `Tessarium.Low.Blake2s` does not
prove anything generic about message lengths; it transcribes the whole
round-function message as sixteen literal little-endian words and a byte
counter, which is what lets the file carry no buffers, loops or length
arithmetic. Both strings lost two bytes, so the message went 47 → 43, the
counter 111 → 107, and the words holding `i` and `x` moved from 9 and 11 to
8 and 10. Every word constant was recomputed — and the method was validated
first by rederiving the OLD constants from the OLD strings and diffing them
against what the file already said. A transcription tool that cannot
reproduce the thing it is replacing is not evidence.

The Argon2 known-answer rows had to move with the salt. They were
recomputed the way the originals were made: the vendored reference C (via
`wasm/argon2.wasm`) and noble's independent implementation, required to
agree before either number was written down. Taking them from one
implementation alone would have turned known-answer tests into a snapshot
of whatever the code currently does.

**Evidence the change was exactly what was intended, and no more:**
`design/bands.json` came back byte-identical, so the grid geometry did not
move — only which permutation of it a phrase gets. The regenerated vectors
say the same thing from the other side: all 47 `grid_vectors` rows
unchanged, and every keyed row — key derivation, Feistel, addresses — fully
changed. The hand-written JS oracle, which shares no code with the proved
core, agrees with it on 32,298 points under the new constants; so does the
wasm core. Three independent implementations landing on the same new
answers is what says the transcription is right, not the proof alone.

**One thing the sweep got wrong and had to be undone:** it rewrote two
historical constants named in older entries — the grid version before
`-grid-2` and the derivation version before `-kdf-3` — into strings that
never existed on any date. A blind substitution over a ledger corrupts the
record the ledger exists to keep. (Those entries no longer spell the old
name either; they were elided by hand afterwards, which keeps them true
where a substitution would not have.)

**Follow-on:** a basemap archive downloaded before today carries the old
metadata key, so its ledger reads as absent: tiles still serve and the
downloads list shows nothing. This paragraph also claimed that anything
which would rewrite such an archive refuses rather than overwriting. That
was not true when it was written — `of_metadata` returned `Ok []` for an
absent key and the rewrite proceeded — and it was made true afterwards; see
2026-08-24. Re-download to restore the record either way. opam cannot
rename a switch, so the local one was rebuilt from an export (112
packages).

### 2026-08-23 — A place says what it is, and says it once

**Phase:** 6 · **Branch:** fix/search-place-kind

**What:** Two index bugs behind the same report — a list of eight Jaspers
that all read alike.

Every populated place had kind "locality": a capital, a town and a hamlet
of nine, identically. The tiles carry `kind_detail` — the word a person
would use — and it was being dropped. Places now take it; every other
layer keeps `kind`, because a road's detail is "primary" where its kind is
"major road", and only places have the problem this solves.

And one town could occupy two rows. Repeat sightings collapse by name,
layer and position, but position was a grid square ALONE, so whether two
sightings twenty metres apart collapsed depended on where the lines fell.
Jasper, Alberta straddled one: the real index carried it twice, and a
search for Jasper spent two of its eight rows on the same town. A sighting
now looks at the eight squares around its own and joins any cluster of the
same name within the radius, wherever that cluster was first filed.

**Rationale:** The other direction is deliberately unchanged and is not
claimed. The grid, not the radius, is what keeps two DIFFERENT towns of one
name apart, so two sharing a square are still one row however far apart in
it they sit. That is what makes the square kilometres wide, and it is still
far narrower than the gap between distinct places.

**Follow-on:** Neither fix reaches an index that already exists — the index
rebuilds when the archive changes, and a finished archive may never change
again. Roadmapped with the two ways out. The kinds also arrive in English
in every locale, which is now a roadmap item of its own.

**Tests:** Three checks in the PMTiles suite (a place takes the detail,
every other layer does not, a place without one keeps its kind), falsified
by dropping the detail and by giving it to every layer. Four in the server
suite over the real Alberta pair — one row across the line, either arrival
order, a different town of the same name kept apart, a road at the same
point kept apart — falsified by looking only at the sighting's own square,
which broke the two named for it.

### 2026-08-23 — The comma in "Jasper, GA" finally does something

**Phase:** 6 · **Branch:** fix/search-typed-context

**What:** Typing a state or country after the comma now ranks the results.
Reported against the real United States index: seven towns are called
Jasper, the list came back ordered by population, the Georgia one sat sixth
of eight, and the popover shows about five rows — so it was below the fold,
and ", GA" moved it not at all. Now it is first.

Three pieces. The index publishes its own rank with each row (`score`,
lower better), because rows sharing one are rows it considers equally good
answers to the NAME and that is exactly the set worth re-ordering. The
dropdown asks for forty rows instead of eight when the query carries a
comma — it can only re-rank what it was given, and the right answer was
never in the first eight. And the ranking is layered: name rank first, then
how much of the context the row's own country and subdivisions answer, then
the index's order among equals, which a stable sort keeps for free.
`tools/gen-regions.py` now emits each subdivision's postal abbreviation, so
"GA" is Georgia; the file is otherwise byte-identical.

**Rationale:** The server cannot answer this and never will. Its index is
built from tile labels, and a tile label does not know its country — no
entry for Jasper contains "GA" anywhere, which is why the context could
only ever rank a name against itself. The browser already derives the
country and subdivision for the row LABEL, from the border data the
download picker ships, so the evidence was sitting right there, offline,
one function away from the ranking. The roadmap had proposed exactly this
("the same trick applied to the candidates rather than the corpus"); this
is that, with the candidate set widened so there are candidates to apply
it to.

Ranking, never filtering — the same hedge the display already makes. The
boxes overlap and the borders are simplified, so a context that DECIDED
would hide the right answer every time the catalogue disagreed with the
atlas. The Jasper on the Florida/Georgia line proves both halves: it
answers "GA" because Georgia's box holds it, and it is still offered for
every other query.

An abbreviation matches a whole label, never a prefix: read as a prefix,
"GA" is also Gauteng and Galicia. It is still Gabon, whose country code is
literally GA — a real collision in the codes, and one more reason this
ranks rather than filters.

One display change came with it. An ambiguous point stays silent about its
subdivision, as before, UNLESS the query named one of the boxes it sits
in — saying it then is the same box evidence answering the question
actually put.

**Follow-on:** Only nine countries have catalogued subdivisions, so a
French department or a German state answers nothing. Placing a point is a
raycast against every border polygon, now paid on forty rows rather than
eight — 15 ms measured, memoized on the rows, the context words and the
locale, which is why `countryName` grew an explicit locale parameter.

**Tests:** 24 new checks in `ui/test/place-context.mjs`, every coordinate a
real row out of the real index, falsified six ways (abbreviations read as
prefixes, abbreviations dropped from the labels, an ambiguous point naming
one anyway, the context thrown away, the context outranking the name rank,
equal rows no longer comparing equal) — each broke the checks named for it
and no others. Three server checks pin the published rank and its
precedence over population, falsified two ways. Two e2e checks pin the
widened ask, falsified by swapping the two limits, which failed both and
nothing else.

### 2026-08-23 — Locking asks first, and one eye opens the whole panel

**Phase:** 6 · **Branch:** feat/lock-warning-and-reveal

**What:** Locking now opens a React Aria modal that says the key is
forgotten immediately and the phrase was never stored, so there is nothing
here to recover it from. Cancel is first in the DOM and on the left, the
destructive confirm on the right. A standing note in the panel footer says
the same about a reload. The panel head gained a reveal-all eye (anything
still hidden means the next press reveals), and copy now answers where it
was pressed -- a GitHub-style tick for two seconds instead of a toast at
the top of the screen. Nine messages across all six locales.

**Rationale:** Nothing about what the app KEEPS changed. The phrase is
still wiped the moment the key is derived and the worker still holds only
the key; the ask was for messaging, not retention, and the retention I had
proposed was withdrawn on that basis. The reload note cannot be a dialog
because a browser will not let a page put wording in front of a refresh,
so the only place it can be said in time is before it happens.

**Follow-on:** sonner is the last component outside React Aria. Its two
tuned behaviours -- errors never auto-dismiss, `richColors` off because
its tinted palette puts 13px text under AA -- are the checks to write
first. Already on the roadmap.

**Testing lesson:** the loading-bar check waited for the map to go quiet
AFTER installing a 500 ms delay on every tile, so it was never quiet and
the check failed three runs in four. It waits while traffic is still
normal now, and the reset and refetch happen in one evaluate that first
verifies no bar is up. Three consecutive clean runs.

### 2026-08-23 — The last native controls move, and a race comes out with them

**Phase:** 6 · **Branch:** ui/native-controls-react-aria

**What:** Both `<details>` disclosures (the optional passphrase, the region
tree) and both checkboxes (region picks, the browse-cache toggle) are React
Aria. Only sonner is now outside it.

**Rationale, and it reverses what was written the same day.** The entry above
recorded these as deliberately staying native, on the grounds that a
disclosure and a checkbox have no behaviour worth taking from a library. That
reasoning was sound and was answering the wrong question: the ask was
consistency, and what these two controls have that the others do not is an
appearance drawn by the operating system — a `summary` marker triangle and a
system checkbox — on the densest screen in the application. Behaviour was
never the reason to move them.

**A race, found rather than caused.** The loading-bar check waited for
`.map-loading` to be absent, once, then watched for it to be ADDED. The map
can begin a fetch in the gap between that sample and the observer, and the
tracker will not raise a bar that is already up — so the check recorded
nothing and failed. This migration touched no map code and produced an
IDENTICAL map event trace (`dataloading` 1, `sourcedata` 2, `data` 2, `idle`
0, measured on both branches); it simply added enough render work to lose a
race that was always there, taking the check from passing to failing three
runs in four. Master lost two different timing checks in the same session,
which is how the suite says it has more of these.

The precondition is now absence held for 800 ms, past the bar's whole
measured cycle (~300 ms up, ~250 ms down), so no bar can be in flight when
the observation starts. Three consecutive clean runs after, against three
failures in four before.

**Follow-on:** sonner; roadmap.md, Phase 6.

### 2026-08-23 — React Aria is the component library

**Phase:** 6 · **Branches:** spike/react-aria-search, ui/tooltip-react-aria,
ui/selects-react-aria

**What:** The search box, the tooltip and both dropdowns are React Aria
Components; `@radix-ui/react-tooltip` is uninstalled and the root
`Tooltip.Provider` is gone. A shared `components/Dropdown.tsx` replaced two
native `<select>` elements, so the two dropdowns in the application are now
one component. `PlaceSearch` lost 43 lines net and with them the open flag,
the highlight index, the click-away listener, the blur rule, Escape, the
arrow-key wrap and an `aria-activedescendant` that had to agree with three
render branches.

**Rationale:** Base UI was the obvious pick and is out — `1.0.0-rc.0`
published 2025-12-04 with nothing since, eight months at a release candidate,
while the thing it succeeds is still publishing. React Aria is on 1.20.0
(2026-07-31), ships no styling so the plain-CSS approach survives, and needs
no Tailwind.

The native `<select>` had a comment defending it, and that comment was right
about what it argued: a HAND-ROLLED listbox would be worse than the platform's.
That stops deciding anything once the project has a vetted library for it. What
was left is that the OS drew it, so it was the one control that did not look
like the application. Recorded because the reasoning changed rather than the
decision being wrong.

**The cost, measured:** the gate went UP 38,617 bytes gzipped, because the
language picker lives on it and pulled React Aria's shared core into the entry
chunk. The map chunk came DOWN 49,222, since it no longer carries its own copy
— so a whole session is 10,605 bytes cheaper and only the first screen pays
more. The gate budget in `ui/test/e2e.mjs` moved 176 -> 200 KB with that
measurement written beside it. Against where this started, the phrase screen is
551 KB -> 178 KB.

**Two impedance mismatches, both worth knowing before the next widget:**
ComboBox decides whether to open in an effect on the render where the input
changed, and refuses when the collection is empty — every answer in the search
box is late (250 ms debounce, a worker round trip, then a decode or an index
scan), so the list never opened at all. Fixed with `allowsEmptyCollection`
always on and the popover rendered conditionally. That broke Escape: the close
path resets the library's record of the last input value to the empty string
while the box still holds text, so the reopen effect fires in the same tick.
`allowsCustomValue` takes the other path and is correct here anyway.

**Checks:** 242 end-to-end checks, 0 failures, at every step. The suite drives
the dropdowns the way a person does now — press the control, press the option
— because there is no `selectOption` for a listbox; options carry a
`data-value` written for that purpose rather than the suite reading a library
internal.

**Follow-on:** `<details>`, native checkboxes and sonner deliberately stay;
roadmap.md, Phase 6, says what would change each.

### 2026-08-22 — Refusals say themselves in the user's language

**Phase:** 6 · **Branch:** i18n/worker-errors

**What:** Every refusal a user can reach now carries a stable code, and the
display edge turns the code into a catalogue entry. Twelve codes, twelve
messages, six locales. The producers are two: `ocaml/lib/tessarium.ml`,
where `Invalid_address`, `Bad_mnemonic`, `Bad_passphrase` and
`validate_mnemonic`'s error now carry `{ code; arg; message }`; and
`ui/public/core.worker.js`, where `Refused` gained a code. `ui/src/core/
refusal.ts` is the single place a code becomes a sentence, and `MapView`,
`PhraseEntry` and `PlaceSearch` call it instead of reading `.message`.

**Rationale:** The worker cannot translate — no catalogue, no locale, plain
JavaScript in `public/` that no bundler reads — and neither can OCaml
compiled to a separate artifact. So the producer names the failure and the
edge says it. `arg` carries the one value that varies, passed positionally
and named at the edge, so a catalogue entry can put a word where its own
grammar wants it rather than where English does.

**The English is unchanged, deliberately.** Every sentence that was already
written for a user is byte-identical in the catalogue, so this change is
about locale and not about copy — the e2e's existing assertions on that
wording still hold untouched, which is the evidence. Two exceptions, both
strings that were never sentences: `"locked"`, which surfaced in a toast as
that one word, and the internal diagnostics (a refused band table, a bad wasm
import, an argon2 return code), which now share one `core_failed` code whose
message says plainly that it is our defect and carries the English detail. A
user cannot act on "the band table failed the core's shape check" and should
not be left thinking they might.

**Also fixed, because the refactor exposed it:** `indicesOfAddress` used to
raise across the js_of_ocaml boundary, and the worker dug the message out of
the exception array's last element. That worked only while the payload was a
string. Giving refusals a record would have silently turned every malformed
address into "[object Object]". It answers with a refusal now and the
array-digging helper is gone.

**Checks, falsified before being kept:** `ui/test/messages.mjs` reads the
codes back out of the worker AND out of `tessarium.ml`, and asserts each
has an entry and that no entry is dead — shown failing against a renamed
worker code (`bolted`) and against a renamed OCaml code (`mnemonic_cksum`),
in both directions each time. The e2e enters an address that names nothing,
in French, and asserts the refusal comes back French and not English, then
switches back and asserts the English — shown failing (English text under a
French interface) against a build whose edge returned `.message` directly.
242 checks, 0 failures; the 14 dune suites all ran.

**Follow-on:** the HTTP API's error strings are still English and one of them
reaches a toast in `DownloadCard`. roadmap.md, Phase 6.

### 2026-08-22 — The phrase screen stops downloading the map

**Phase:** 4 · **Branch:** perf/gate-payload

**What:** MapView is a dynamic import behind `Suspense`, so MapLibre and the
Protomaps style leave the entry chunk. Reaching a phrase field that can be
typed into went from **564,414 B to 140,111 B** on the wire — both measured in
a browser against the embedded UI, not estimated — a 75% cut on the one screen
shown to someone who has not yet decided to use this. Total weight is
unchanged (543,535 B gzipped against 544,462 B): nothing was removed, it moved
behind the decision to unlock. `PhraseEntry` starts the map download the
moment a phrase passes its checksum, which overlaps it with Argon2id over
64 MB, so the split costs nothing a user can feel. A visitor who never types a
valid phrase never fetches it at all.

**Rationale:** The gate needs none of that code, and the user drives this over
a forwarded port where bytes cost roughly ten times what they do locally, so
first-load weight is felt rather than theoretical.

The number is what it costs to REACH a usable phrase field, and not what a
session costs: `/tessarium.js` (about 181 KB) and the map chunk both follow
as the phrase is typed and validates. Recorded here because a 137 KB figure
quoted without that sentence would be flattering.

**Found on the way, and the reason this took two runs:** MapLibre puts its own
`maplibregl-map` class on the element the stylesheet calls `.map`, and sets
`position: relative` with no height. One class each, so the later stylesheet
won — and splitting the chunk moved MapLibre's CSS into a second file loaded
after the app's. The map computed to **height 0**. Everything still mounted,
tiles still loaded, `.map-wrap` still appeared; clicks landed on a map with no
area, and the first check to complain was an unrelated one about the
coordinate row several hundred lines later. Fixed with `.map-wrap > .map`,
which outranks a single class whatever the load order.

**Checks, both falsified before being kept:** the e2e asserts the rendered map
fills its half of the window (940x0 FAIL against the bare `.map` selector,
940x900 PASS with the child selector), and holds the gate to 176 KB with a
companion check that the map still arrives as its own larger download — so the
budget cannot be met by breaking the map instead. The `Suspense` fallback is
rendered under a deliberately delayed chunk and read for its text, because
nothing else in the suite is slow enough to show it. 240 checks, 0 failures.

**Follow-on:** the map chunk is 398 KB on the wire and nothing has tried to
shrink it; the sourcemap item's figures were re-measured. Both in roadmap.md,
Phase 4.

### 2026-08-22 — A long path segment took the connection down

**Phase:** 6 · **Branch:** fix/long-path-segment

**What:** `GET /<300 bytes>` closed the connection instead of answering.
`Eio.Path.kind` returns `` `Not_found `` for a path that is simply absent but
RAISES for one the filesystem refuses to look at — a segment over NAME_MAX
(255) gives ENAMETOOLONG out of statx, EACCES and ELOOP do the same — and the
three places that probed a request-derived path matched only on the kinds a
successful call returns. The exception travelled up as a connection error. One
unauthenticated request, no session needed.

All three now go through one `path_kind`, which answers `` `Not_found `` and
logs. `serve_file` was the one the report came from; `open_tile_archive` and
the `floor_depth` size check were the other two, so `/tiles.json`,
`/world.json` and `/tiles/z/x/y.mvt` were dropping connections too and a fix to
`serve_file` alone would have left them. The client is told the same thing
either way — there is nothing here to send, and which kind of nothing is not a
stranger's business. The operator is not: a plain absence stays silent, and
anything reaching the handler is logged, because "every asset went 404 at once"
is what running out of file descriptors looks like from outside, and answering
404 for it would otherwise have made that invisible.

`serve_file` now probes and stats in one step rather than one after the other,
which closes the window where a file was there for the probe and gone for the
stat. The downloader renames `map.pmtiles` into place under that same root.

Found while checking the newly proved resolver against the running server:
`/<8190 bytes>` dropped the connection while `/<8193 bytes>` returned a clean
404, because the second was over the new 8,192-byte target cap and never
reached the filesystem. A refused target behaving better than an accepted one
is what gave it away.

`Access_log.printable` is new and everything request-derived goes through it.
`url_path.ml`'s resolver refuses NUL, a separator and a leading dot, none of
which is about logging: a segment may still hold CR or LF, and a log line is
newline-delimited, so `GET /%0d%0a...` wrote a second line that read like one
this server emitted. The comment above `describe` claimed asset paths "come
from the UI build and are safe to name", which was never true of a route built
from a request.

**Rationale:** `theorem_no_escape` says a 300-byte segment cannot leave the
root and is right — it holds no separator and no NUL. Whether the filesystem
will accept a name that long is a fact about the directory, and the module is
never told about directories; its two stated carve-outs are how the caller
joins the segments and whether the directory holds a symlink out of itself.
Name length is a third, of the same kind. That is why this is a test and not a
lemma.

Two checks, because the two routes answer differently and only one is a 404: a
segment with no extension is an SPA route, so the UI path serves index.html
and the basemap path has no fallback. Falsified — without the fix the first
reads `threw: fetch failed`.

The companion check, that the server still answers afterwards, is recorded as
the weaker thing it is: node opens a fresh connection, so it passes against
this bug too. It is kept for the worse version, where an unhandled error on a
request path ends the process.

**Follow-on:** the window between the probe and `Eio.Path.with_open_in` in the
body is still open, and it is worse than what was fixed here because the
headers have already gone out. In roadmap.md, with the measurement. Also
roadmapped: CI drives the browser suite with one server where the suite
expects five, which if it is dying early would make several of this week's
checks local-only.

### 2026-08-22 — The path resolver is proved

**Phase:** 1–3 · **Branch:** proof/url-path

**What:** `ocaml/server/url_path.ml`'s `resolve` — the function that stops
`GET /../../etc/passwd` — is now extracted from `fstar/Tessarium.UrlPath.fst`
rather than hand-written. Three theorems and three liveness lemmas:

`theorem_no_escape` — every segment `resolve` accepts is non-empty, is neither
`.` nor `..`, and holds no `/`, `\` or NUL. Stated over a predicate
(`opens_under_root`) that names each hazard rather than over the runtime test
itself, so weakening the test cannot quietly weaken the theorem to match. It
is also what makes the module's ORDER a proof obligation: reorder it to
validate before decoding and this is the theorem that stops verifying.

`theorem_no_dotfile` — no accepted segment begins with a dot. Separate from
the first because it is a different claim: `.env` is under the root, it is
just not ours to hand out. Without it, half of the one rule in `safe` rested
on two unit tests.

`theorem_traversal_refused` — a target that percent-decodes to `..` is
refused. Given `opens_under_root` as written this follows from the first
theorem rather than adding an obligation; it earns its place by naming `..`
directly, so dropping that clause from the predicate leaves the traversal case
still proved. One round of decoding, not a fixpoint: `%252e%252e` is accepted
as the literal name `%2e%2e`.

The three lemmas are liveness. Every theorem above says "if it accepts,
then…", and `resolve = fun _ -> None` satisfies all of them; the lemmas pin
the root to `index.html`, an ordinary name to itself, and `%20` to a space.

Modelled on byte lists, not strings: a request target is octets until
something decodes it, and `/`, `.` and NUL cannot occur inside a multi-byte
UTF-8 sequence, so nothing is lost and no new F\* support module is needed.
The trusted part of the DECISION is two lines converting a string to bytes and
back. The rest of the file — `extension`, `content_type`, `cache_control` — is
untouched hand-written code, and `content_type` is a security decision by its
own comment. The proof covers which files may be opened, not what is said
about them afterwards.

Byte lists cost something. Boxed integers, one per byte, make `resolve` 8.6×
master's on a realistic 25-byte target (0.3 µs → 2.8 µs, which is nothing per
request) and 12× on a long one. Written first with `List.nth` inside
`String.init` it was quadratic — 6.6 ms for a 4 KB path against master's 20 µs
— and `resolve` runs from `Route.of_request` on every request, before the rate
limiter, on the server's only domain. Now linear, and capped: a target over
8,192 bytes is refused before any of this runs, which master did not do at
all. Worst accepted case is 389 µs at the cap.

Falsified seven ways, each rejected by the solver: drop the leading-dot rule,
the backslash test or the NUL test from `safe`; check the raw target before
decoding it; keep the traversal refusal but allow dotfiles; make `resolve`
refuse everything; make `safe` reject everything. The last two verified before
the liveness lemmas existed.

Re-asserted at runtime too. `test_server.ml` runs the extracted resolver over
40,562 targets built as a product of fragments, and holds every accepted
segment to the extracted `opens_under_root` and `names_no_dotfile`. The
corpus is in two groups on purpose: an all-hostile corpus runs the claims over
almost nothing, because hostile fragments are refused and refusal is what a
different check already covers. The second group is names that come close to
the rules without breaking them and encodings that decode into legitimate
ones, so 7,277 targets are accepted carrying 15 distinct segments rather than
three literals. All three numbers are printed rather than only asserted, since
a corpus can grow without either of the last two moving — an earlier version
of this check ran 8,440 targets and reached 4 distinct segments.

`fstar/Makefile` needed one fix to take a module that `Tessarium.Api` does
not reach: the dependency root is now every `Tessarium.*.fst`, derived by
wildcard. Under the single root a new module would have been extracted by the
loop and verified by nothing.

Adding one then exposed three things that were already broken on master, none
of which anyone would meet without running `make clean`, and all three of
which a fresh clone meets:

1. The `.depend` rule passed `--report_assumes error`, which fires on ulib's
   own admitted interfaces — `FStar.Range` and four others — during a
   dependency scan. `make clean && make verify` could not regenerate `.depend`
   at all. It only ever worked because the file was committed. It is no longer
   committed: it holds absolute paths into `$HOME` (27 of `ALL_CHECKED_FILES`'
   37 entries), it is the only generated artifact here with no CI
   regenerate-and-diff gate, and it cannot have one for that reason.

2. `make clean` did `rm -rf ../ocaml/extracted`, which deletes the committed
   `ocaml/extracted/dune`, and `make extract` does not put it back. Now it
   removes `$(OUT)/*.ml`.

3. `low-verify` never cached `check/Tessarium.Check.Round`, which
   `Tessarium.Low.Check` reads. F* will not write a module's `.checked` while
   a dependency has none, and krml then refuses the whole emission with
   "Cross-module inlining expects all modules to be checked first". So
   `make test-lowstar` failed outright on any tree without `check/*.checked` —
   verified against master, not inferred. CI caches only `~/toolchain`, so its
   "Emitted C computes what the proved source computes" step was reaching that
   state on every fresh runner.

`make clean` followed by `make extract`, `make test-extraction` and
`make test-lowstar` now runs through.

The bundle is unaffected: `whole_program` drops a server-only module from the
browser, and `tessarium_js.bc.js` is byte-identical at 1,224,261.

**Rationale:** The plan called this "the first proof of a server module rather
than a maths one, and the pattern for any that follow." The reason to start
here rather than with `Http_range` or `Route` is that path traversal is the
one bug in this server a test suite is structurally bad at: it fails only on
inputs nobody thought to write down, and every spelling that got through a
real server got through a suite that tested the obvious ones.

Not proved, and now stated in README.md rather than only in the F\* source:
that the caller joins the segments the way the theorem assumes — that join is
`List.fold_left Eio.Path.( / )` in serve.ml — and that the directory
underneath holds no symlink pointing out of itself, which is a property of the
filesystem and not of this code.

**Follow-on:** `Http_range.parse` and `Route.of_request` are the same shape;
roadmap.md, Phase 1–3, with the reason neither is urgent. `UrlPath` is a new
extracted module with no counterpart in `fstar/check/`, so it joins the
trusted-extraction surface without joining the evaluator leg that watches it —
also roadmapped. CLAUDE.md said no line of `ocaml/server/` was F\*; corrected
with the user's agreement, in both the proof section and the tree listing.

### 2026-08-22 — The browser was downloading a megabyte of debug data

**Phase:** 4 · **Branch:** perf/browser-payload

**What:** `tessarium.js` was 5,105,724 bytes, and the server sent 1,057,859
of them — gzipped — on every first visit. Two dune settings in `ocaml/js/dune`
fixed it:

`sourcemap no`, because dune's dev profile has js_of_ocaml inline one. It was
2,924 KB of the 5,106 KB file and 68% of its gzipped weight, a source map
being text that compresses no better than the code it describes.

`compilation_mode whole_program`, because dune's dev default links each
library separately and so keeps every module whether the browser reaches it or
not. yojson, stdint and ppx_deriving arrive through `ocaml/fstarlib`, which
`tessarium_extracted` depends on, and the browser calls none of them.
Compiling the whole program at once lets js_of_ocaml drop what nothing calls.

The file is now 1,224,261 bytes and the server sends 181,447 — **5.8× less
over the wire, 876 KB off every first load.** Both figures are what the
running server reports as `content-length` with `content-encoding: gzip`, from
a clean `dune clean && dune build` on each side. `gzip -9` gives 1,015,840 and
175,524 for the same two files; `ocaml/gzip`, which is what the server
actually compresses with, is the looser of the two, so the wire numbers above
are the honest ones to quote. The e2e reports a real first visit at 735 KB
with the new bundle; the same measurement was not taken before, so what that
total was is not recorded here.

Both settings live in the dune file rather than in a `--profile release`
build, so the bundle `ocaml/js/test/test_vectors.cjs` and
`js/worker-differential.mjs` run against is byte-identical to the bundle that
ships. That needed `(lang dune 3.6)` → `3.17`; the `sourcemap`
and `compilation_mode` fields do not exist before it.

`ui/test/payload.mjs` is new and holds both settings in place: a gzipped
budget for the bundle and for `core.worker.js`, plus an assertion that the
bundle carries no source map. It measures the bundle where dune writes it,
which `npm run sync-core` and then Vite copy verbatim, so it cannot grade a
stale copy. Falsified: as it prints them, the shipped bundle is 169.6 KB
gzipped against a 200.0 KB budget; putting the source map back makes it
628.9 KB and trips both checks; dropping `whole_program` alone makes it
319.8 KB and trips the budget. (Those are node's zlib, which runs 7% under
`ocaml/gzip` — 169,561 against 181,447 — so the budget is set with that gap
already spent.)

`npm run check` runs it, and CI now runs `make test-static` — it did not
before, so the static suite had never run there at all and nothing automated
would have caught either dune setting being deleted. Eight comments calling
this "the 5 MB core" were corrected.

**Rationale:** Two other candidates were investigated first and both are
closed.

*Dead exports in the browser bundle.* The bundle exports thirteen methods and
four constants. `ui/public/core.worker.js` reads all four constants but calls
only seven of the methods; the other six looked dead. They are not. `encodeDeg`, `decodeDeg` and `gridForBounds` are the reference oracle in
`js/worker-differential.mjs`, and `encodeNs`, `decodeNs` and `cellBoundsDeg`
are the same in `ocaml/js/test/test_vectors.cjs`. The worker gets its
arithmetic from `wasm/core.wasm`; the bundle's copy is what that arithmetic is
checked against. Removing them would have deleted a differential wall, not
tightened one. Nothing here is unnecessary.

*Moving NFKD to the browser's own normaliser.* `Uunf` appeared 10,064 times
in the bundle as it was, which looked like most of it. It was not: against the bundle as it
now ships, dropping `uunf` entirely takes it from 1,224,261 to 829,547 bytes
raw but only from 175,524 to 145,133 gzipped — 395 KB raw for 30 KB on the
wire, because the Unicode tables are repetitive and compress hard. Occurrence
count was a bad proxy for size.

30 KB is 17% of the payload, which is not nothing. It still does not pay for
the failure it would introduce: if OCaml's `uunf` and a browser's normaliser
ever disagree by one byte, that user derives a different key and gets a map
they do not recognise, with nothing on screen to explain it. A silent wrong
answer is the one failure mode this project spends the most to avoid, and
17% of a payload that is already 5.8× smaller does not buy it.
`ocaml/lib/normalize.ml` stays as it is and stays the only normaliser.

Two things the bump itself changed, neither of them the point of the commit.
dune 3.17 drops warning 30 — two mutually recursive record types sharing a
field name — from the dev profile's error set, where 3.6 had it; the root
`dune` puts it back with `-w @30`, falsified against a deliberate collision.
And `tools/setup.sh --check` now reads dune's version rather than only its
presence, since a switch created under the old `dune >= 3.0` constraint passed
that check and then failed the build.

**Follow-on:** `assets/index-*.js` is now the largest item at 532 KB gzipped,
and `vite.config.ts` still ships a 5,019 KB source map into the binary. Both
are in roadmap.md, Phase 4.

### 2026-08-21 — The map under the map

**Phase:** 6 · **Branch:** fix/coarse-map-stays

**What:** Zooming into a region held only coarsely replaced the map with grey.
A vector source is one pyramid with one depth and ours has holes — the
downloader takes any region to any depth into one archive — and MapLibre draws
a hole as an empty tile. `Tile.hasData()` counts empty as data, so the
stretched coarse parent stops being retained and the map the user was looking
at is swapped for nothing.

Two sources over the same archives now, which is how the offline map apps do
it: a floor underneath, cut to a depth the archives cover the WHOLE planet at,
with the downloaded detail composited over it. A hole in the top layer of two
is transparent rather than blank, and the floor has no holes to have.

Its depth is measured rather than declared. `Basemap_download.floor_depth`
walks zoom levels until one has a gap and stops there, counting every archive
together — 3 ms against a 6.4 GB archive holding a full world at zoom 6, and
two or three lookups against one holding a single city. An archive whose file
is shorter than its own header says is not counted at all: its directories
answer for tiles whose bytes are missing, which is the one shape that can
certify a floor full of holes, and `tessarium-basemap` now writes to `.part`
and renames so an interrupted fetch cannot leave one. `world.pmtiles` is a new
optional archive beside `map.pmtiles`: `tools/fetch-basemap.sh` fetches one
(zoom 4, ~6 MB; zoom 5 is ~14 MB and 6 is ~43 MB), the tile lookup treats it
as one more file in the list, and the downloader never writes it — so removing
a region cannot take the floor away with it.

The two TileJSON documents partition the pyramid rather than overlapping:
`/world.json` is 0..depth over the whole planet, `/tiles.json` is depth+1..
max over what was downloaded. Below the floor's depth the detail source was
asking for the very same tiles, so every tile in the viewport was fetched
twice. Where the cut lands past the detail's own depth the range comes out
empty on purpose — MapLibre requests nothing outside a source's zoom range —
which is also what stops a world-overview-only archive painting its coarsest
tiles over the floor's finer ones.

The note said "No map downloaded at this zoom" over ground the floor now
draws, and the grey wash — 42% opaque, sized for blank ground — darkened it.
The note is now one sentence that is true wherever it appears: the detail is
not downloaded, and nothing about what is underneath. The wash is withheld
wherever there is a floor at all, and the coverage answer gained a `floor`
field to say so, because the depth cannot: every download starts at zoom 0,
so an archive holding one city reports a depth over Tokyo while covering the
planet at nothing but that one tile.

An adversarial review then refuted a claim made here in an earlier draft: a
validator on the 204 for a tile nobody holds. The reasoning was sound — 204 is
cacheable by default, so a tag should turn the repeat into an empty 304 — and
measurement showed Chromium simply does not store the 204, never echoes the
tag, and never gets the 304, while a control on the same origin revalidated a
real tile correctly. The tag bought nothing, so it is not there. An ETag on a
response with no representation was a fiction anyway (RFC 9110 8.8.3), and it
had turned `If-None-Match: *` into a 304 where the spec asks for the 204.

**Rationale:** Measured, not declared, is the whole design. Two earlier
attempts failed on exactly that point: serving 404 for a missing tile (MapLibre
swallows 404 for vector sources by design — `err.status !== 404` — so it is
indistinguishable from the 204 already sent), and capping the source's maxzoom
from the coverage query (the cap fed the query zoom and the server's depth
descends from the zoom asked about, a downward-only ratchet, measured
collapsing 12 → 0 → 0 → 0). A floor that guesses its own depth reintroduces
the bug it exists to fix, so the depth is a fact read off the archives.

Labels are kept on the floor rather than stripped, which was the obvious
economy. They are the most useful thing on screen exactly where the floor is
the only map there is. They do not double where detail exists, and the reason
is order rather than collision: the detail set opens with `earth`, an opaque
fill, so wherever the detail tile has data it paints over the whole floor
stack. That makes the layer order load-bearing and it is commented as such —
an adversarial review caught the first version claiming the collision pass was
doing it, which would have made the ordering look free to change.

**Follow-on:** five items in roadmap.md — the in-app world overview still
merges into `map.pmtiles` rather than `world.pmtiles`; the release tarball
ships no overview, so a fresh install has a two-command setup; the floor
re-asks its deepest tile once per integer camera zoom; a locale switch does
not rebuild the style, so the map's language only follows the interface
across a download; and far past the floor's own depth the map is a single
stretched polygon that the app describes only as "detail not downloaded",
which is true but thin.

### 2026-08-21 — Coming back costs nothing, and a long fly-to stops flying

**Phase:** 6 · **Branch:** perf/http-caching-and-fly

**What:** Every GET a session makes now carries an ETag and answers a matching
`If-None-Match` with an empty 304 — tiles (hashed per request, because a
browse-cache download replaces them under the same URL), embedded UI assets
(hashed at build time by `gen_assets`, so the 5 MB core is not re-hashed to
say "unchanged"), files off disk (path, size and mtime) and `/tiles.json`.
Not the 204 for a tile nobody holds, which has no body to revalidate, and not
the `/api` replies, which are POSTs. Measured against the running server over
the 56 requests a session makes: **5177 KB → 0.1 KB** on a second visit, 52 of
them 304 counted server-side. Locking and unlocking pays the same nothing,
which was the third report.

`If-Range` came with it: the file endpoint advertises byte ranges, and giving
it a validator is what first lets a client form a partial cache entry to
resume against. `map.pmtiles` is rewritten in place by the downloader, so a
range guarded by a tag that has moved on is answered with the whole file
rather than a window into a different archive.

`flyTo` no longer takes a fixed `duration: 1200`. Both call sites go through
`ui/src/core/camera.ts`, which hands MapLibre a `speed` and a `maxDuration` and
lets it decide: a journey it can animate inside 1.2 s is animated, anything
longer lands at once. And the loading bar's `idle` is no longer the only way
down — while the bar is up, `MapView` asks the map directly on a 250 ms poll.

**Rationale:** Validators rather than lifetimes. `no-cache` was correct and
stays: an update or a removal really does change tiles under the same URL. It
was never the problem — a rule that says "ask" with nothing to ask about is
answered in full every time.

Jumping rather than a slower flight, because a slower flight does not fix it.
`flyTo` arcs out to a zoom that fits the whole journey, and from street zoom
that is zoom levels the map holds no tiles for — which is why one city in
Georgia to the next looked exactly like London to Atlanta. A jump asks for the
destination and nothing else. The cost is that long searches no longer show
the journey; reduced-motion users already got this behaviour, so it is now the
same for everyone past 1.2 seconds.

The stuck loading bar was found by this branch and belongs to it: MapLibre
fires `idle` from inside a render and renders only while something is dirty,
so a load that resolves with nothing new to draw could raise the bar and never
lower it. Rare while every tile was a fresh download, ordinary once they come
back from cache in milliseconds — it failed the end-to-end suite twice in
three runs with the map itself reporting fully loaded.

The end-to-end check that was recorded as flaky was neither flaky nor
tuned. Instrumented instead: the bar goes up at 318 ms and down at 568 ms,
and the check raced a `waitForSelector` against that window — a missed window
and a bar that never appeared were the same failure. It now records the bar
through an observer set before the refetch, and separately asserts that the
interception took at all, so "the setup did not take" fails as itself. Three
runs green, and it fails correctly against a tracker that never shows and
against a route that intercepts nothing.

**Follow-on:** Content-hashing the three fixed assets so they need no round
trip at all, and the tracker's other direction — a spurious `idle` cancelling
a pending show — both in roadmap.md. Also fixed in passing: every
`waitForFunction` in the end-to-end suite passed its timeout as the page
function's ARGUMENT, so two waits that said sixty seconds spent thirty.

### 2026-08-21 — One search box, and addresses stop leaving the browser

**Phase:** 6 · **Branch:** fix/search-address-privacy

**What:** The panel's "Find an address" form is gone. The map's search box now
takes both a place name and an address, and decides which was typed *before*
it sends anything. `Tessarium.address_shape` classifies the text as
`Complete` (decode it in the worker, offer the square), `Partial` (someone is
mid-address — show nothing, send nothing) or `Not_address` (search the place
index as before). `usePlaceSearch` takes the verdict as a required argument,
so the query is disabled rather than issued-and-discarded.

**Rationale:**

- *This was a live privacy defect, not a simplification.* Typing an address
  into the search box POSTed it to `/api/basemap-search`, which prefix-matched
  the first word and flew the map somewhere else entirely —
  `paper.later.curve.0851` landed on Papéré, France. Reported from use. The
  visible half was the wrong destination; the half that matters is that the
  address crossed into a request, where a verbose server or any proxy logs it.
- *The rule lives beside the format.* In `ocaml/lib`, reached from the browser
  through a js_of_ocaml export, because a TypeScript copy of "what an address
  looks like" would drift from the parser the first time the format moved.
- *Punctuation, not part-counting.* The first rule was "three or more dotted
  parts", which let `dream.tourist.` through to the index — a third of a
  secret. The rule is now a dot used as address punctuation: one with nothing
  after it, or with a non-space after it. `st. louis` and `mt. fuji` keep
  working because the space after the dot is what tells them apart.
- *The bias runs one way on purpose.* `route 66 exit 1234` is read as an
  address and answered with "'route' is not a BIP-39 word" rather than
  searched. Failing towards silence costs a search; failing the other way
  spends a secret, and only one of those can be taken back.
- *The box is cleared on arrival.* A place name is kept so the same results
  can be seen again; an address is not. The search sits OVER the map, and the
  panel keeps that same value behind a conceal toggle — leaving it in the box
  would put an address in every screenshot of the map. The existing "no
  address is rendered onto the map" check caught this, which is the second
  time that check has earned its keep.

**Falsified, twice.** Opening the gate (`usePlaceSearch(debounced, true)`)
fails both wire checks — the e2e types the address one character at a time and
watches `/api/basemap-search`, because the leak it prevents happens while
someone is still typing. Not clearing the box fails the two exposure checks.

**The review found the rule covered one spelling in six.** `split_address`
accepts `,` `/` space `-` `_` and `.`, and the first classifier looked only at
the dot — so `vacuum-penalty-health-347`, three words and three of four
digits, went to the place index on its way to being typed. Measured across the
prefixes of one vector address: 22 of 24 sendable for each non-dot spelling.
The rule now has two halves, because the separators do:

- punctuation a place name does not use that way (`.` `,` `/` `_` with
  nothing after it or a non-space after it), which also catches a mistyped
  address because it looks at punctuation rather than words;
- the wordlist, for space and dash, which places do use. Two or more BIP-39
  words is what separates `vacuum penalty health` from `new york city` and
  `Stratford-upon-Avon` — each of those has exactly one (`city`, `upon`).
  Matched exactly, not by four-letter prefix, or `county` resolving to
  `country` would take `orange county` off the index; digits excluded, or
  `highway 4 exit 12` would go.

After: 34 sendable prefixes across all six spellings out of 150, worst case
one complete word plus two letters of the next.

**Follow-on:** Three residuals, recorded rather than papered over. A first
word plus a two-letter start of the second still reaches the index (`vacuum
pe`) — closing it means withholding `city hall`, which is a worse trade.
`route 66 exit 1234` is read as an address. And the four-letter prefix
spelling (`drea tour cree`) reads as a place name until its number arrives,
because exact matching is what keeps `orange county` searchable.

---

### 2026-08-21 — The browser answers from the proved core, and the switch completes

**Phase:** 1–3 · **Branch:** feat/ui-wasm-core-switch

**What:** The second half. `ui/public/core.worker.js` answers `encode`,
`decode` and `grid` from `wasm/core.wasm` — the same vendored C the server
links, compiled to wasm32 by the pinned zig. With the server half from earlier
today, every address any user sees on either host is now computed by the C
KaRaMeL emitted from the F* proofs. js_of_ocaml keeps everything that is not
arithmetic: the wordlist codec both directions (three new exports —
`cumTable`, `addressOfIndices`, `indicesOfAddress`), BIP-39 validation and
generation, the KDF's inputs, and the band table it hands the module at load,
which `seal_cum` re-checks in full — base, monotonicity, step bound, grand
total — before the core will answer anything.

**Rationale:**

- *The grid walk stayed in JavaScript.* The roadmap left two options: move the
  cell walk into `wasm/glue.c` beside `bounds`, or keep it as a driver over
  the wasm's `bounds`. The driver won because the walk is not arithmetic — it
  decides which cells to ask about, and every corner it reports comes from the
  proved function either way. The cost is real and is the reason for the new
  wall below: two drivers over one proved function is exactly the duplication
  this project refuses everywhere else, so it is only tolerable while
  something holds the two to each other.
- *BigInt, not floats.* The walk steps in integer nanodegrees for the same
  reason the OCaml one does. The single float boundary is the degree the UI
  speaks, converted once — and it converts with ties away from zero, matching
  OCaml's `Float.round`, not `Math.round`, which breaks them toward +Infinity
  and moves points on negative half-units into a different cell.

**A new wall, because the old ones structurally could not see this.**
`js/worker-differential.mjs` loads the shipped worker unmodified into a node
sandbox that owns its globals and drives the real message protocol. Because
the sandbox owns `fetch`, "the browser answers from the wasm core" is
*observed*: a worker quietly reverted to js_of_ocaml never requests
`/core.wasm`, and the check fails. That closes the same hole the server half
had to close with a fingerprint in `test_server.ml` — the side-by-side walls
prove the two cores agree, which is precisely why they cannot say which one
answered. It also pins the transcription: 104 checks over 400 points, the
committed rejections, and 19 named viewports including both poles, the
antimeridian, inverted and zero-area boxes, and every limit from 0 up.

**Falsified, four ways.** Reverting `encode` to `core.encodeDeg` fails the two
which-core checks. Restoring the `limit`-against-array-length bug fails 7.
Putting `Math.round` back fails the negative-half-unit viewport. Reverting the
OCaml truncation fix fails 3.

**Two bugs it found, both introduced by this branch:**

- *The grid drew a quarter of its cells.* `limit` counts cells; the walk
  compared it against the flat array's length, which holds four numbers per
  cell. A z19 viewport rendered 3,000 of 6,004 cells and raised the "too many
  squares" banner, at an everyday zoom.
- *A viewport touching the antimeridian drew one row.* Found while falsifying
  the truncation fix, and introduced by that fix: the zero-width guard fires
  for real at `lon_max`, where the last cell in a row is clamped, so ending
  the walk there instead of the row stopped the grid after the first row.

**Also corrected, and the larger share of the work:** `truncated` meant two
different things. `cells_in_bounds` reported `false` when the limit ran out
inside the last row — cells dropped, caller told the grid was complete. Both
sides now mean "at least one overlapping cell was not returned", verified to
change no cell anywhere (0 differences over 305 viewports against master) and
to change truncation only where master was wrong.

**Follow-on:** The worker's error strings are English in a six-locale app;
now in roadmap.md as its own item, because the switch enlarged that surface
without creating it. `CLAUDE.md:107` still says the browser runs the OCaml
extraction, which is now false — left for the user, who owns that file.

And one cost this branch owes: it made the "slow tiles raise the loading bar"
end-to-end check flaky. Measured, not guessed — master 0 failures in 9 runs,
this branch 3 in 11. The evidence points at the check's setup racing rather
than at the bar, and it is recorded in roadmap.md with the numbers. It is left
failing occasionally rather than tuned until green, because a check that was
adjusted until it stopped complaining about a branch is no longer evidence
about anything.

---

### 2026-08-21 — The server's HTTP API answers from the proved C core

**Phase:** 1–3 · **Branch:** feat/server-c-core-switch

**Scope first, because the headline reads wider than the change:** `/api/*`
is off unless the server is started with `--api`, and no UI path uses it. In
the default and desktop configurations this core therefore computes nothing
yet — every address a user sees still comes from js_of_ocaml in the browser.
What landed is the wiring and the proof that it is real.

**What:** The first half of the switch. `Tessarium.core` is now an injected
record — `encode`, `decode`, `bounds_of_point` — in the same shape as
`derive_key ~kdf`. `serve.ml` injects `Tessarium_c_core.C_core.core`, so
every address the HTTP API returns is computed by the C that KaRaMeL emitted
from the F* proofs. The extracted-OCaml core is unchanged and un-retired: it
still generates the committed vectors, still feeds the evaluator leg and
gen_check, still drives the differential corpus the JS oracle and the wasm
build are checked against, and still answers beside the C core in
test_c_core.ml's 15,549-check wall on every `make test`.

**Rationale:**

- *Injected, not switched inside the module.* The alternative was calling
  `Tessarium_c_core` directly from serve.ml, which would have duplicated the
  wordlist codec, the range checks and two user-facing error strings across
  two call paths. Injection keeps one composition and one set of messages, and
  makes "which core serves" a one-value change at the call site — the property
  the phase order asked for.
- *Only the arithmetic crosses.* The record carries integer coordinates and
  word indices. Address formatting and parsing stay in `ocaml/lib`, so both
  cores necessarily produce the same words and the same errors.
- *init before serving.* `C_core.init ()` runs in `main.ml` before
  `Eio_main.run`, because the C globals and the `initialised` ref are
  unsynchronised and a later second domain would otherwise race them.

**Falsified, twice.** By hand first: with the FFI stub's first output word
shifted by one, a server started with `--api` answered
`craft.move.flavor.0693` for (48.8566, 2.3522) under the BIP-39 zero phrase
(`abandon` x23 + `art`, empty passphrase); with the stub restored it answered
`cradle.move.flavor.0693`. Those are wordlist indices 400 and 399 — exactly
the off-by-one — and the independent JS implementation computes
`cradle.move.flavor.0693` for the same phrase and point. That implementation
shares no CODE with either core (noble BLAKE2s, noble Argon2id, its own
grid); it does share two generated data files, `js/bands.json` and the
wordlist, as the README's three-legs paragraph is careful to say.

Then permanently, because a hand-run falsification is not a check: the review
pointed out that rewiring `serve.ml` back to `extracted_core` left every
suite green — the side-by-side wall proves the cores AGREE, which is why it
cannot see which one is wired. `test_server.ml` now fingerprints the injected
core on a point where they deliberately differ (a word index of 2048, outside
the proved domain: the stubs refuse it, the extracted core answers). Shown to
fail on the revert.

**Notes:** `ocaml/c_core` gained a dependency on `tessarium` for the record
type; no cycle, since the pure library does not know the C core exists (and
cannot, as it also compiles under js_of_ocaml). One browser-suite run failed
on "slow tiles raise the loading bar" and passed on the three runs around it.
Nothing here touches tile loading, but calling it a known flake would be
inventing a history: the test's own header claims that path is deterministic.
Left open in roadmap.md rather than explained away here.

### 2026-08-20 — The KDF moves to Argon2id (kdf-3)

**Phase:** 4 (security hardening) · **Branch:** feat/argon2id-kdf

**What:** Key derivation is now a single stage of Argon2id -- t=3, m=64 MiB,
p=1 (RFC 9106's second recommended option), password = the NFKD phrase, salt
= the kdf-3 version salt ++ the NFKD passphrase, 32 bytes out -- replacing the
two-stage PBKDF2-HMAC-SHA512 chain. One vendored implementation of the
primitive: the PHC winner's reference C (release 20190702, tarball sha256
pinned, CC0/Apache-2.0), linked natively by the server (`ocaml/argon2`,
runtime lock released around the ~110 ms call) and compiled by the pinned
zig to `wasm/argon2.wasm` (16 KB) for the browser worker. Every key -- and
therefore every address -- changed; pre-release, so a clean break, second of
the day after the BLAKE2s move.

**Rationale:**

- *The recorded objection dissolved.* The ledger rejected Argon2id on
  measurement (pure-OCaml: 21 s in a browser) with two untaken routes, one
  of them "a WASM Argon2id in the browser with a C build natively -- two
  implementations of a primitive, against this project's grain." The C-core
  pipeline built since then compiles ONE source for both hosts with
  committed, byte-diffed artifacts -- the same pattern, so the route stopped
  being against the grain. Measured now: 108 ms native, 149 ms as wasm --
  140x the rejected figure, and faster than the 289 ms PBKDF2 unlock it
  replaces.
- *Memory-hardness is the point.* 202,048 PBKDF2 iterations taxed a
  perfectly-parallel GPU attacker linearly; 64 MiB per concurrent guess
  denies the parallelism instead of pricing it.
- *What was deliberately given up:* the intermediate value is no longer the
  standard BIP-39 seed (that chain was PBKDF2-HMAC-SHA512 -- NIST-designed,
  per the de-NIST decision). The phrase itself remains a valid BIP-39
  phrase (wordlist + checksum); nothing external ever consumed the seed.
  SHA-512 leaves the tree entirely; SHA-256 remains only in the BIP-39
  wordlist checksum and the ledger's content ids.
- *One normalization authority.* The browser used to duplicate the NFKD and
  joining rules in worker JS (forced by WebCrypto needing the bytes).
  kdfInputs on the js_of_ocaml core now builds password and salt for the
  worker, so the rules live once, in the same OCaml the server runs; the
  wasm only stretches.

**Walls, all green and each falsified:** KAT suite pinning the vendored C at
the production parameters (vectors generated by the reference C and
independently recomputed by noble before hardcoding; one flipped hex digit
rings). `js/argon2-differential.mjs` in every `make test`: the committed
wasm against noble on phrase-shaped inputs plus a short-salt refusal (a
t=3→2 drift in the glue rings). The main differential's --mnemonic runs pin
OCaml-Argon2id against noble-Argon2id end to end; the browser e2e
coordinate checks pin the worker chain (a single dropped password byte rang
in both the coordinate and NFKD checks). `make sync-argon2` re-downloads
the pinned release and byte-diffs the vendor tree (a one-byte tamper
rings); CI runs it plus a rebuild-and-diff of the wasm. The full deep sweep
was re-run under kdf-3 before its README claim was kept: 5 seeds x 2,012,298
points, 10,061,490 total, zero disagreements. That run is also the widest
KDF cross-check there is -- js/differential.mjs re-derives each seed's key
with noble's Argon2id, so all five keys agree between the vendored C and an
independent implementation before a single address is compared.

**Decisions recorded:** the unlock-over-plain-HTTP refusal is kept as
POLICY (`self.isSecureContext`) now that the technical dependency on
WebCrypto is gone. The CSP gains exactly `'wasm-unsafe-eval'`. The unlock
hint string changed in all six locales. The `.checked` one-run-behind trap
bit once more through a comment edit to a check/ module (the low loop
refreshes only low/ caches) -- refreshed by hand, same documented class.

### 2026-08-20 — The round function moves to keyed BLAKE2s (mapping v2)

**Phase:** 4 (security hardening) · **Branch:** feat/blake2s-round

**What:** The user directed the project's security functions off NIST designs
onto community-vetted primitives. The Feistel round function is now keyed
BLAKE2s-256 (RFC 7693): domain prefix bumped to v2, the same 47-byte
message layout, the first 16 digest bytes read as a LITTLE-endian integer
(BLAKE2s's own order -- no byte swap anywhere), the 32-byte key crossing every
ABI as eight little-endian words. Every address changed; pre-release, so a
clean break. The KDF moves separately (Argon2id -- its roadmap entry is
updated with the route that reopened it).

**Rationale:**

- *Stated honestly: vetting was not the weak point.* SHA-256's constants are
  nothing-up-my-sleeve, and it is the most-attacked hash in existence. The
  argument that carries is provenance and positioning for a privacy tool --
  "no NSA-designed crypto in any security function" is checkable without
  trusting anyone -- plus the swap being a net simplification.
- *BLAKE2s keys natively,* so the HMAC construction disappears: two
  compressions per MAC against four. It is 32-bit ARX, so the v1 proof
  machinery (w32-in-U64 masking, div/mul rotations, chunked rounds,
  opaque_to_smt) transferred whole; the new module verifies in 0.9 s.
  Pedigree: SHA-3 finalist lineage, WireGuard, libsodium, Argon2's core.
- *Before any code moved,* the intended constants (SIGMA, G wiring, parameter
  block, counter semantics) were cross-verified against python's hashlib over
  300 random keyed cases, and digestif's and noble's keyed BLAKE2s were pinned
  to the same vectors -- three independent implementations agreeing before the
  transcription started.

**What moved together (one commit, every wall green):** the proof module
(`Low.Blake2s` replacing `Low.Hmac`; state travels as two 8-tuples -- F*
tuples stop at arity 14), `Low.Core`'s little-endian Horner fold, the
evaluator leg, gen_check's key-word packing, the C harness (a generic keyed
BLAKE2s rebuilt over the extracted `compress`, pinned to RFC 7693's "abc" and
keyed KAT rows at lengths 0/47/64/129), `crypto.ml` (digestif
`BLAKE2S.Keyed`), the FFI stubs, the vendored C, the wasm module (15.7 KB →
14.1 KB), the JS oracle (noble's blake2s -- node's OpenSSL binding has no
keyed form; `@noble/hashes` 2.3.0 pinned exact at a root `package.json`,
because dune runs the oracle from `_build` and node resolution walks up to
the root; CI installs with `npm ci --ignore-scripts`), the vectors, and the
docs' PRF claims. Encode: 81 µs → 56 µs.

**Falsifications, all shown to ring:** a flipped sigma wire rang in the keyed
KATs -- and demonstrably NOT in the unkeyed "abc" row, whose message words
are almost all zero; that asymmetry is why the keyed rows exist. A tampered
layout word rang in both digestif legs while every KAT stayed green -- the
v1 diagnostic layering (transcription vs layout) reproduced for v2. Big-endian
key packing in gen_check rang in the C draws. A tampered expected value rang
in the evaluator's assert_norm. A big-endian digest read in the JS oracle rang
across the whole corpus (32,596 disagreements).

**Honesty notes:** SHA-256 remains in two NON-security roles, documented in
place: the BIP-39 wordlist checksum (typo detection, fixed by that community
standard) and the download ledger's content ids. PBKDF2-HMAC-SHA512 remains
the KDF until the Argon2id branch lands. CLAUDE.md's primitive names were
updated with the user's explicit approval, per its own rule. The review
caught the deep-sweep claim resting on v1 evidence; the full
10,061,490-point sweep was re-run under v2 (5 seeds x 2,012,298 points,
zero disagreements) before the claim was allowed to stand.

### 2026-08-20 — Search results say where they go

**Phase:** 6

**What:** Each place-search row now reads "kind · Subdivision, Country ·
1,234 km NE": containment from the shipped Natural Earth catalogue
(border-polygon raycast; admin-1 boxes for the nine catalogued
countries), distance and compass point from the current map centre, all
offline. Ambiguous subdivision boxes say nothing rather than guessing
(New York City sits in New Jersey's box too); country ties on
overlapping simplified borders resolve by the candidate's own catalogued
city, then enclave box-nesting, then depth inside the polygon — which
gets every one of the catalogue's own 1,198 city points right,
including both Congo capitals, Maseru, Malabo and Port Vila. 25 unit
checks against the real committed catalogue; every tiebreak branch
shown to ring under tampering; e2e asserts kind and distance render.
`make test-ui` now depends on `make ui`, because the e2e servers serve
the embedded bundle and were greenly exercising the previous one.

**Rationale:** The motivating report was two-fold: identical "Atlanta —
locality" rows, and a pick that flew across the world onto an empty
map. This lands the first half and the distance warning for the second;
the empty-map half is otherwise covered by the world-overview offer and
the grey missing-tile wash (ledger, 2026-08-19/20). A per-result "no
map here yet" marker was considered and deferred: the archive ledger
carries no region boxes, so it needs a server-side answer — recorded in
the roadmap. Also recorded there: the catalogue generator should emit
boxes that bound its final rings (today the appended off-coast city
quads fall outside them, which is why containment must skip the box
prefilter) and could emit enclave holes.

**Follow-on:** roadmap item under Web UI (search context follow-ups).

### 2026-08-20 — The verified core reaches WebAssembly

**Phase:** 1–3

**What:** `wasm/core.wasm` — the same six vendored C files the server
links, compiled to wasm32-wasi by a pinned zig 0.13.0 (`make
sync-wasm`; byte-identical rebuilds, CI rebuilds and diffs with a
sha-pinned toolchain download). The artifact is 15.7 KB stripped
(`-Wl,--strip-all`; unstripped, name-section line info made the bytes
sensitive to comment edits). `wasm/glue.c` mirrors the FFI stubs:
scalar ranges checked per call, the band table fed value by value and
its whole shape validated at seal. `js/wasm-differential.mjs` replays
the differential corpus through it under `dune test`: every address,
every decode landing exactly on its centre, bounds containing centre
always and point off the two spec edges, tweaked-address rejections
exercised (11,454 per run — the corpus is deterministic), the module's
imports allow-listed to exactly libc init's random_get so anything new
appearing rings. The corpus generator now emits the
derived key in its header — the wasm core's contract starts at the key.

**Rationale:** KaRaMeL's own wasm backend is foreclosed on this
toolchain: F* 2026.08.09 ships no LowStar/HyperStack libraries, so
krml's WasmSupport runtime cannot even be checked, and the backend
rejects the function-valued round-function/table parameters besides.
Compiling the ALREADY-EMITTED C with a second, pinned compiler keeps
one artifact chain (proved F* → krml C → both hosts) and adds zig only
as a build tool, not a trust anchor: the wall checks behaviour against
the extracted core, and CI byte-diffs the artifact. Falsified: a
transposed argument in the glue rings (wasm trap), live-code byte
tampers ring, dead-region byte tampers do NOT ring behaviourally and
are caught only by CI's rebuild-and-diff — stated exactly so.

**Follow-on:** the switch phase — server answers from the C core, UI
from the wasm core ('wasm-unsafe-eval' CSP change, worker key as raw
bytes), extracted-OCaml core leaves the serving path.

### 2026-08-20 — The C core crosses the FFI, side by side with the extracted core

**Phase:** 1–3

**What:** `ocaml/c_core/`: the KaRaMeL emission committed as vendor code
(with the krml runtime headers, pinned to the toolchain version;
`make sync-c-core` refreshes, CI diffs), OCaml externals over
range-checking stubs (the C refinements are erased, so the stubs check
every argument before the proved code runs), and a Z-facing wrapper.
`test_c_core.ml` is the side-by-side wall the roadmap called for:
15,549 checks per run — encode, decode-of-own-answer, scanned addresses
including rejections, bounds; corners, a band seam, the pole, both
antimeridians, 2,000 generated points, three keys. Falsified: flipped
key packing (13,364 ring), one tampered band-table entry (27 ring).
Registered in check-suites.sh so a suite that stops running is itself a
failure.

**Rationale:** The emitted C is committed rather than built from F* on
every server build so `make build` keeps working without the toolchain
— the same reasoning as ocaml/extracted, watched the same way. The C
core lives in its own library (`tessarium_c_core`): the `tessarium`
library also compiles under js_of_ocaml, and C stubs do not cross into
the browser. The server does NOT switch yet: the wall runs beside the
extracted core until the pair has earned "byte-identical" on real use,
per the recorded phase order.

**Follow-on:** WASM for the browser; then the server answers from the C
core and the extracted-OCaml core retires.

### 2026-08-20 — The real round function moves inside the proof

**Phase:** 1–3

**What:** `fstar/low/Tessarium.Low.Hmac.fst` (SHA-256 + the production
HMAC in pure machine integers, all-U64 words masked to 32 bits, unrolled
in eight-round chunks) and `Tessarium.Low.Core.fst` (the machine round
function with a proved Horner reduction, plus production extraction roots
`core_encode`/`core_decode`/`core_bounds`/`core_encrypt`/`core_decrypt`
and their theorems). gen_check now emits real-round-function families
(16 digestif draws over 4 keys with a dedicated Lehmer stream, 14
real-key e2e points, 2 rejections); check_main.c replays them and pins
`compress` to 3 NIST vectors; new `Check.RealRound` makes the evaluator
re-derive the digestif draws from the proved source. Falsified in all
four layers: round constant (NIST + digestif ring), message layout
(digestif rings, NIST stays green), Horner multiplier (verification
fails), gen_check key packing (C leg rings).

**Rationale:** The roadmap said "pull HMAC-SHA256 from HACL\*"; deviated.
HACL\*'s HMAC is written against LowStar's stateful buffer model — one
call would have pulled every Tot module into the Stack effect, a rewrite
of the whole port for no assurance gain here: the production key is
exactly 32 bytes and the tweak constant, so the message is fixed-shape
(47 bytes, four compressions, static padding) and a buffer-free
machine-integer transcription is both simpler and inside OUR proof.
FIPS defines SHA-256 over wrapping 32-bit words, so the masked machine
arithmetic IS the standard's arithmetic; what transcription cannot prove
(constants, layout) is pinned by NIST + digestif + evaluator on
independent axes, each shown to ring. Verifier lessons recorded in
BOUNDS.md: flat unrolling sends pure-WP substitution exponential;
`opaque_to_smt` on the chunks keeps downstream VCs bounded. Build
lesson: per-module krml extraction (two leaves now — Check and Core),
and low-verify refreshes .checked in dependency order because a stale
dep is re-verified inline but its cache is not rewritten.

**Follow-on:** FFI phase next (server calls the C core beside the
extracted one), then WASM, then the extracted-OCaml core retires.

### 2026-08-15 — Design settled, roadmap opened

**Phase:** 0

**What:** Core architecture agreed and recorded in `roadmap.md`. Address format
(3 BIP-39 words + 4-digit number, ~2.4 m resolution), integer banded grid,
scattered per-seed mapping via generalised Feistel, 24-word mnemonics, F\* core
extracting to OCaml now and C/WASM later, OCaml server.

**Rationale:** Three choices were live and are now closed.

- *Scattered over hierarchical.* Hierarchical gives truncatable precision and
  memorable neighbouring addresses, but a single leaked address exposes the
  entire enclosing 244 m block — all 10,000 squares. Scattered exposes one
  square. Since the product's premise is a private per-seed map, leak blast
  radius dominates the ergonomic win. Coarse precision becomes an explicit mode
  instead.
- *F\* over Rust+hax, Haskell, F#, Idris.* F\* extracts natively to OCaml, C and
  WASM, which covers server and clients from one proved source. Haskell's
  laziness is a liability in a crypto path and it has no F\* backend; F# is
  materially *less* strict than OCaml (no functors, .NET nulls); Rust+hax is the
  strongest alternative but the tooling is young.
- *OxCaml deferred.* Its unboxed types would fix real `int64` boxing in extracted
  code, but extracted code must not be hand-edited, the gain is invisible behind
  HTTP, and the extensions are explicitly experimental with no backwards-
  compatibility guarantee. Low\* → C is the better performance path and is a
  refactor within F\*, not a rewrite.

**Follow-on:** Phases 0–7 and open questions now in `roadmap.md`. The band table
design is the first real blocker — Phase 1 proofs cannot start without it.

---

### 2026-08-15 — Grid designed, reference implementation built and tested

**Phase:** 1–3 (design and reference), unblocking Phase 1 proofs

**What:** Band table solved and locked at 6,553,600 rows / 4096 bands. Python
reference implementation of grid, key derivation, FE1 Feistel and codec,
passing 30 property checks. 150 cross-platform test vectors committed. An
independent JavaScript implementation reproduces every vector and agrees with
the reference on 4,000 randomised cases. F\* interfaces and theorem statements
written for all three core modules. OCaml core interface and Dream server
written.

**Rationale:** Three corrections came out of actually building it.

- *Target resolution 2.4 m → 3 m.* The roadmap carried both "~2.4 m cells" and
  "~5.7 × 10¹³ cells needed, 0.66 of address space", which are inconsistent.
  2.44 m is the side length that consumes the address space exactly; at that
  size the grid needs 103% of the space and does not fit. 3 m fits at 65% fill
  and produces the 35% invalid share that gives free typo rejection. The two
  claims were never compatible and the 2.4 m figure was wrong.
- *Feistel halves rebalanced.* The recorded pair (a = 2¹⁹, b = 2¹⁸ × 625) is a
  250:1 split, which is badly unbalanced for a Feistel network. a = 2¹⁸ × 25
  and b = 2¹⁹ × 25 give the same exact product with a 2:1 ratio.
- *"Core must use unsigned 64-bit" was overstated.* The widest intermediate is
  4.80 × 10¹⁸, which fits signed int64 with 1.92× headroom. Unsigned is
  preferred for margin but is not forced.

**Bug found:** inverting the floor-bucket with a floor instead of a ceiling.
Cell `c` covers `[ceil(c·span/k), ceil((c+1)·span/k))`; using floor put each
cell's upper edge one nanodegree short, so points landing in that sliver tested
as outside their own cell. Surfaced as 15 containment failures in 200,000
samples and 6,144 band-seam collisions — both from the same root cause. This is
exactly the class of bug that motivated verification: no crash, no error, just
a wrong answer at cell boundaries. `theorem_containment` is now stated
separately in `Tessarium.Grid.fsti` because of it.

**Measured:** cells 3.054 m tall, 2.875–3.000 m wide (distortion 1.043); band
table 48 KB; 35.13% of addresses reject against 35.17% predicted; of 1,289
single-word typos that decoded at all, none landed within 100 km.

**Follow-on:** Phase 1 is unblocked — the band table question is closed. Phases
1–3 are now F\* implementation and proof against the written interfaces. Three
new open questions in `roadmap.md`: pole geometry, whether to take HMAC-SHA256
from HACL\*, and whether the JS implementation should survive the WASM port.

---

### 2026-08-15 — Scaffolding labelled and scheduled for removal

**Phase:** 0

**What:** `reference/` and `js/` marked as scaffolding in `README.md` and in a
new `reference/README.md`, with interim rules (no new features, not citable as
a specification, F\* wins any disagreement) and explicit removal criteria.
`design/grid_design.py` recorded as exempt and permanent.

**Rationale:** Both directories are hand-written reimplementations of the
algorithm, which is the exact failure mode the one-proved-source architecture
exists to prevent. They were built because no F\* toolchain was available
during design validation, and they earned that keep — three wrong design
numbers and the floor/ceiling bug came out of them — but the justification is
circumstantial and expires. The sharper issue, missed when they were written:
`vectors/vectors.json` is generated by `reference/gen_vectors.py`, so the
Python is currently the de facto source of truth for every implementation
checked against those vectors. That inverts the intended trust ordering.

**Follow-on:** Phase 4 gains two items — re-anchor the vectors to F\* (contents
must come out byte-identical) and delete `reference/`. The open question about
`js/` narrowed: it has a real argument for surviving, since an independently
written implementation checks the extracted one in a way a second extraction
target cannot. Decide at Phase 6.

---

### 2026-08-15 — Renamed to Tessarium; typo-scatter test corrected

**Phase:** 0

**What:** Project renamed from `w3wx` to `tessarium` across all four domain
separators, every module name, and the docs. Vectors regenerated. Both suites
re-run and a fresh 4,000-case Python/JS fuzz confirms cross-language agreement
under the new separators.

**Rationale:** `w3wx` was literally "w3w" + x, so the association the project
was trying to avoid was baked into its cryptographic domain separators.
Tessarium is crypto + tessera (a mosaic tile), sharing the `t`. Three earlier
candidates were rejected on collision: *tessera* (an existing npm tile server,
adjacent domain), *scytale* (at least eight crypto projects), *cryptile*
(`cryptiles` on npm has 219 dependents). Also considered and rejected:
seed-prefixed names, which read as Bitcoin wallet tooling and would encourage
exactly the seed reuse the README warns against.

Renaming was free today and permanently expensive later. Changing a domain
separator after launch invalidates every address anyone has written down.

**Bug found (in a test, not the design):** `test_typo_scatter` reported 2
near-hits against a threshold of 1. Investigation showed 12 of 13 apparent
near-hits were cases where the random replacement word happened to be the word
already there — leaving the address unchanged, so it "decoded" to distance
zero. Not typos. Genuine typos within 100km: 1, against 0.80 expected under
uniform scattering — exact agreement with the design. The test also used
Euclidean distance in degrees, which is not distance. Now excludes same-word
replacements, uses haversine, and bounds against a Poisson expectation rather
than a magic number. Second check added asserting the map is not hierarchical,
which is the failure the test actually guards against.

**Follow-on:** none. Rename complete, no references remain.

---

### 2026-08-15 — Application architecture settled; repo under version control

**Phase:** 0

**What:** The project gained a target beyond the core: a working app on Linux
desktop and the web, where a 24-word phrase is entered, the map is generated
under it, and clicking a tile yields that tile's address. Settled the delivery
path, the UI stack, the round-function source, the privacy posture, the basemap
and the desktop shape; all now in `roadmap.md` under *Locked decisions*. Phases
5–7 rewritten around them, Android split out as Phase 9. `git init` and a
baseline commit — the repository had never been under version control.

**Rationale:** Six decisions, five of which reverse or narrow something the
roadmap previously left open.

- *`js_of_ocaml` instead of Low\* → C → WASM for the browser.* The original
  plan reached clients through a second extraction target, which made a working
  UI wait on the whole Low\* retarget. `js_of_ocaml` compiles the OCaml already
  being extracted, so the browser and the server run one extraction rather than
  two, with no C toolchain and no KaRaMeL in the critical path. Low\* survives
  in Phase 8 as an optimisation.
- *Round function from `digestif`'s pure-OCaml backend, not HACL\*.* HACL\* is
  verified and was the presumed answer, but it reaches OCaml through C stubs,
  and C stubs do not cross into `js_of_ocaml`. Taking it would have forced a
  separate browser-side crypto implementation — a second hand-written copy, the
  precise failure mode this architecture exists to prevent. `digestif`'s pure
  backend compiles unchanged in both targets, so there is exactly one. The
  interface already anticipated this: `round_fn` is a parameter and bijectivity
  never depended on it.
- *Eio + cohttp-eio, not Dream.* The roadmap carried "Eio or Dream" unresolved.
  This server serves static assets, three JSON routes and PMTiles range
  requests; Dream is at `1.0.0~alpha8`, is Lwt-based, and pulls OpenSSL
  bindings, GraphQL, an HTML parser and a Markdown parser along with it, while
  still leaving range support to be hand-rolled. Eio is direct-style, actively
  maintained and effects-native.
- *OCaml 5.4, not 4.14.* 4.14 was briefly chosen out of caution about Dream's
  OCaml 5 support. That caution was unfounded — Dream declares `ocaml >= 4.08`
  with no upper bound — and the pin was actively harmful: `zarith_stubs_js`
  v0.17.0, which is what makes extracted `Prims.int` arithmetic work in a
  browser, requires `ocaml >= 5.1.0`. Checking the constraint rather than
  assuming it reversed the decision.
- *Vector basemap, not raster.* Offline was a hard requirement, and raster
  cannot meet it at this resolution: planet coverage to z19 is hundreds of
  billions of tiles, and z19 is only 0.30 m/px, which puts a 3 m cell at ten
  pixels with nothing but blur beyond. Vector tiles to z15 cover the planet in
  roughly 100 GB and render crisply at z22. PMTiles also collapses hosting to a
  single file behind HTTP range requests, so desktop-offline and self-hosted
  become one code path.
- *Plain DOM UI, not React Native.* Expo can build web, so the question was not
  capability but commitment: Capacitor wraps a finished web build and can be
  added years later, whereas Expo is a foundational choice that cannot be
  retrofitted onto a DOM app. With Android deferred, the cheapest way to keep it
  open is to not choose a mobile framework at all. React Native would also have
  put `react-native-web` between the app and a DOM/WebGL map library, and made
  awkward the Web Worker that PBKDF2 needs.

Settled two of the roadmap's open questions outright — the round-function source,
and whether the server must exist (it does, as static host, tile server and
desktop shell, but no UI path depends on its encode/decode API; keys are derived
client-side and never transmitted).

**Follow-on:** Phase 0 reduces to toolchain pinning and CI. Phases 5–7 replace
the old Phase 5–6. Android is Phase 9. Two new open questions: whether `js/`
survives now that it is the only independent check on the extracted core, and
who hosts the basemap extracts the in-app downloader will fetch.

---

### 2026-08-15 — First verified module; band table memory limits measured

**Phase:** 1

**What:** `Tessarium.Spec.fst` verifies — all conditions discharged, 0.4 s,
no admits. That covers `lemma_factors`, `lemma_bucket_range`,
`lemma_bucket_monotone`, `lemma_edge_inverse` and `lemma_midpoint_interior`,
plus three new division lemmas (`lemma_div_char`, `lemma_div_le_iff`,
`lemma_ceil_le`) that the rest of the development rests on. `lemma_edge_inverse`
is the one corresponding to the floor/ceiling bug the reference implementation
shipped first time round. F\* toolchain (2026.08.09, Z3 4.13.3) running from a
binary release in `$HOME`, needing no root.

**Rationale:** Two corrections came out of running the prover rather than
reasoning about it.

- *`FStar.Mul` no longer exists.* All four `fstar/*.fsti` files open it, and all
  four would fail on the first line. It was removed from ulib; `*` on integers
  now needs no import. The interfaces were written against an older F\* and had
  never been run.
- *F\* rejects `_` digit separators.* Every geodetic constant used them.

Both are the same class of problem: the F\* in this repository had never been
near a compiler, so nothing about it could be assumed.

**Measured (2 GB RAM, no swap):** F\* memory against band-table size is sharply
super-linear — 256 entries 115 MB, 512 → 166 MB, 1024 → 274 MB, 2048 → 640 MB,
and 4096 is killed by the OOM killer above 1 GB. Splitting the same 4096 entries
into 16 chunks of 256 costs 207 MB and succeeds, a 5× reduction. Sixteen
per-chunk `assert_norm` obligations verify in 241 MB / 2.1 s, and F\*'s
normaliser independently computed the grand total as 55,692,067,744,000,
matching the committed table. But any *single* obligation touching the whole
table exceeds 2 GB, including `FStar.ImmutableArray` variants, because the
array is rebuilt per obligation rather than shared.

**Re-measured at 16 GB.** The memory ceiling was real but was masking the
actual constraint. With headroom, the flat 4096-entry literal elaborates in
1.4 GB / 7.6 s and the generated `Tessarium.BandTable.fst` in 1.9 GB / 9.5 s,
so raw size was never the problem. Two sharper findings replace it:

- *Z3 encoding size is the binding constraint.* A module that defines the
  literals drags them into every SMT query it contains. A trivial index-bound
  check — `b + 1 < length arr` under `b < bands - 1` — fails at 4096 entries
  after 35 s, and the byte-identical code over 4 entries verifies in 0.2 s. The
  fix is `[@@"opaque_to_smt"]`, which removes a definition from the SMT encoding
  while leaving it reducible by the normaliser. Confirmed: chunked lists with
  the attribute verify in 271 MB / 2.07 s.
- *Lists normalise; arrays do not.* The same well-formedness scan takes 2.1 s
  over chunked lists and does not terminate within 10 minutes via
  `FStar.ImmutableArray` lookups. `ImmutableArray` earns its place only as the
  extraction-time O(1) runtime representation, never as the proof vehicle.

A third, smaller trap: an SMT pattern on a closed term (`[SMTPat (length arr)]`
on a unit lemma) contains no bound variable, so Z3 discards it silently and F\*
only warns. Length facts belong in the array's refinement type instead.

**Rationale:** the governing rule is that each proof obligation must touch a
small term — chunking the data is not enough on its own. That pushes the grid
theorems behind an abstract `Tessarium.Table.fsti` carrying only
well-formedness, so injectivity, containment and round-trip never see a literal,
and the concrete table's cost is isolated to one module. That is better
structure independently of the prover's limits, and the existing
`Tessarium.Grid.fsti` already declares the table abstractly, so it matches the
original intent.

**Follow-on:** Phase 1 gains the interface split and a chunked re-emit of the
band table; the current emitter produces one flat literal, which now elaborates
but poisons every SMT query in its module.

---

### 2026-08-17 — Band table verified; toolchain pinned

**Phase:** 0–1

**What:** `Tessarium.Scan` and `Tessarium.Table.Data` both verify with no
admits, in 4.7 s and 304 MB. The band table is now a proved artifact rather than
an assumption: adjacent-difference bounds, length, and the 55,692,067,744,000
grand total all discharged against the committed `bands.json`. Toolchain
complete and pinned — F\* 2026.08.09 with Z3 4.13.3 from a binary release in
`$HOME`, OCaml 5.3.0 via an opam switch, Node 24.19.0 via nvm with a `.nvmrc`.

**Rationale:** three changes, each forced by measurement rather than taste.

- *The table stores cumulative column counts, not the two tables the grid
  consumes.* `offsets[b]` is `cum[b] * rows_per_band` and `col_counts[b]` is
  `cum[b+1] - cum[b]`, so band-offset contiguity — previously a lemma requiring
  a two-list relational scan — becomes true by definition and needs no proof at
  all. One predicate is left over the data, that adjacent differences lie in
  (0, max], and it yields positive column counts and the per-band width bound
  together. The stored values also shrink from 14 digits to 11, and one table
  replaces two.
- *Chunked, with the literals opaque to SMT.* Measured on the same table: one
  whole-table obligation costs 56 s and 6.6 GB; seventeen per-chunk obligations
  folded by data-free lemmas cost 4.7 s and 304 MB. 12x faster, 22x leaner, and
  well inside what a CI runner can be trusted with.
- *`lemma_total` folds `last` across chunks rather than indexing.* Reaching the
  final element with `assert_norm` on `L.index` walks all 4097 cells and cost
  22 s / 4.3 GB on its own. `lemma_unsnoc_is_last` plus `lemma_append_last`
  across the chunk seams leaves one small per-chunk normalisation.

*OCaml 5.3.0, not 5.4.1 as previously recorded — by convenience, not by
constraint.* The F\* distribution ships its ulib support library as precompiled
`.cmi`/`.cmx`, and OCaml has no stable ABI: objects carry a version magic number
and cross-module inlining details, so they cannot be linked by a different
compiler. Matching 5.3.0, the compiler F\* itself was built with, lets
extraction link those objects directly with no rebuild step.

It is not a hard pin. The distribution also ships complete sources — 129
compiled units against 129 `.ml` files, none missing — so any OCaml version F\*
supports is available at the cost of rebuilding the support library. An earlier
draft of this entry claimed a third of the units had no source and that the pin
was forced; that was a miscount. `lib/ulib.ml` is a *directory*, and `ls *.ml`
listed its contents rather than matching files, which made the sources look both
fewer and misplaced. Every other constraint clears regardless: `eio` needs
>= 5.2.0, `zarith_stubs_js` needs >= 5.1.0.

*Node 24, not 22.* 22 entered Maintenance on 2025-10-21; 24 has been Active LTS
since 2025-10-28. Managed by nvm rather than a system package so the version is
per-project and needs no root.

**Follow-on:** `Tessarium.Grid.fsti` needs rewriting — it predates the
cumulative encoding, declaring `col_counts` and `offsets` as separate abstract
tables with contiguity as a lemma, and it opens the removed `FStar.Mul`.

---

### 2026-08-17 — Core verifies, extracts, and runs in both targets

**Phase:** 1–5

**What:** The whole core is through `fstar.exe` with no admits —
`Tessarium.Table`, `.Grid`, `.Feistel`, `.Codec` and `.Api` join `.Spec`,
`.Scan` and `.Table.Data`. It extracts to OCaml, and the extracted OCaml
reproduces all 199 committed vector checks natively. The *same* extraction,
compiled by `js_of_ocaml`, reproduces 46 vector checks under Node in 0.84 s —
so the browser and the server demonstrably run one implementation.

What the refinement types buy, stated precisely: `point_to_cell` returns a
value provably below `total_cells`, `band_search` provably returns the unique
band containing a row, `cell_to_point` provably returns coordinates in range,
and `theorem_no_overflow` discharges the 1.92x int64 headroom. These are
type-level guarantees, discharged at verification time. The three grid
*theorems* — containment, injectivity across band seams, round-trip — are still
unwritten, and remain in `roadmap.md`.

**Rationale:** five findings, each from running the pipeline rather than
reasoning about it.

- *`--extract` silently skipped the band table.* F\* walks what it calls a
  "possibly-partial dependency graph": a module that has an interface is loaded
  from that interface alone, so its implementation is never elaborated and does
  not come out. `Tessarium.Table.Data` is exactly that shape and is the module
  holding the table. The build now invokes `--extract_module` once per module.
  A whole-program flag that silently emits *less* than asked is worth
  remembering.
- *F\*'s shipped `.cmi` files read as corrupt against an identical compiler.*
  Same OCaml 5.3.0, same magic `Caml1999I035`, still rejected. OCaml 5.3
  compresses `.cmi` with zstd when the compiler has it; F\*'s build did and ours
  did not. `make -C fstar fstarlib` now vendors the eight support modules from
  the shipped *sources* and builds them with our switch, which sidesteps the
  question rather than chasing the flag.
- *`js_of_ocaml` compiles OCaml's `int` to 32 bits.* Longitude reaches
  1.8 x 10¹¹ nanodegrees, so this is not a corner case, and it produced three
  separate failures: the four bound constants silently truncated
  (`-90000000000` became `194313216`), a module-level `Z.to_int total_cells`
  raised `Z.Overflow` at load, and every exact value crossing the JS boundary
  would have wrapped. Bounds are `Z.of_string`, and nanodegrees cross as decimal
  strings. The degree helpers convert at the edge, which is the one place the
  no-floating-point rule permits it.
- *`batteries` drags OCaml threads into the bundle.* F\*'s support modules use a
  sliver of it; `js_of_ocaml` has no `caml_thread_initialize`, so the bundle
  loaded and immediately died. A twelve-line `BatList` shim replaces it, and the
  bundle fell from 5.8 MB to 4.4 MB.
- *`Prims.int` is `Z.t`, and that is the right default.* Extracted arithmetic is
  Zarith throughout rather than native int. Slower than necessary — the values
  all fit in 63 bits — but it is what makes the same extraction correct in a
  32-bit JS runtime, and correctness before speed here is not a close call. If a
  profiler ever objects, the answer is Low\* -> C (Phase 8), not hand-editing
  extracted code.

**Measured:** full verification 12 s; extraction 8 modules; native vectors 199
checks / 0 failures; JS bundle 4.4 MB, 46 checks / 0 failures / 0.84 s.

**Follow-on:** the three grid theorems and the Feistel/codec round-trip
theorems stay open in Phases 1–3, now against implementations that exist rather
than against interfaces. CI is the gating item: until it runs, no verification
claim in the README is reproducible by anyone else.

---

### 2026-08-17 — Working map prototype: server, UI, offline basemap, CI

**Phase:** 0, 5–6

**What:** The thing the project set out to build works. Enter a 24-word
phrase, the map opens under it, click a square and get its address, paste an
address and fly back to that square. Four pieces landed:

- **Eio + cohttp-eio server.** Static assets, health, PMTiles over byte
  ranges, and an encode/decode API that is off by default. Routing, path
  safety and range parsing are pure and separately tested.
- **Vite + React + MapLibre GL UI**, with the verified core in a Web Worker
  that owns the derived key. The grid overlay is drawn from a new
  `cells_in_bounds` in the core.
- **PMTiles reader and region extractor in OCaml** — the offline basemap.
- **CI**, verifying from a pinned F\* release and re-extracting on every push.

**Rationale:** four decisions, three of them forced by something breaking.

- *PMTiles in OCaml rather than the Go `pmtiles` tool.* Raised by the user as
  a preference and it turned out to be the load-bearing choice: the desktop
  target is meant to be one static binary, and the Phase 6 region downloader
  has to run *inside* it. Shelling out to a Go binary would have made Go a
  runtime dependency of the shipped app in all but name. Serving tiles never
  needed it — that is plain range requests over an opaque file — so the Go
  tool was only ever doing the one job the app itself must do.
- *The key lives in the worker and there is no way to read it back.* The main
  thread sends coordinates and receives addresses. This started as a way to
  keep PBKDF2 off the render thread and became a real boundary: the main
  thread has the DOM, which is where an injected script would be looking. The
  browser test asserts a second worker in the same page has no key.
- *Content-Security-Policy defaults to `connect-src 'self'`.* A seed phrase is
  typed into this page, so the question is not whether the code is trustworthy
  but whether a compromised dependency would have anywhere to send it. With no
  remote origin permitted, it does not. Widening it takes a flag, which is why
  the basemap had to be served locally rather than from a CDN.
- *The access log is a closed variant of route shapes, not a format string.*
  There is no free-form field, so there is nowhere for a phrase, key or
  address to be interpolated even by accident, and query strings are dropped
  before logging. Structural rather than disciplinary.

**Bugs found, each by a test that existed to find it:**

- *Worker errors were resolved as successes.* Operational failures came back
  nested inside `result`, and the client only rejected on a top-level `error`.
  So an address decoding to nothing — about 35% of them, by design — reported
  success, and the map flew to `NaN`. The valid path worked perfectly, which
  is exactly why this survived until a test looked up a deliberately invalid
  address. Refusals now throw.
- *A relative PMTiles offset used as an absolute one.* Directory entries store
  offsets relative to the data section. The extractor added nothing, so it
  copied tile bytes out of the root directory. The output had a correct
  header, correct tile count, correct bounds, and every tile was garbage — no
  error anywhere, just a map that renders blank. Caught by reading the output
  back with the reference JavaScript implementation.
- *An `assert` that was a bad test, not a bad implementation.* A lookup of
  `pig.night.notaword.7473` was expected to name the unknown word; it decoded
  instead, because four-letter prefix matching resolved `nota` to `notable`.
  The feature working as designed.

**Measured:** 349 checks across five suites — 199 native vectors, 55 in the JS
bundle, 57 server, 38 PMTiles, 17 in headless Chromium. Extraction is
byte-identical on re-run. A 0.25° × 0.10° London extract at zoom 15 is 31 MB
of tiles out of a 128 GB planet build, plus 15 MB of glyphs.

**Follow-on:** Phase 5 narrows to session expiry and rate-limiting the one
endpoint that runs PBKDF2. Phase 6 keeps the in-app region downloader, label
placement above zoom 20.5, and keyboard access. Phase 7's "single binary" is
not yet true — assets are read from `ui/dist` at runtime. The basemap
distribution question narrowed: no one needs to host extracts, but
`demo-bucket.protomaps.com` is a demo bucket with no availability promise.

---

### 2026-08-17 — Every theorem proved

**Phase:** 1–3

**What:** The theorem set is complete, with no admits.
`Grid.theorem_containment`, `theorem_injective` and `theorem_roundtrip`;
`Feistel.theorem_roundtrip`, `theorem_injective`, `theorem_surjective`;
`Codec.theorem_roundtrip` both directions and `theorem_injective`; and
`Api.theorem_end_to_end`, which composes all three layers into the property a
user would state — decoding an encoded point names that point's own square.

**Rationale:** three things worth keeping.

- *Band-seam injectivity reduces to one lemma.* `lemma_band_unique`: offsets is
  strictly increasing, so the half-open interval each band owns is disjoint
  from every other's, and no two bands can claim an index. The seam question
  the design worried about for months is four lines once the table stores
  cumulative counts, which is a return on that encoding decision rather than a
  coincidence.
- *The Feistel induction needed no second loop.* The obvious approach — a
  decryption loop with an adjustable endpoint, so both directions range over
  the same segment — would have added a function to the extracted surface for
  the sake of a proof. Stating it as *decryption from the last round collapses
  onto decryption from round i* avoids that entirely, and at i = 0 it is
  exactly the round trip, since `dec_loop` at 0 is the identity.
- *Zero admits is enforced by F\*, not by a grep.* `--report_assumes error`
  makes every escape hatch an error. The grep that preceded it was wrong twice:
  it fired on the word "assume" in a prose comment, and it would have missed a
  hatch reached through an abbreviation.

**Checked non-vacuous.** Every theorem was re-run against a deliberately false
variant, and each was rejected: a point falling below its own cell, a round
trip landing on `index + 1`, injectivity concluding two equal indices came from
different rows, end-to-end decoding to `None`. The sharpest control was setting
`rounds` to 9 — the parity invariant breaks, exactly as the design's
"must be even" note says it should, which shows the proof depends on the
round count rather than merely tolerating it.

**Dropped:** a `theorem_encode_total` that verified but asserted nothing — its
second disjunct held by the return type. A theorem that looks meaningful and
is not is worse than an absent one, because it reads as coverage.

**Follow-on:** two narrower gaps in Phases 1–3. Nothing proves the extracted
OCaml matches the F\* it came from — the extraction pipeline is trusted, and
199 vectors are all that bridge it. And `theorem_containment` carries
`requires lat < lat_min + lat_span`, because exactly +90° is clamped rather
than bucketed; `lemma_pole_clamp` covers the pole separately.

---

### 2026-08-17 — Vectors re-anchored to F\*; Python reference deleted

**Phase:** 4

**What:** `vectors/vectors.json` is now generated by the verified core, and
`reference/` is gone. The trust ordering the architecture exists to establish
finally holds: nothing in the tree computes an answer that the F\* is then
checked against.

**Rationale:** three decisions.

- *Split the questions from the answers.* `vectors/inputs.json` holds the
  points, mnemonics and Feistel inputs and is committed;
  `ocaml/tools/gen_vectors.ml` computes the outputs. The alternative —
  regenerating inputs too — would have meant reproducing Python's Mersenne
  Twister in OCaml to keep the same 47 points, which is absurd work for no
  gain. Which points to test is arbitrary; what the answers are is the thing
  under test. `--check` runs in CI, so the core drifting from its own committed
  answers is a build failure rather than a silent regeneration.
- *The regenerated file was semantically identical to the Python's*, which was
  the stated precondition for deletion and the reason for doing it in that
  order. Verified three ways afterwards: the OCaml `--check`, all five other
  suites, and the Python itself before it was removed.
- *`js/` stays, and the open question is closed.* With `reference/` gone it is
  the only thing in the tree that could catch a bug in the F\* extraction by
  disagreeing with it — the pipeline is trusted, not verified, and an
  independently written implementation checks something no second extraction
  target can. It is now wired into `dune test` (150 checks) rather than run by
  hand, which converts it from a copy that might drift into a live oracle.

**Found on the way:** `ocaml/lib/wordlist.ml` carried a "GENERATED — do not
edit" header with nothing in the tree able to generate it, and its only source
was the file about to be deleted. That is hand-written code wearing a
misleading comment. The BIP-39 list moved to `wordlist/english.txt` with its
canonical checksum recorded, and the module is now produced by a dune rule and
not committed at all, so it cannot drift. The generator refuses a list that is
not exactly 2048 words — a short one would build cleanly and produce wrong
addresses, since the codec's radix depends on the count.

**Measured:** six suites under one `dune test` — 199 native, 150 independent
JS, 55 js_of_ocaml, 57 server, 38 PMTiles, plus the vector regeneration check.

**Follow-on:** Phase 4 keeps the benchmark and a large randomised differential
sweep; the 47 committed points are a floor, and the extraction is the trusted
part worth stressing.

---

### 2026-08-17 — Differential sweep against the extraction; encode benchmarked

**Phase:** 4

**What:** The extracted core and the independently written JavaScript
implementation agree on **512,298 points, with zero disagreements** —
`point_to_cell`, `cell_to_point`, `encode`, and `decode` landing in the same
square. A 14,298-point version runs in CI.

**Rationale:** the corpus is deliberately unbalanced. Uniformly random points
essentially never land on a band seam — there are 4096 of them across
1.8 × 10¹¹ nanodegrees — and seams are exactly where two bands could both claim
a point or leave a gap. So the generator straddles every seam explicitly, three
points each, giving 12,287 seam points in every run including the small CI one.
That is the case `theorem_injective` rules out in the F\*, and the case where a
bug introduced *by extraction* would be least visible.

This matters because the extraction pipeline is trusted rather than verified.
The F\* is proved and nothing proves the OCaml that came out of it says the
same thing. An independently written implementation disagreeing is the only
signal available, which is the argument for keeping `js/` and the reason it is
now pointed at half a million points rather than 47.

**Measured, and the roadmap's estimate was wrong:** an encode costs **53 µs**,
not the 3–6 µs recorded. The breakdown says why, and it is not what the
estimate assumed:

| | |
|---|---|
| `round_fn`, one HMAC-SHA256 | 5.12 µs |
| ten rounds | 51.2 µs |
| `point_to_cell`, whole grid | 0.06 µs |

So 97% of the cost is the hash, and the Zarith arithmetic the estimate worried
about is negligible. The 3–6 µs figure implicitly assumed a C hash; the pure
OCaml backend was chosen deliberately, so that the browser and the server run
one implementation, and roughly a tenfold slowdown is what that costs. The
grid being 0.06 µs is the useful part: no future performance discussion needs
to look at the extracted core.

**Follow-on:** Phase 4 becomes a single entry weighing a native round function
against having two implementations of the hash.

---

### 2026-08-17 — Single binary and release tarball

**Phase:** 7

**What:** The UI is compiled into the server binary, so the desktop target is
genuinely one file. Extracted from the tarball into an empty directory, it
serves the app with no `--ui` flag and no asset directory anywhere; the browser
suite passes against it. `tools/package.sh` produces a 13 MB tarball holding
two executables, a licence and a README.

**Rationale:** three choices.

- *Assets are stored gzipped and served with `Content-Encoding: gzip`.* The
  js_of_ocaml core is 4.4 MB, and an OCaml source file containing a 4.4 MB
  escaped string literal is slow to compile and large in the binary. Gzipped it
  is 990 KB, which is also what a browser wants over the wire, so nothing is
  decompressed at startup and the common path does no work. A client that will
  not accept gzip gets it decompressed rather than a 406 — browsers all accept
  it, but curl and scripts should still work.
- *`make ui` copies `ui/dist` to `ocaml/server/ui_dist` rather than dune
  depending on `ui/dist` directly.* The direct route would put
  `ui/node_modules` in dune's view, and scanning ten thousand files on every
  build to reach four is a poor trade.
- *Embedded assets are checked before the directory, not after.* That way a
  `--ui` directory overrides the built-in copy, so `npm run dev` against this
  server works without rebuilding the binary; and a fresh clone that has never
  built the UI still compiles, because the generated module comes out empty and
  everything falls through to disk.

**Also:** gzip had appeared in three places — PMTiles directories, the asset
embedder, and the server decompressing for non-gzip clients — so it moved to
one `ocaml/gzip` library. The compressor uses a fixed timestamp, or an embedded
asset would make the binary irreproducible for no reason.

**Caveat, stated rather than hidden:** the binary dynamically links `libgmp`
through Zarith, so "a clean machine needs nothing installed" is not quite true.
It needs `libgmp10`, which Python and GnuPG already pull in nearly everywhere.
Recorded in the tarball's README and left open in Phase 7 rather than quietly
dropped.

**Measured:** 6 assets embedded, 5.4 s to compile them in, 15.2 MB server
binary, 13 MB tarball. The served core is byte-identical to the built bundle.

**Follow-on:** Phase 7 keeps `.deb`, AppImage, a desktop entry, and the libgmp
question.

---

### 2026-08-17 — Server hardening and a toolchain setup script

**Phase:** 0, 5

**What:** Sessions expire (1 hour TTL, 1024 ceiling, swept on write) and
`/api/session` is rate limited (token bucket, 10 burst, 1/s, `429` with
`retry_after`). `tools/setup.sh` installs the pinned toolchain from nothing,
with `--check` to report without changing anything.

**Rationale:**

- *Only one endpoint is rate limited, deliberately.* PBKDF2 is the only
  expensive thing the server does — that slowness is the point of it — and
  that is exactly what makes an unauthenticated route calling it a lever for
  exhausting the host. Limiting cheap routes would cost latency for no
  security.
- *The limiter is a pure function of state and time,* with the clock injected.
  That makes refill, exhaustion, the burst ceiling and a backwards clock
  testable directly rather than by sleeping through them. The backwards-clock
  case is the one worth having: a naive elapsed-time refill mints tokens when
  the clock steps back.
- *Sessions are swept on write, not on a timer.* There is nothing to tidy when
  nothing is happening, and an idle server should not wake up to do it. A TTL
  alone still admits unbounded growth inside one window, hence the ceiling too.
- *`setup.sh` compares its versions against `ci.yml` and refuses to run if they
  disagree.* Two copies of a pinned version drift; this makes the drift a hard
  error rather than a contributor proving something CI does not. It will not
  install opam itself — how you get the package manager is a decision about
  your machine, not one this repository should make.

**Follow-on:** Phase 0 is closed.

---

### 2026-08-17 — Rounds raised to 16; grid version bumped to 2

**Phase:** 2 (locked decision revised)

**What:** The Feistel round count went from 10 to 16, and the grid version
string from grid-1 to grid-2. Every address
changed. All nine modules re-verify, all seven suites pass, and the
independently written implementation agrees on the new addresses.

**Rationale.** The construction is the family underlying FF1/FF3, which has a
real attack literature. Those attacks need query counts far beyond what this
threat model exposes, and 10 rounds matched FF1. But the parameters have not
been checked against the published bounds, addresses are permanent once
issued, and the cost of margin is linear and small. Buying it was free today
and impossible later — the same argument that justified the rename.

Measured: 180 µs per encode in the browser build, up from about 112 µs. A
full grid redraw with labels is roughly 216 ms, which runs in a worker and
never touches the render thread.

*The version string had to move with it.* The rule was written for
regenerating the band table, but it exists for a broader reason: an address
issued under the old parameters must fail loudly rather than quietly resolve
somewhere new. Changing the round count has exactly that effect, so the string
bumped too.

**Worth keeping:** the proof is round-count agnostic but not parity-agnostic.
An earlier negative control set `rounds` to 9 and verification failed, because
the halves swap domains each round and only an even count returns them. So
changing this number is checked by the prover rather than by inspection.

**Measured, and it reframes the key-derivation question:** the browser build
takes 241 ms per derivation at 2048 iterations, while an optimised GPU does
~244,000 per second — about 59,000x faster. Raising the iteration count scales
both sides equally and never closes that gap. The gap only closes by making
our own implementation fast, which means a native hash in each target. Now an
explicit Phase 4 item rather than an assumption that "PBKDF2 is slow, so we
are fine".

**Follow-on:** three Phase 4 items — a fast key derivation, in-app phrase
generation (the highest-value one, since a made-up phrase is the only case
where derivation cost decides anything), and writing the FE1 parameter
analysis down properly. Coarse precision moved to Phase 8 with the measurement
that killed the cheap version.

### 2026-08-17 — In-app phrase generation, privacy mode, and a UI/UX baseline

**Phase:** 4 and 6

**What:** `Tessarium.mnemonic_of_entropy` turns 32 bytes into 24 BIP-39
words, pinned to BIP-39's own published 256-bit vectors. The worker draws the
bytes from `crypto.getRandomValues` and the UI offers "Generate one for me".
Cell addresses are no longer drawn on the map at any zoom, and the bulk
address operation that fed them is gone. The panel gained an eye toggle that
removes the address from the DOM and a copy button that still works while it
is hidden. The passphrase explanation was rewritten for a non-technical
reader. The map is keyboard-operable: Enter takes the centre square.

The UI was rebuilt against the standards added to `CLAUDE.md` mid-task:
React Query for everything crossing into the worker, Zustand for app state,
Paraglide for messages in six locales (en-US/GB/CA, fr-FR/CA, es-US), Sonner
toasts for action outcomes, a banner for site-wide conditions, a shared
`IconButton` over Radix Tooltip, lucide icons, zod at the worker boundary,
Biome for linting and dprint for formatting.

**Rationale:**

- *Addresses come off the map entirely.* The item on the roadmap was about
  label placement above z20.5. Removing them is better than placing them: an
  attacker's search needs (address, real place) pairs, and a screenshot of a
  labelled grid is fifty pairs in one image from a user who thought they were
  sharing a picture of a street. One square at a time, in the panel, and the
  eye toggle takes that to none.
- *Generation stays pure.* `mnemonic_of_entropy` takes entropy rather than
  producing it. Where the bytes come from is the only thing that decides
  whether a phrase is worth 2^256 guesses or 2^40, and it is the one thing
  that cannot be judged from the output — a phrase from a counter is
  indistinguishable from one from a hardware RNG. Keeping randomness at the
  edge leaves it visible and leaves the encoding testable against BIP-39.
- *Paraglide, not a runtime dictionary.* Messages compile to typed functions,
  so a key that does not exist fails the build. Configured with
  `globalVariable` + `preferredLanguage` and no cookie or localStorage,
  because this application persists nothing and the end-to-end test asserts
  it. A language choice therefore lasts for the session only.

**Bugs found and fixed, each with a test that fails without the fix:**

- `zoo.zoo.zoo.9999` was invalid under grid version 1 and is valid under
  version 2, so the end-to-end check that it is refused had silently stopped
  testing anything. Invalid addresses are now generated into `vectors.json`
  by the core and track the grid.
- `check-suites.sh` identified the js_of_ocaml suite by its check count, so
  adding a test was indistinguishable from a suite that had stopped running —
  the exact failure that script exists to catch. It matches a name now.
- A generated phrase landed ~200 ms after the click and overwrote anything
  typed in the meantime. The field is read-only while the request is out.
- Two end-to-end waits were satisfied by state that predated the action they
  were waiting on, which left requests in flight to land later and race.

**Follow-on:** The translations are unreviewed; Paraglide fetches its plugin
from a CDN at build time, which conflicts with shipping offline. Both are in
`roadmap.md`.

### 2026-08-17 — Privacy mode on by default; Paraglide builds offline

**Phase:** 4 and 6

**What:** A newly selected square shows a masked address; the eye reveals it.
Paraglide's message-format plugin is now a pinned npm dependency referenced by
path instead of a CDN URL, so a clean checkout builds with no network after
`npm ci`.

**Rationale:**

- *Concealed by default.* The two states do not cost the same. Revealing an
  address the user did not ask to reveal hands it to whoever is behind them;
  hiding one they wanted costs a click. Copy still works while concealed, so
  the common case — get the address, send it to someone — needs no reveal at
  all.
- *Plugin from npm, not a CDN.* Closes the open question. The alternatives were
  committing 120 KB of compiled third-party JavaScript that nobody had read, or
  keeping a build-time network dependency in a project that otherwise ships
  offline. The npm package is the same artifact, pinned in the lockfile and
  installed by a step the build already runs.

**Bug found and fixed, with a test that fails without the fix:** Paraglide
treats a plugin it cannot import as a warning and then reports success, having
compiled nothing at all. The message test now checks the compiled output
against the catalogue, so that becomes a failure instead of an empty UI.

### 2026-08-17 — Adversarial review of the translations

**Phase:** 6

**What:** Two independent reviewers went over the French and Spanish against
the English source. Both returned "not safe to ship". Every finding is applied.

**Rationale:** The defects were not style. In French, `gate_passphrase_what`
attached "celle-ci" to the wrong noun, so the sentence written to stop people
confusing the passphrase with a second seed phrase said "your 24 words and
this second seed phrase decide"; and the wallet warning said `graine de
portefeuille`, a calque no French speaker uses for the thing every other
string called a `phrase de récupération` — a user could read the warning,
agree with it, and paste their wallet seed anyway. In Spanish, the wallet
warning's dropped subject resolved to the attacker ("if *they* also hold
funds"), and `contraseña` filed an unrecoverable secret under the same mental
heading as a password you can reset. Both files also named the Enter key as
the verb "to enter" in the screen-reader label.

The English changed too: "Click any square" became "Tap or click", because the
UI rules require touch parity and the source string did not have it.

**Follow-on:** A native speaker should still read all three. Recorded in
`roadmap.md`.

### 2026-08-17 — Hardened key derivation and NFKD passphrases

**Phase:** 4

**What:** One key-derivation version bump carrying two changes. Passphrases are
NFKD-normalised before hashing, as BIP-39 requires. A second PBKDF2-SHA512
stage of 200,000 iterations now derives the Feistel key from the BIP-39 seed,
replacing HKDF. The browser derives with WebCrypto instead of the bundled core.
`derivation_version` moves to kdf-2; every address changed.

**Rationale:**

- *Argon2id was the plan and was rejected on measurement.* Pure-OCaml Argon2id
  at 64 MiB costs 21 s in a browser (BLAKE2b through js_of_ocaml: 9.2 MiB/s
  against 72.6 MiB/s native). Browser-viable parameters would be ~8 MiB, too
  little memory to justify the primitive. Kept on the roadmap with the numbers.
- *Hardened PBKDF2 instead.* BIP-39 fixes its own stage at 2048 iterations
  forever, but the seed is an intermediate here, so a second stage costs an
  attacker linearly and leaves the phrase standard BIP-39. 2048 -> 202,048 is
  98.7x: the ~10^14 single-pair forgery search goes from ~47 days on a 100-GPU
  farm to ~13 years.
- *WebCrypto in the browser.* Measured: our PBKDF2 through js_of_ocaml does
  ~8,500 iterations/s, WebCrypto 4.1 million — about 480x. That is what makes
  the new cost affordable: unlock measured at **289 ms**, against 241 ms for
  the old 2048-iteration derivation. The browser now runs different code from
  the server for this one step, which the coordinate checks below pin.
- *Iteration count by measurement.* 200,000 costs 1.2 s natively, paid only by
  the opt-in `--api` mode and the build. Higher counts are browser-cheap and
  natively expensive; this is where the two meet.

**Bugs found and fixed, each with a test that fails without the fix:**

- **The end-to-end suite never verified the browser's key.** Looking up an
  address, flying to it and clicking the square is a decode-then-encode round
  trip, which returns the address you started with under ANY key — a wrong key
  decodes it to a different place and re-encodes that place to the same words.
  The suite would have passed with the derivation completely wrong. It now
  reads the panel's coordinates back and compares them to the vector's point,
  which is the only output a wrong key changes.
- **The first NFKD test was hollow.** It unlocked with the decomposed
  passphrase, but NFKD's *output* is the decomposed form, so it passed with
  normalisation removed entirely. Reversed: it now feeds the precomposed form,
  which is the direction that can fail.
- Test points were (0, 0), which is also what a failed coordinate parse
  produces. Both the main sample and the NFKD vectors now use ordinary
  mid-latitude points.

**Follow-on:** Argon2id stays open, now with the measurements that rejected it.

### 2026-08-17 — Version-skew detection moved out of the UI

**Phase:** 6

**What:** The mapping-version line lasted one commit. The panel now shows only
`Tessarium v0.1.0` (baked from package.json at build time); the grid and
derivation versions are checked by the end-to-end suite against the vectors —
a direct worker probe, no DOM. Verifiable build identity went to the roadmap
as a Phase 7 item with the design constraint recorded: self-reported hashes
are theater, verification must happen outside the app.

**Rationale:** The skew that motivated the display was a development-phase
event (two mapping bumps in one day). A test catches it wherever it recurs;
a footer line taxes every user forever for it. Reversed on user direction.


### 2026-08-17 — In-app region downloader

**Phase:** 6

**What:** "Download maps for this view", end to end. Server: POST
/api/basemap-{estimate,download,status,cancel}, reachable without --api (they
carry a bounding box, never key material); tile and asset sources are the
`--basemap-source` / `--basemap-assets` flags, never the client; an Eio fiber
writes map.pmtiles.part and renames on completion; glyphs and sprites are
fetched and untarred once, if missing. Shared plumbing landed first as
`pmtiles_source` (the CLI's byte sources as a library), `Basemap_job` (pure
state machine) and `Untar` (pure, escape-safe). UI: a download button on the
map and an action on the missing-basemap banner open a non-modal card —
estimate, confirm, progress, cancel — all network state in React Query,
15 new message keys in all six locales. On completion the style is swapped
with a cache-busting query string and the grid/selection overlay re-added,
with no page reload, because a reload drops the key. The e2e now boots TWO
server instances: the one under test starts with an empty basemap directory
and downloads from the second, which serves a generated fixture (tiny valid
PMTiles of hand-encoded MVT tiles + sprite/glyph tarball, from
`gen_basemap_fixture`), so the suite drives our Range client against our own
Range server with no external network. 59 e2e checks, 100 server checks.

**Bugs found while building it, each now pinned by a test:**
- A POST whose declared body was never drained left its bytes in the
  keep-alive connection, where they were parsed as the start of the next
  request — every later status poll on that connection returned 405. The
  reverse mistake (reading a body that was never declared) hangs a bodyless
  curl until timeout. `Serve.declares_body` decides from the headers; unit
  tests cover both directions, and the e2e's polling loop is the integration
  regression.
- A small download can run idle-to-done entirely between two 1 s status
  polls, so "did my download finish?" was unanswerable from states alone.
  The status envelope now carries a generation counter that increments per
  start; the e2e's fixture download completes near-instantly on purpose.
- The missing-basemap banner never fired: it sniffed MapLibre error messages
  for "pmtiles", and the real messages name nothing. The UI now asks the
  server directly (HEAD /basemap/map.pmtiles); the e2e starts with an empty
  basemap directory, so the banner path runs every time.
- `make test-ui`'s cleanup trap ran after `cd ui`, so its `kill $(cat
  .server.pid)` found no file and the test server leaked. The e2e now runs
  in a subshell.

**Follow-on:** one region at a time — a new download replaces the archive —
recorded as an open roadmap item, with region merging as the likely shape.

### 2026-08-18 — World map first, merged downloads, and the speed fix

**Phase:** 6

**What:** The downloader reworked around the way people actually use offline
maps, on user feedback that a grey screen gives nothing to aim a download at.
Three pieces. (1) `Pmtiles.Merge`: downloads now merge into the archive on
disk instead of replacing it — union of tile sets, base copy wins, directories
rebuilt — so the world map survives every city added on top, estimates quote
only the bytes you do not already hold, and an area you have reports
"covered" (the UI says "you already have this" and disables the button). The
generic writer under both extract and merge is `Extract.write_tiles`;
`Archive.entries` enumerates an archive for merging. (2) World-first UI: with
no basemap on disk the card leads with "Download world map" — the whole world
at zoom 6, measured at ~44 MB against the Protomaps planet build (z7 is
187 MB, z8 551 MB) — and drops the offer once an archive exists. From there:
find the place on the world map, zoom, download the view. (3) Speed: every
range request was its own TLS connection, so a city download was thousands of
handshakes; `Pmtiles_source.with_readahead` fetches 1 MiB windows that the
small ascending reads (directories, then clustered blobs) land in. The real
world download now completes in ~30 s. The e2e drives the full sequence
offline against the fixture server: world at generation one, view detail
MERGED at generation two (header proven to span z0–15 by its own bytes),
covered-state on the third ask. 64 e2e checks, 45 pmtiles checks (merge
mutation-verified: dropping the data-offset translation fails the
byte-for-byte check).

**Rationale:** "There's so much of the world not filled in — no idea what to
download since the whole screen is gray." The world overview is what makes
every later choice visible, and merging is what makes it affordable.

**Follow-on:** base-wins means held tiles never refresh and the archive only
grows; recorded as an open roadmap item (refresh action + eviction story).

### 2026-08-18 — Tile budget and the country picker

**Phase:** 6

**What:** Two follow-ons to the world-first downloader, both from live use.
(1) The wedge: "download this view" over half a continent asked for street
level across the whole box — ~40 million tile ids to plan, minutes of
grinding during which the single-domain server answered nothing (and the
likely cause of an earlier unexplained server death, via memory). New
`Tile_id.depth_for` caps every plan at 8,192 tiles: depth follows area, so a
city view still gets z15, a continent stops at regional detail, and the
whole world lands exactly on the overview zoom. The estimate reports the
depth it chose; the card says "stops at regional detail — zoom in and
download again for street level" when it clamps. The continental estimate
that hung for minutes now answers in 1.6 s. Client requests also carry a
120 s abort so a wedged server can never again present as "checking…"
forever. (2) The picker: download a country or state by name, as the
established offline map apps do. Catalogue committed at ui/src/regions.json
(Natural Earth, public domain; 177 countries, 294 subdivisions across nine
federations), regenerated offline by tools/gen-regions.py; names localised
at runtime with Intl.DisplayNames from ISO codes, so no message keys per
country. The card's three offers (world, this view, picked region) now run
through one shared Offer component — estimate, covered, depth hint, confirm
— so they cannot drift. e2e: UK picked by its localised name merges in at
generation three; the US select exposes 51 states. 67 e2e checks, 49
pmtiles checks, 938 message checks.

**Rationale:** "Several minutes now" — the estimate was not slow, the server
was wedged planning an impossible request; the budget makes the impossible
request mean something sensible instead of refusing it. The picker is the
answer to "most open source android maps have this option".

**Follow-on:** full-depth country downloads (yieldful planning, resume) and
polygon-clipped regions, both on the roadmap.

### 2026-08-18 — Full-depth country and state downloads

**Phase:** 6

**What:** An explicit country or state pick now downloads the WHOLE thing at
street level, on user direction ("if a person picks a whole country, they
need to literally get the entire country down to the lowest level of
detail"). `Tile_id.download_depth` replaces the flat 8,192-tile clamp with
two tiers: any request that plans within 6,000,000 tile ids gets its full
depth — verified live: France 9.4 GB / 2.3M tiles / z15 (estimate in 16 s),
California 1.5 GB / z15 — and only boxes beyond the ceiling (Brazil, a
world-spanning viewport) fall back to a quick 131,072-id regional plan, with
the card's hint now saying to zoom in or pick a state or province. The
million-id planning loops yield to the scheduler (`Extract.plan ?on_tile`,
`Merge.plan ?on_entry`, injected closures with cancel polling), proven live:
healthz answered in 34 ms while a second France plan was mid-flight, and
planning is now cancellable. Depth-decision mutation-tested in the pmtiles
suite (France/California unclamped at 15, Brazil clamped, world quick).
67 e2e checks (UK now merges at true z15 against the fixture), 53 pmtiles
checks, 938 message checks, all suites green.

**Rationale:** "It keeps tailoring the view to this level of detail and then
when I zoom in more, I have to download again." Tailoring is now the
exception with an honest explanation, not the rule.

**Follow-on:** the giants (Brazil-scale boxes, Alaska's antimeridian bbox)
need chunked resumable downloads; the final directory build blocks briefly;
a country plan holds ~300–400 MB transiently. All in the roadmap item.

### 2026-08-18 — Multi-select downloads and the city catalogue

**Phase:** 6

**What:** The picker is now a filterable tree: every country expands to its
states and its cities (Natural Earth 50m populated places joined into the
committed catalogue — 1,198 cities across 173 countries; boxes drawn by
prominence and latitude, since the source carries points), and any mix of
checkboxes across any number of countries rides in ONE download.
`Merge.plan` takes a list of fresh regions and dedups them against each
other by tile id exactly as against the base, so a country plus one of its
cities pays for the overlap once — proven byte-for-byte in the pmtiles
suite (both boxes in one request equal extract-then-merge) and through the
UI in the e2e (adding London to a UK selection leaves the price unchanged).
The API now takes {"regions": [...]} (a bare box is refused) and answers
per-region max_zooms, so the card names exactly which picks are too big for
street level (Intl.ListFormat) while each region is depth-budgeted on its
own — one giant pick no longer drags the states beside it down to regional
detail. Estimates fire after the selection settles for 500 ms, not per tap.
71 e2e / 56 pmtiles / 105 server / 962 message checks, all suites green.

**Rationale:** "I'd like some sort of expanded view where I can select
multiple states or cities at the same time." Built on native
details/summary and checkboxes rather than a component library: every
behavior in the tree — disclosure, toggling, keyboard focus — is the
browser's own, per the house rule of taking primitives instead of
re-implementing behavior.

**Follow-on:** several full-depth countries in one selection plan
sequentially and can outlive the client's 120 s estimate timeout — noted on
the giants roadmap item. City boxes are drawn, not boundaries — noted on
the boxes item.

### 2026-08-18 — Grid overlay lost after a download's style swap

**Phase:** 6

**What:** After any completed download the map rebuilt its style, and the
grid and selection overlay never came back: when MapLibre's style diff
succeeds it fires style.load synchronously inside the setStyle call, and
rebuildBasemap registered its once-listener after the call — too late,
every time. Each missed listener stayed armed and repaired the NEXT swap,
so back-to-back downloads masked the loss and a single download (the
real-world case — reported over a fresh Georgia download) lost the grid
until reload. Fix: register the listener before setStyle (serves both the
synchronous diff path and the asynchronous rebuild fallback), plus an
idempotence guard in addOverlay. Regression test per the hard rule, shown
failing first: the e2e now asserts the overlay's sources and layers survive
the FIRST download's swap and that the grid refills, via a
window.__tessarium_map test handle (the map holds tiles and geometry,
never the key or an address). 73 e2e checks.

**Rationale:** checked after the first download deliberately — the leaked
listeners made any later swap look healthy.

### 2026-08-18 — Resumable multi-part downloads for the giants

**Phase:** 6

**What:** Boxes too big to plan in one piece (over 6M tile ids) now split
into at most eight parts that each fit the proven single-part envelope
(`Tile_id.split`: bisect the worst offender along its longer tile axis;
coverage proven exactly in the pmtiles suite -- union of part ids equals the
box's ids). Parts fetch sequentially, each merged into the archive and
renamed atomically; an interruption or cancel keeps every finished part, and
a re-request finds a held part covered and skips it after planning alone --
that is the resume, proven in e2e against a third server instance running
`--tile-budget 1024,256,8` (split download completes with parts >= 2;
re-download skips every part and says "already have"). Single-box regions
still ride one merge so overlapping picks keep deduping. `Merge.plan`
rewritten from hashtable to sorted-array merge-join (~3x less memory on
giant bases; byte-for-byte identical output under the existing round-trip
checks). Job states carry part/parts; the UI bar tracks the current part
("Part 2 of 4"). Estimates plan units one at a time and discard them
(bounded memory); client estimate timeout raised to 300 s. Live against the
planet build: Brazil 6.03 GB / 17.9M tiles / z15 estimated in 52 s;
continental US 19.1 GB / 21.7M tiles / z15; healthz under 1 s mid-plan.
77 e2e / 61 pmtiles / 106 server / 974 message checks green.

**Rationale:** sequential atomic part-merges reuse the entire existing merge
machinery -- resume falls out of base-wins dedup rather than a new on-disk
format. The write amplification that buys is recorded on the roadmap item.

### 2026-08-18 — Polygon-clipped countries and honest antimeridian boxes

**Phase:** 6

**What:** Country downloads now stop at the border instead of the bounding
box. The catalogue carries each country's outer rings (Natural Earth 110m,
Douglas-Peucker simplified to a 300-point budget, 2-decimal quantised;
229 KB total), and the picker sends them with each region. The server
validates polygons at the door (64 rings / 2048 points / in-range, tested),
plans them with a quadtree walk (`Tile_id.clip_walk`: prune outside
subtrees, enumerate inside subtrees arithmetically, per-tile tests only on
the border -- proven equal to the per-tile definition by brute force in the
pmtiles suite), and budgets and splits giants with clipped counts.
Antimeridian countries become two honest boxes clustered from polygon
parts (Russia: 19..180 plus -180..-169.9; Fiji likewise) riding the
existing multi-region API -- no server change at all. Live: France
polygon-clipped is 5.23 GB / 1.14M tiles / z15 in 12.9 s, versus 9.36 GB
for the metropolitan box alone, and now includes Guiana and Corsica;
clipped Canada (~36M ids) fits the giant ceiling its 112M-id box never
could. 79 e2e / 66 pmtiles / 110 server / 974 message checks green.

**Rationale:** clipping in the planner (quadtree, O(border)) rather than
per-tile keeps a z15 country affordable -- a ray cast per candidate tile
would be billions of tests. Holes deliberately unmodelled: downloading the
Lesotho-shaped sliver inside South Africa is harmless; missing an enclave
would not be.

### 2026-08-18 — Polygon branch review findings fixed

**Phase:** 6

**What:** Adversarial review found the border simplifier silently dropping
rings (Canada lost Vancouver Island; the US lost Molokai; 122 cities in all
fell outside their simplified borders) and the clipped planner burning
unyielding, unbounded CPU (a within-caps sawtooth polygon could wedge the
server for hours). Fixed: ring simplification is anchored on a real chord
and a collapsed ring survives as its bounding quad; the generator escalates
each country's point budget until every catalogued city sits inside the
simplified border, appending a city's drawn box as an extra ring when its
point sits off the coarse 110m coastline; a committed data-invariant suite
(ui/test/regions.mjs, 1,691 checks, in npm run check) ray-casts every city
against its country's polygon -- it failed 122 ways against the old data.
The quadtree walk gained a yield hook wired to the server's breathe/cancel
closure and a work budget (2^28 ring-point operations) that kills
pathological polygons cleanly. Antarctica, which encircles a pole and
defeats lon/lat ray casting, ships no polygon and two hemisphere boxes.
Plus: polygon null and [lon,lat,elev] positions accepted; classify gets
direct unit checks; a multi-box country's depth warning stays named.

**Rationale:** cities are the acceptance test for a border because they are
exactly what a country download must contain.

### 2026-08-18 — Contrast audit enforced; error toasts wait to be read

**Phase:** 6

**What:** Every foreground/background pair the stylesheet uses is now
measured against WCAG AA by ui/test/contrast.mjs (41 checks, wired into
npm run check), reading the palette live from styles.css so drift fails the
build; literal-presence checks keep the hand-listed pairs honest. The audit
found the active palette already passing -- --accent's 3.95:1 is only ever
the 19px/600 address line, which is large text at a 3:1 bar, and that
rationale is now pinned in the test -- and one genuinely illegible pair:
disabled button labels at 1.63:1 (WCAG-exempt, but unreadable), now 5.66:1.
Review fixes went further: the large-text exemption
for the accent died entirely (a mobile media query renders the address at
17px, under the bold threshold) -- the address now uses --accent-text at
4.84:1; sonner's richColors was dropped because its red-on-pink error text
sat at 4.35:1 outside the stylesheet where no audit can see it; input and
select borders moved to --line-strong (3.44:1, non-text 3:1) from a 1.33:1
hairline; placeholders are pinned to the audited hint colour. Error toasts
persist until dismissed (ui/src/toast.ts wraps every toast.error call; the
e2e asserts a toast carries the close button): a five-second auto-dismiss
is shorter than a long error read aloud through sonner's live region.
Out of the audit's reach, recorded here: canvas-drawn grid and selection
colours over arbitrary map imagery are not statically checkable. 51
contrast checks, 80 e2e checks green.

**Rationale:** an audit that runs once rots; this one runs on every check.

### 2026-08-18 — FE1 security write-up

**Phase:** 4

**What:** docs/fe1-security.md, linked from the README: the construction's
exact parameters (a ≈ 2^22.6, b ≈ 2^23.6, 16 rounds, HMAC-SHA256, fixed
tweak); the two oracles and their arithmetic (raw encode 81 µs, measured
at 16 rounds by the new ocaml/tools/bench_encode.ml; with the 1/s-burst-10
limiter, a million queries ≈ 11.6 days, the full codebook ≈ 2.7 million
years); Bellare–Hoang–Tessaro 2016,
Durak–Vaudenay 2017 and Hoang–Miller–Trieu 2019 each named with why it
does not reach these parameters (small-domain data requirements; chosen
tweaks against a compile-time tweak constant; 8-round FF3 structure); the
codebook-is-not-the-key endgame; the two key-search spaces stated together
(KDF prices phrase guessing only; the raw 2^256 keyspace needs no pricing
and yields no phrase); the quantum dismissal with citations
(Kuwakado–Morii needs superposition queries; offline-Simon targets
Even–Mansour/FX, not 16-round PRF Feistel). Every number cross-checked
against the source before writing.

**Rationale:** the roadmap demanded the dismissal read as informed, with
the load-bearing role of the rate limiter written down rather than assumed.

### 2026-08-18 — Writing the security doc found the limiter gap

**Phase:** 4

**What:** Adversarial review of the FE1 write-up refuted its central
quantitative claim against the code: only /api/session was rate-limited;
encode and decode were raw oracles answering at full speed, so "a million
queries ≈ 11.6 days" described a control that did not exist. The limiter
now covers every key-touching endpoint via a pure, tested
rate_limited_endpoint predicate applied at dispatch (mutation-tested: the
suite fails three ways when encode/decode leave the set). Scripting
consequence, deliberate: the opt-in API now answers at most 1 encode or
decode per second sustained. Also corrected from the same review: the KDF
chain is two PBKDF2 stages (HKDF text was stale in the locked decisions and
copied into the doc); encode is 81 µs at 16 rounds, measured by the new
committed bench, not the ten-round-era 53 µs; the 2:1 split is
"near-balanced, tolerated", not "balanced"; attack families are
round-parameterized (demonstrations at 8-10 rounds), stated as such; the
offline-Simon citation no longer absorbs Hosoyamada-Sasaki's separate
six-round classical-query Feistel work. CLAUDE.md still names the tweak
at grid-1 (code says -2); left for the user, per its own rule.

**Rationale:** the write-up exists to be checked against the code; being
falsified by its own review and forcing the code to match is that working.

### 2026-08-18 — Desktop packaging: static gmp, .deb, AppDir, repro CI

**Phase:** 7

**What:** libgmp is now linked statically into both binaries -- via a
search-path trick (a build directory holding only libgmp.a outranks the
system's .so for every -lgmp), because zarith's cmxa embeds its own flag
ahead of anything the command line can say -- so the tarball's "needs
nothing installed" claim is finally true, and its README says so (GMP is
LGPL; the repository's full source alongside is what keeps that
compliant). tools/package.sh now emits a bit-deterministic tarball (sorted,
root-owned, fixed mtimes, gzip -n) carrying the new desktop entry and icon;
tools/package-deb.sh builds a deterministic .deb (SOURCE_DATE_EPOCH;
depends on libc6 alone) with menu integration; tools/package-appimage.sh
builds a complete AppDir and hands off to appimagetool, which CI images do
not carry -- the residue is a roadmap line. Determinism proven locally:
tarball and .deb hashes identical across rebuilds, the UI bundle identical
across clean builds, and CI gained a `reproducible` job that builds and
packages twice from clean and diffs the checksums -- the first rung of
verifiable builds, leaving that item blocked on a release key only.
`make package-deb` and `make package-appimage` wired. Full wall green
(80 e2e / 51 contrast / 1691 catalogue / all 7 dune suites).

**Rationale:** published checksums are worthless if the build is not
bit-reproducible; the CI job is what keeps that property from rotting.

### 2026-08-18 — Packaging review findings fixed

**Phase:** 7

**What:** The reproducible-CI job could never pass -- its git clean deleted
the vendored fstarlib modules the second build needed (now excluded). The
.deb's hardcoded libc6 floor understated reality (binaries import
GLIBC_2.35; the floor is now computed from objdump at build time). Both
artifacts inherited the packager's umask (077 broke dpkg-deb outright; 002
shipped group-writable /usr) -- both scripts now set umask 022 and tar
normalizes modes. The .deb gained md5sums and a copyright file naming GMP's
LGPL and source now that it is statically embedded; the tarball README
likewise. AppRun no longer makes --basemap unrepeatable. Installed-Size
uses apparent size. Determinism claims scoped honestly: bit-identity holds
per-toolchain; cross-machine identity needs the ~60 absolute opam paths
scrubbed from the binaries first (recorded on the verifiable-builds item).

**Rationale:** a reproducibility check that cannot pass, guarding a
dependency floor that cannot hold, is worse than none -- it certifies.

### 2026-08-18 — Ten-million-point differential sweep, key-varying corpus

**Phase:** 1-3 (the extraction-trust gap)

**What:** The differential corpus can now vary its key:
ocaml/tools/differential.exe takes --mnemonic and --passphrase and stamps
them into the corpus header, and js/differential.mjs derives its key from
that header -- so a sweep now exercises the KDF chain and the Feistel
schedule differentially, not just the grid under one fixed permutation.
The CI sweep's random count grew 10x (2,000 -> 20,000; with seam
weighting, 14,298 -> 32,298 points actually checked, ~15 s). The deep run: five configurations -- four distinct
24-word seeds and one with a TREZOR passphrase, distinct RNG seeds --
of 2,012,298 points each, 10,061,490 total, every one agreeing between
the extracted OCaml and the independently written JS on cell, centre,
address and round-trip: zero disagreements. Each configuration includes
all 12,287 band-seam straddles, where an extraction bug would hide. The
run is committed as tools/differential-deep.sh -- the summary above is
this ledger's record; the script is what makes it checkable. Its review
also hardened the reporter: an empty corpus now fails the sweep instead of
printing a clean zero (which a dead generator once made look like four
passes), a cross-key decode divergence is reported instead of crashing the
reporter, and check-suites.sh refuses a zero-point differential line.

**Rationale:** the extraction gap admits no cheap proof; what it admits is
evidence at scale, and evidence that also spans keys is strictly stronger
than the same points under one key.

### 2026-08-18 — Basemap source: "latest" resolves the newest daily build

**Phase:** 5 (offline basemap)

**What:** `demo-bucket.protomaps.com/v4.pmtiles` — the default tile source —
was deleted upstream, so every download and estimate failed with a bare
"HTTP 404 fetching bytes 0-1048575". The default `--basemap-source` is now
`latest`: at each estimate or download the server resolves the newest dated
daily build from Protomaps' published listing
(build-metadata.protomaps.dev/builds.json) and reads that. The CLI and
fetch-basemap.sh accept the same sentinel; an explicit URL or path still
passes through untouched. Range-request errors now name the URL they hit.
Seven checks in the pmtiles suite pin the listing parsing (newest wins over
listing order, junk entries skipped, empty/HTML/object listings are errors).

**Rationale:** this was the roadmap's open "demo bucket carries no
availability promise" question, settled by the bucket vanishing. Pinning a
dated build instead would rot identically — only the last ~60 dated builds
exist at any moment. Resolving per operation rather than at startup is
deliberate: a long-running server outlives any single daily build. The daily
builds are still tileset schema 4.x (4.15.2), which the UI style targets.

**Follow-on:** the self-hosted-mirror half of the question stays open on the
roadmap: Protomaps promises nothing about the daily builds either, and a
mirror is ~137 GB.

### 2026-08-18 — The download ledger: list, update, remove, reminders

**Phase:** 5 (offline basemap)

**What:** Every completed download is now recorded — name, regions, date,
resolved source build, bytes — inside map.pmtiles' own metadata section, in
the same atomic rename that publishes its tiles, so the record can never
describe tiles that are not on disk. The card lists the entries with per-row
**Update** (re-fetches the region tile for tile: the merge tie inverted to
fresh-wins, the one deliberate way to refresh stale tiles) and **Remove**
(rewrites the archive without the entry's tiles; the rule is Remove undoes
the download — a tile goes exactly when the removed download would have
fetched it and no kept entry's would; removing the last entry deletes the
file). Regions older than a threshold get an "update available" nudge; the
threshold (30/90/180/never, default 90 days) persists server-side in
basemap/settings.json because the browser deliberately stores nothing.
Pre-ledger archives are adopted by re-requesting a covered area: the entry
lands with completion time zero, displayed as "age unknown" and treated as
stale. Scripted downloads without a name are recorded under their box.
New suites: ledger serialization (canonical bytes, identity from regions
alone and blind to their order, loud corruption failure — never a silently
emptied ledger), removal geometry on exact tile boundaries, refresh and
prune merge properties, endpoint dispatch, and the whole lifecycle driven
through the real card and API in e2e (103 checks, run twice for
determinism).

**Rationale:** one merged archive plus a ledger, not per-region files —
per-region archives must be self-contained, so overlapping picks would
store and download shared tiles repeatedly, defeating skip-if-held; and
the agreed browse-cache feature only makes sense in a merged store. The
ledger lives in the archive rather than a sidecar for crash-consistency;
the settings live in a sidecar rather than the archive because a
preference toggle must not rewrite gigabytes. Determinism is load-bearing
per the user's explicit requirement: fixed serialization order, an entry
id derived only from its regions (%.7f canonical text, SHA-256), and the
clock injected, never read.

**Follow-on:** the opt-in browse cache (two-tier archive) and an
update-price estimate, both on the roadmap.

### 2026-08-18 — Ledger review findings fixed

**Phase:** 5 (offline basemap)

**What:** The adversarial review confirmed the pure core (byte-determinism,
identity stability, atomicity, refresh correctness all survived attack) and
found two accuracy bugs, both verified with probes and both fixed with the
test that had been missing: the recorded `bytes` counted archive-copy
volume instead of network bytes (a 40 MB city atop a 900 MB archive
recorded ~940 MB; multi-part re-counted earlier parts) — entries now record
accumulated fetch bytes, pinned in e2e against the estimate's quote; and
entries recorded the REQUESTED zoom where a clamped giant only fetched the
GRANTED depth, so Remove claimed tiles that never existed and protected
tiles forever — entries now record granted depths, pinned in e2e by a
clamped download whose ledger row must equal the estimate's granted zoom.
The removal predicate was also aligned exactly with the planner's floor
arithmetic (a geometric edge-touch test claimed west/north neighbours of
tile-aligned boxes the covering never fetches; now pinned by a property
test: drops = covering membership over a five-zoom universe, boxes plain,
tile-aligned, sliver and clipped). Smaller findings, all fixed: adoption
was unreachable from the UI (a covered offer now becomes "Keep track of
this map"); ledger cache not invalidated on failed/cancelled though both
can follow a successful write; an update after a budget change could leave
two records claiming one place (updates now replace by id explicitly);
duplicate ledger keys read/wrote inconsistently (now refused loudly);
negative zero split identities (normalised); invisible characters passed
the name filter (Uchar-level now); freed-bytes omitted header bytes;
fr-CA punctuation; a dedicated message when a removal frees nothing
because every tile is shared.

**Rationale:** the review's framing stands as the spec: Remove undoes the
download, so the entry must describe the download that happened — granted
depth, network bytes — not the one that was asked for.

**Follow-on:** archive-level byte determinism across identical download
sequences is untested end to end (it requires a fixed clock; the ledger's
own byte-determinism is pinned); the resume-tail fallback path
(last part held, earlier parts fetched) has no dedicated test.

### 2026-08-18 — Range-request sockets leaked until the download ended

**Phase:** 5 (offline basemap)

**What:** Every HTTP range request opened a connection scoped to the
download's switch, so it stayed open until the whole download finished --
~6,400 sockets for a 6 GB country at one request per megabyte readahead
window, dead at the default 4,096-fd limit at about 86%. The live failing
case was France: 5.5 GB in, "Too many open files" out, and the .part
discarded. Each fetch now runs in its own switch, closing its connection
with its body; get_body (assets tarball, build listing) is scoped the same
way. New suite: test_source_fds drives the real http_source against a
loopback server for 80 window-missing reads and counts /proc/self/fd --
shown failing first (167 fds after, from 7) and flat after the fix.

**Rationale:** the readahead comment already recorded that each read is its
own connection and TLS handshake; the leak was that nothing ever closed
them. Closing per request keeps that accepted cost and removes the
unbounded one.

### 2026-08-18 — Tiles served through /tiles, with TileJSON from the headers

**Phase:** 5 (offline basemap)

**What:** The map's tiles now come from the server's /tiles/{z}/{x}/{y}.mvt
endpoint instead of reading map.pmtiles directly through the pmtiles JS
protocol -- the server consults the archives in order (the browse cache
first, once it exists, then the main archive), serves stored bytes with
content-encoding from the archive's tile compression (inflating for
clients that do not accept it, same policy as the embedded assets), and
answers a tile nobody holds with a quiet 204 the map renders as nothing.
Source metadata comes from a /tiles.json endpoint deriving zoom range and
bounds from the archive headers. The pmtiles JS dependency is gone; the
e2e fixture's tiles are now gzipped like the real planet build, so the
content-encoding path the browser decodes is under test.

**Rationale:** this is the structural half of the approved browse cache: a
second archive can only be consulted by something that sees both, and that
something is the server. 204 rather than 404 for absent tiles because past
the coverage edge an empty tile is a normal answer, not an error to log on
every pan.

**Follow-on:** the browse cache itself (cache.pmtiles, the browse endpoint,
compaction, the opt-in setting).

### 2026-08-18 — Tile endpoint review findings fixed

**Phase:** 5 (offline basemap)

**What:** The adversarial review reproduced a high-severity regression in a
live browser: the style hardcoded maxzoom 15, and MapLibre only overzooms
past the SOURCE's stated depth -- so a world-at-z6 archive (the product's
own recommended first download) rendered a blank basemap at street zoom
over data it held. The pmtiles protocol used to supply that metadata from
the archive header; the /tiles.json endpoint now restores it, plus bounds,
and the e2e pins the source's effective maxzoom to the archive's. Also
found and fixed: HEAD /tiles/ wrote the tile body after its headers,
poisoning keep-alive connections (now an Expert response that writes
nothing on HEAD); the 204 carried a content-length, which RFC 9110
forbids (rebuilt without one, plus cache-control); tiles ignored
Accept-Encoding where the asset path inflates for non-gzip clients (now
mirrored); and the gzip branch was untested because the fixture was
uncompressed (now gzipped). TileJSON tile URLs are absolute, built from
the request's validated Host header -- MapLibre substitutes them inside a
blob-URL worker where relative URLs have no base.

**Rationale:** the reviewer's framing was right: the pmtiles protocol was
quietly supplying source metadata, and replacing the transport without
replacing the metadata was the regression. TileJSON replaces all of it in
one endpoint and buys back bounds for free.

### 2026-08-18 — The browse cache: opt-in tiles while panning online

**Phase:** 5 (offline basemap)

**What:** With the new setting on (off by default, gated server-side so a
page cannot make the server reach the network against the user's choice),
a settled pan fetches the viewport's missing tiles -- capped at 1,024 per
request -- into cache.pmtiles, a second small archive the tile endpoint
consults first. The map refreshes the visible tiles when a fetch lands.
Past a compaction threshold (budget's fourth field; default 48 MB) the
cache folds into the main archive under the job's one-writer rule, ledger
carried forward untouched -- browsed tiles are anonymous by design, and
never earn an entry. Two rules keep the tiers coherent: a completed
download or update prunes its region out of the cache, so a stale browsed
copy can never shadow bytes just fetched (the endpoint prefers the cache);
and browsing is refused while the archive writer runs. End to end in the
suite: gate off means 403, a browsed z15 tile 204s before and 200s after,
the one-byte test threshold forces a real compaction whose ledger stays
intact, and a second look fetches nothing.

**Rationale:** the two-tier design was agreed with the user before
building: per-gesture rewrites of a multi-gigabyte archive are absurd,
per-gesture rewrites of a small cache are cheap, and one fold amortises
them. The prune-on-download rule answers the one real coherence question
(which copy wins where tiers overlap): recorded regions own their tiles.

**Follow-on:** the UI browse trigger (pan-settled fetch) is exercised
manually, not in e2e -- the fixture areas the main test server can browse
are already downloaded by earlier checks; recorded here rather than
hidden.


### 2026-08-18 — Browse cache review fixes

**Phase:** 5 (offline basemap)

**What:** Adversarial review of the browse cache, all findings fixed. Two
majors on the server: the browse and compaction merge paths skipped the
compression guard (a source switching schemes would have relabelled every
archived tile as the wrong compression in one silent rename -- both paths
now refuse loudly), and the cache prune ran only on the success path (a
cancelled or failed download now prunes too, since every renamed part
already owns its region; the prune itself is no longer cancellable, so the
cancel path cannot abort the very cleanup it depends on). One major in the
UI: the browse fetched Math.round(zoom) where MapLibre displays floor(zoom)
-- half of all zoom positions fetched tiles the screen never asks for --
and a browse deeper than the source's pinned maxzoom now rebuilds the style
so tiles.json advertises the new depth, instead of refreshing tiles MapLibre
will never request. Minors: compaction now unlinks the cache before the
rename (a crash between the two costs re-fetchable browsed tiles, never a
permanent duplicate cache shadowing the archive); settings writes are
serialized under a mutex (two quick clicks could lose a field or corrupt
the file unrecoverably); the prune's wait on a live browse is a condition
wait, not a hot spin; a failed compaction-trigger check no longer tears
down the browse response; browse failures discard cache.pmtiles.part; a
browse that starts a compaction wakes the status poll so the UI can see it,
and a failure seen in the compacting state gets its own toast. Privacy:
turning the browse setting off now deletes the cache -- off means gone, and
the hint says so. Float-spelled whole zooms (15.0) are accepted.

**Rationale:** the review's tenth finding was the sharpest: the central
coherence rule (prune-on-download) had zero automated coverage, because the
only server that browses in e2e compacts instantly. The suite now removes a
deep entry on the default-threshold server to open a hole, browses it back
into a persisting cache, proves the cache serves, proves toggle-off erases
it, then downloads the same region and proves the prune empties the cache
while the tile keeps serving -- 13 new e2e checks, 4 new unit checks.

**Follow-on:** an antimeridian viewport still browses only its western
half (the box clamps at 180 rather than splitting in two); recorded as a
known limit, not worth two sequential requests today.

### 2026-08-18 — Browse cache review fixes, second pass

**Phase:** 5 (offline basemap)

**What:** A review of the previous entry's fix commit found it had introduced
two regressions of its own, and they are corrected here. The settings mutex
wrapped a fallible read: Eio POISONS a mutex whose critical section raised and
refuses it forever after, so one unreadable settings.json -- a bad mode, an
exhausted fd table -- cost the user their reminder and browse controls for the
life of the process. Now nothing escapes that block. Compaction's unlink was
moved back AFTER the rename: the window it was "fixing" was benign and
self-healing (the duplicate holds byte-identical tiles and the next browse
folds again), while unlinking first destroys every browsed tile if the rename
fails. Clearing the browse seat no longer goes through the mutex, which bought
nothing: every critical section on it is a suspension-free read or assignment,
so it is never held while another fiber runs, and the write now pairs with the
lock-free read the waiter already does. Also: turning browsing off no longer
refuses to erase because a browse holds the file -- the erasing is handed to
whichever writer holds it and happens as that writer finishes, so the request
answers immediately and the file still goes. The obvious alternative, waiting
for the browse, was written first and rejected on review: it puts an unbounded
network wait on a request the user is watching, and a stalled upstream read
would hang the response until the browser gave up, leaving the toggle showing
"on" over a setting the server had already saved;
the browse response carries the zoom the server actually wrote, so a client
deeper than its source stops rebuilding the style on every pan; `refreshTiles`
is not called without a source; `Cancelled` is re-raised rather than logged;
and the prune runs once per download, not twice.

**Rationale:** the previous entry claimed a green wall validated three major
fixes. It validated one. Two of the three had no regression test, and the
falsification that would have shown this was itself broken -- `if true then ()
else` in OCaml only skips to the next semicolon, so the "disabled" function
kept running. Verifying a test by disabling the code it covers is only
evidence when the disabling is checked too.

A second review of those corrections found one of them was itself a
regression -- waiting for the browse put an unbounded network wait on the
settings request -- and that is what the deferred erasing above replaces. It
also found three assertions that did not test what their names claimed; the
browse depth is now a named function with its own checks, the response field
is asserted end to end, and the French check was rebuilt to compare each
punctuation mark against itself rather than inferring a house style by
majority vote. That last rebuild showed the first version had "fixed" fr-FR
by moving a colon AWAY from the standard spacing, so both French catalogues
now follow the documented rule: a full no-break space before a colon, a
narrow one before the marks that take one.

**Follow-on:** the compression guard now has end-to-end coverage on a server
whose source disagrees with its archive (both refusals fail without it,
demonstrated). The cancelled-download prune still has none, and why is
recorded in roadmap.md rather than left as an unexplained hole: the fixture
shares one tile blob across every id, so no region is slow enough to cancel.
A French punctuation check was added after the space before a colon was
spelled with the wrong character in both French locales -- 1286 catalogue
checks had passed over it, and it also caught one stray that predated this
work.

### 2026-08-18 — The cancelled download's prune, tested

**Phase:** 5 (offline basemap)

**What:** The rule that a download owns its region from the moment a part
lands -- and must drop that region from the browse cache whether it finishes
or is cancelled -- now has an end-to-end test. Cancelling a download that has
published a part leaves no browsed copy of its tiles behind; removing the
prune from the cancel path fails exactly that check and nothing else,
demonstrated before the test was kept.

**Rationale:** the previous entry recorded this as untestable, because the
fixture made every download finish in under half a second: all tile ids share
one blob and the reader fetches a megabyte at a time, so a region of any size
was about three range requests. Both halves of that had to go. The fixture
generator can now give each tile its own 64 KiB slot, so reads cannot be
coalesced away, and the cancel server reads through a delaying proxy in the
e2e harness. A download is then seconds long, its first part lands early, and
"halfway" is a place that exists. The cost is a 14 MB fixture archive and a
fifth test server; the alternative was a race dressed as a test.

**Follow-on:** the same slow-source machinery would make other timing-
dependent paths testable -- resume after an interrupted part, and progress
reporting -- neither of which has coverage today.

### 2026-08-18 — Offline place search

**Phase:** 6 (web UI)

**What:** A search box over the map finds places, water and named roads inside
the downloaded region, and flies to them. Nothing leaves the machine: the
index is built from the archive's own vector tiles when a region lands, so a
query -- which names where the user is going -- is answered from disk. New
`Pmtiles.Mvt` reads just enough Mapbox Vector Tile to pull a feature's name,
kind, population and a representative point, skipping unknown fields by wire
type so a richer real tile still parses. `Place_index` walks the archive to
zoom 12, dedups a label against the tiles and zooms that repeat it, and writes
a sorted tab-separated sidecar; queries fold case and accents ("orleans" finds
Orléans), rank exact over prefix over word-start over substring, and break
ties on population then layer. Rebuilt on download, update and removal, with
its own `Indexing` job state; removing a region takes its names with it.

**Rationale:** the obvious build -- call a geocoder -- was rejected outright,
not deferred: a search query names the destination in a way even tile
requests do not, and the CSP allows no remote origin at all. Two bugs found by
running it against the real 6.4 GB France archive rather than the fixture, and
both would have looked fine in a unit test. Deduplicating a label by name and
layer collapsed all eleven French places called Paris into whichever was seen
last, so the first result for "Paris" was a hamlet; position is now part of
the identity. And ranking by layer alone offered a village ahead of the
capital, so population -- which the basemap already carries -- decides first.
Measured after the fix: France indexes in 22 s to 1.1 M entries, "Paris"
answers with Paris.

A review of the first cut found it shipped broken in ways the suite could not
see, and those are fixed here. The UI parses the job state as a tagged union
and throws on an unknown tag, so the new `indexing` state broke status polling
on every download -- the fixture is too small to ever reach that state, so
nothing caught it; the wire shape is now pinned by its own checks. The index
walk ignored `run_length`, so run-compressed entries were read once and the
tiles after them skipped, and progress could never reach its own total. The
tag reader appended to a list per tag, which is quadratic: forty thousand
unpacked tags took seven seconds inside a job fiber with no suspension point.
A search collected and sorted every match before applying the limit -- a
one-character query allocated 305 MB and sorted for 1.2 s without yielding --
and now keeps only the best few as it scans. Five CSS variables did not exist,
so the search box had no background, no border and no focus ring at all.
Cancelling during the post-download index reported the finished download as
cancelled. Names from tiles could carry a tab or newline and forge an index
row with coordinates of their choosing. And the keyboard stayed live under a
closed list, so Enter after Escape flew the map to something invisible.

**Follow-on:** street coverage, index size and query latency at greater depth
are recorded in roadmap.md; the map's controls moved to a left-hand rail
because search took the corner they were in. Compaction now reindexes, so
browsed places become findable.

### 2026-08-19 — Saying where coverage ends

**Phase:** 6 (web UI)

**What:** Outside the downloaded region the map is blank, and until now the
app said nothing about it -- a user panning east out of France could not tell
a missing download from a broken program. The blank ground is now washed grey
with a line along its edge, and a note under the middle of the view says the
map is not downloaded here and offers the downloader. New `basemap-coverage`
endpoint answers one viewport with one character per tile plus the deepest
zoom the archives reach under its centre; `ui/src/core/coverage.ts` merges the
missing tiles into rectangles, traces the boundary where missing meets held,
and projects both back to degrees.

**Rationale:** the mask reads the ARCHIVES, not the download ledger, and that
was the load-bearing decision. The ledger records what was asked for, which is
a different thing from what is on disk: this machine's archive was seeded by
the extraction tool with a world overview no ledger entry claims, browsed
tiles belong to no entry at all, and compaction folds them into the main
archive without one. A ledger-drawn mask would therefore grey out ground the
user can plainly see drawn -- worse than the silence it replaces. Asking the
same archives the tile endpoint asks, in the same order, makes the mask agree
with the map by construction, and the end-to-end test checks exactly that
agreement cell by cell rather than trusting the code that drew it. Presence is
a directory lookup with no tile body read: 1.3 ms for a typical viewport
against the 6.4 GB France archive, and 2.4-3.0 ms for the largest query the
endpoint accepts.

The boundary is drawn from the tile edges where missing meets held, not from
the outlines of the merged rectangles: two rectangles splitting one blank area
share a seam, and drawing that seam would put a line through the middle of
nothing. Nothing is drawn along the edge of the query itself, because the map
simply stops knowing there and a box around the viewport would be a claim
nobody made.

One bug the suite caught before it shipped: MapLibre reports a vector source's
spec default maxzoom of 22 until tiles.json arrives, so the first query after
every style swap asked about zoom 19 over an archive cut to 15 and was
refused, four times a run. The clamp is to the tile grid's own depth rather
than to whatever the source currently claims.

An adversarial review found seven defects worth the pass, all fixed here. The
worst was a race the feature could not survive in normal use: nothing marked
which coverage answer was current, and React Query returns a cached view in a
microtask while a fresh request is still in flight, so panning back to
somewhere left seconds ago resolved BEFORE the place passed through -- the
older answer landed last, wiped the wash and the note, and left the app silent
while the camera sat on blank ground. Newest question wins now, and the
end-to-end suite reproduces the ordering with a delayed route.

Two more were wrong answers rather than wrong drawing. The depth was measured
at the midpoint of the requested degrees while the client called the middle
CELL of the answered rectangle the middle -- different tiles for 24 viewports
in every 840 swept, which put "zoom out to see it" on screen over ground the
archive held at exactly that zoom. Both now name the same cell, and because
they do, a blank middle always reports a depth below the zoom asked about,
which is what makes the sentence true whenever it is said. And an archive that
would not open failed the whole query with a 400 -- blaming the page for this
server's own broken file, and taking the browse cache's good answers down with
it. It is skipped with a warning now, exactly as the tile endpoint skips it,
and the two failures are two statuses.

The note was wrong for touch in three ways: the whole pill took the pointer,
so a thumb drag from the bottom of the map -- the most natural gesture there
-- did nothing; its button was 32px against the 44px every other touch control
here uses; and pressing it opened the download card and then sat on top of it,
winning the hit test over the card's own controls. With browsing on it also
flashed grey and offered a download for tiles the app was already fetching,
for the 1.2 s before the browse landed. Two message keys became one: the
"never downloaded here" sentence needed a depth of -1, which no real archive
produces, so it was six locales of copy that could not render.

Keyboard focus was left on <body> when the note vanished under the user --
tiles landing, a fly-to settling -- and the first fix for it was wrong in a
way only the test could show: an effect's cleanup runs after React has already
mutated the DOM, so asking then whether focus was inside the note always
answers no. It is recorded while the note is alive instead.

Four tests could not fail. The server's straddle fixture was two identical
rows, so emitting the mask south-to-north passed the check named for it; the
UI had no check on the latitude of a horizontal edge, so moving every one a
tile row south passed all 27; the closed-box check compared minima and maxima,
which are the same set upside down; and the too-large refusal was not
distinguished from a broken archive. Each was demonstrated failing before
being kept. The wash was also raised from 1.2:1 against the background, which
is no signal at all, to something visible -- it only ever covers tiles that
draw nothing, so there is no cartography underneath to protect, and the note
carries the meaning in words regardless.

**Follow-on:** a wrapped viewport is still not a box -- recorded with the
antimeridian browse gap, which shares the same `regionOf` clamp and now has
two callers to fix at once. And the note can only say "not downloaded at this
zoom", never "you have never downloaded this place", because a world overview
covers every point on Earth; the stronger sentence needs the ledger and is
recorded as its own item. Separately, `ui/test/e2e.mjs` merged unformatted
with the place-search branch, so `make test-static` was failing on master for
a day; the formatter ran here.

### 2026-08-19 — A place named the way people name places

**Phase:** 6 (web UI)

**What:** Search matched the whole query as one run of characters inside a
single name, so "Atlanta, GA" -- which appears in no name anywhere --
answered with nothing found, while "Atlanta" answered correctly. Naming a
place more precisely made the search worse. A query is now read the way it is
written: everything before the first comma is the name being asked for, and
every word of it counts; everything after is context that ranks but never
decides. Entries are ordered by how much of the name they carry, then how
exactly they carry its first word, then how much of the context they happen
to carry, then the shorter name, then population and layer as before.

**Rationale:** two wrong designs came first, both caught against the real
6.4 GB archive rather than the fixture, and the second was caught only by
review. Letting the deepest match win outright is wrong because a two-letter
qualifier hides inside ordinary words -- "ga" sits in "Gas", "Gardens" and
"Maçons" -- so "Atlanta, GA" answered with Atlanta Gas Light Lake and
"Savannah, GA" with Savannah Gardens. Ranking the first word'"'"'s exactness
above completeness is worse: "Los" is a name exactly and "Los Angeles" merely
begins with the word, so "Los Angeles" answered with a hamlet of 100 people,
"Las Vegas" with three places called Las, and "L'"'"'Haÿ-les-Roses" with an
aeroway called L. Ten of nineteen common two-word city queries regressed that
way, and the fixture -- which holds exactly one name -- could not see any of
it. Completeness first, exactness second, context last is what survives all
three query shapes.

Measured after the change against the real archive: Los Angeles (3,863,148),
San Francisco (873,965), Las Vegas (678,922), Kansas City (508,090) and Rio de
Janeiro (6,211,223) all answer with themselves; "Atlanta, GA" gives Atlanta
(506,804), "Savannah, GA" gives Savannah (147,780), and "Macon, GA" gives
Georgia'"'"'s Macon (152,663) ahead of France'"'"'s Mâcon (34,448). Latency over the
74 MB index is 274 ms for an ordinary query and 440 ms for a deliberately
pathological one (six one-letter words); depth terms are tested with a
first-hit scan rather than the best-occurrence scan the ranked word needs.

**Follow-on:** the context cannot disambiguate two places of the same name,
and a name containing pasted punctuation is not normalised the way a query
is -- both recorded in roadmap.md, along with a third gap this turned up:
this archive holds Georgia at street detail with no ledger entry claiming
it, because tiles fetched by the command-line extractor leave no record, so
they cannot be updated or removed from the downloaded-maps list.

### 2026-08-19 — The extracted core, cross-examined by F* itself

**Phase:** 1–3 (proof work); the roadmap's "largest single gap"

**What:** Nothing executed the F*. The proofs were checked, the OCaml was
extracted, and every test in the tree ran the extraction -- so the committed
vectors, the differential sweep and the JS oracle all sat DOWNSTREAM of the
one step nobody watched. Now `fstar/check/` holds answers computed by the
extracted binary (`ocaml/tools/gen_check.ml`), and four Check modules make
F*'s normalizer recompute every one from the proved source -- the two
computations share F*'s front end and, it must be said plainly, zarith
itself, and diverge at the extraction backend, which is the step under
watch: all 4097 band-table entries, the module constants, and
fixed points of the Feistel, the codec, the grid and the end-to-end
composition, band seams and rejection path included. `make test-extraction`,
~3 minutes, wired into `make test` and CI beside the determinism diff. The
differential tool now also asserts the proved theorems at runtime over its
whole corpus -- containment, round-trip, decode-of-encode, stated exactly as
proved -- in the composed binary with the real HMAC round function.

**Rationale:** differential testing with F* as the oracle, not verification,
and the docs say so in those words. The concrete round function is trivial on
purpose -- the theorems hold for ANY inhabitant of the type -- and it is
spelled twice, once in F* and once over Prims' own operators; the spellings
drifting apart fails the check, which is the right direction. Three dead ends
shaped the final form, all found by measurement. F*'s NBE evaluator executes
proof terms, and ulib's arithmetic lemmas recurse on argument magnitude, so
one grid point was an out-of-memory rather than an answer; the default
call-by-name normalizer skips the unused lemma bindings and walks the same
point in about a minute. The band table hides behind an interface so SMT
never swallows its literals, which also makes it opaque to the normalizer;
`friend` sees through it while every chunk keeps `opaque_to_smt`. And the
normalizer retains what it evaluates for the lifetime of one module's check,
so the legs OOM together while each passes alone -- one module per leg, one
process per module.

Falsified seven ways before being kept: a band-table digit off by one, the
two round-function spellings drifting, a Feistel with two rounds shaved off
(still a bijection -- generation survives, only value comparison sees it),
the codec's middle words swapped in both directions at once, every grid cell
shifted by one, a hand-edited expected file with no regeneration, and an
inverse-breaking tamper caught by the generator's own sanity check. The
runtime-law leg was itself falsified (grid tamper: 25,593 violations on a
12,798-point corpus) -- after first shipping a version that could not
compile, hidden by a silenced build, and then one that restated
theorem_containment more strongly than it is proved: the theorem folds
longitude and excludes exactly +90°, and asserting one comparison more than
the proof claims flagged half the corpus of a correct binary.

An adversarial review then found the checker's own soundness hole: every
walker was vacuously true on an empty expected list, so a generator
regression emitting `[]` for a leg would have verified green forever --
the exact "theorem that asserts nothing" this project's rules name, and my
seven falsifications were all value mutations, so the vacuity class went
untested. The counts are now pinned in the hand-written harness and both
emptied-leg falsifications fail. The review also caught the headline claim
overstating independence ("sharing nothing past the parser" -- false: both
sides share F*'s elaborator and do arithmetic through the same zarith; only
the js/ oracle escapes that substrate), the runtime-law leg described as
differential when it is self-consistency against proved laws, law
preconditions spelled from local literals rather than the extracted Spec,
no success line for the law leg to prove it still runs, a hand-listed check
module list a fifth module could silently miss, and no end-to-end point at
the exact bottom of the domain. All fixed; a seventh e2e point now sits at
lat_min in band 0.

**Follow-on:** the evaluator leg checks the test round function, not the real
HMAC injection, and seven grid points is a floor -- both recorded in the
roadmap item, which stays open for the structural fix (Low* → C).

## 2026-08-19: the Low* spike — the Feistel as proved-equal C

The migration route is decided (roadmap item 3) and its riskiest step is
demonstrated end to end. fstar/low/ holds the Feistel re-expressed over
64-bit machine integers with a machine-checked proof of bit-for-bit
agreement with the spec, plus the bijection theorems transferred by one
appeal each to the originals. The agreement theorem covers the Feistel
stage, for any round function -- address stability through the migration
becomes a theorem stage by stage as the grid, table and codec ports land,
and is a theorem for none of them until then. KaRaMeL (which ships in the
F* toolchain) emits C that reads like the spec; make test-lowstar compiles
it and replays the same Feistel vectors the extracted OCaml generated and
the evaluator leg re-derives, making the C the THIRD implementation to
answer for those numbers (js/ answers for the real-HMAC vectors, never
these) and the second leg sharing neither zarith nor ocamlopt with what it
checks -- though --codegen krml does share the extraction pipeline's
erasure and ML translation with the OCaml, so that class stays on the
evaluator leg's watch. CI diffs the committed vectors header exactly as it
diffs Expected.fst. BOUNDS.md surveys the whole core: everything fits unsigned
64-bit, no 128-bit arithmetic anywhere — the HMAC reduction decomposes into
U64 via per-modulus constants, and the one tight spot (grid midpoint,
9.61e18, a 1.92x margin) merely has to stay unsigned.

Falsified four ways: formula drift in the F* port fails VERIFICATION before
C exists (the refinement is the alarm); a tampered C constant, swapped
modulus constants, and a tampered vectors header (against correct C) each
fail the harness.

An adversarial review then found three majors, all fixed: the leg's
independence was overclaimed ("nothing after the front end") -- --codegen
krml shares the extraction pipeline's erasure and ML translation with the
OCaml it checks, diverging only at the final emitter, so that failure class
stays on the evaluator leg's watch; krml's exit code, the sole carrier of
its fatal-warning gate, was swallowed by a `| tail -1` pipe in the Makefile
recipe -- a failing krml did not fail make (now logged and gated, falsified
with a stub krml that exits 1); and this ledger itself inflated the wall
("fourth implementation" -- js/ never computes these vectors; "address
stability is now a theorem" -- only the Feistel stage is, so far). Minors,
also fixed: BOUNDS.md's edge side condition said i < k where cell_bounds
reaches i = k; the README absolutized js/'s independence ("no tooling at
all" -- it consumes the same generated bands.json and wordlist as the
core); test-lowstar side-effected the committed Expected.fst and could race
test-extraction under make -j (gen_check grew a "-" mode; the root wall is
.NOTPARALLEL); the harness gained a _Static_assert(FE_COUNT > 0) floor; and
the emitted C's recursion shape and erased refinements are recorded in
BOUNDS.md rather than assumed. Toolchain dead ends recorded in BOUNDS.md: ulib's own
admits trip --report_assumes error unless codegen is narrowed to our
namespace; a value-dependent type abbreviation as a declared type makes
KaRaMeL silently drop the definition (explicit binders extract cleanly);
the ghost-erased round-function index is the pattern the HACL* HMAC phase
reuses.


## 2026-08-19: the Low* grid -- all three grid maps as proved-equal C

Phase two of the migration, same day as the spike. fstar/low/ now holds
the grid: point_to_cell, cell_to_point and cell_bounds over 64-bit machine
integers, each with the ensures equating it to Tessarium.Grid on the
same inputs, plus the transferred round-trip theorem. The two
representation choices both serve the C boundary: coordinates travel as
unsigned offsets from the domain corner (F*'s signed machine integers
carry library admits the zero-admit flag rejects), and the 4,097-entry
band table travels as a function parameter whose result refinement pins
it to T.cum -- the round-function pattern -- so every theorem holds for
any conforming lookup. The unproved plumbing on this path -- the C
lookup and harness lines, gen_check's emission including the
signed-to-offset shift, krml and cc -- is enumerated in BOUNDS.md with
what watches each; the table VALUE is pinned by Check.Table via
Expected.fst's serialization, and cum_table's own bytes by gen_check's
write-then-reparse of every literal plus CI's byte diff. gen_check emits
the table into check_vectors.h beside 13 grid vectors (the seven e2e
points -- both seam neighbours and the pole among them -- plus the +180
meridian, the one input that takes the longitude fold branch, plus five
generated) checked through all three maps, and the harness sweeps the
whole table's shape with both ends pinned to hand-written literals. The tightest number in the
core -- the (2c+1)*lon_span midpoint product at 9.61e18, unsigned-only --
is now a discharged refinement rather than a survey line. The Makefile
derives the Low module list from the directory rather than a hand list,
the same discipline check-extraction uses.

Falsified four ways at first: a bucketing-formula drift in the F* port
fails verification before any C exists; a bumped table entry within the
read set fails the harness when compiled directly (make regenerates the
header first, so the standing guard for arbitrary bytes is CI's diff, not
the harness); a tampered rows_per_band constant in the emitted C fails
the harness; an emptied grid vector table refuses to COMPILE
(_Static_assert count pins in the hand-written harness -- the vacuity
lesson from the extraction-check review, applied in advance this time).

An adversarial review of the grid port confirmed every proof clean (it
re-verified the module from scratch and reimplemented the spec grid
independently to recheck all vector rows) and found the majors in the
checking fabric instead, all fixed: the "one unproved seam" claim hid
that cum_table's C bytes had NO reader -- Check.Table pins Expected.fst's
copy of the table, a different serialization, and the vectors read 92 of
4097 entries -- so gen_check now re-parses every literal it writes (4,278
of them) and compares against memory, and the harness sweeps the whole
table's shape with both ends hand-pinned; the ledger's "a single bumped
entry fails the harness" was true for ~2% of entries and now says what
actually guards the rest; and the longitude FOLD branch was dead in every
vector -- the antimeridian e2e point is -180, already folded -- so a +180
vector now exercises it. Falsified again after the fixes: a sabotaged
emitter misprinting entry 3000 is caught by the self-check at literal
3064; a flattened table step off the vector path is caught by the shape
sweep; a DELETED fold branch in the emitted C is caught by the +180
vector. One honest limit surfaced by falsification itself: perturbing the
fold's output by one nanodegree is invisible to all three maps -- the
maps are constant on that sliver -- so the vector pins the branch's
presence, not its exact intermediate. Medium and minor fixes: the FFI
shim spoken of in present tense before it exists, GRID_COUNT and FE_COUNT
now pinned exactly (not just nonzero), the evaluator leg's grid coverage
stated precisely (seven e2e points forward+centre; generated points and
bounds rows rest on OCaml-vs-C), stale Feistel-only comments, and the
spike's emission-shape obligation closed in writing (band_search: C
recursion, depth <= 12, measured).


## 2026-08-20: the Low* codec and composition -- the pure math fully ported

Phase three: Tessarium.Low.Codec (mixed-radix, U64-trivial, bijection
theorems transferred) and Tessarium.Low.Api -- the composition of all
three ported stages, generic over the round function exactly as the spec
Api is, with decode's partiality crossing the C boundary as a flag word
and theorem_end_to_end_low restating the user-facing guarantee on machine
types: encode a point, decode the answer, land in the same cell, for any
round function and any conforming table lookup. The harness now replays
the codec vectors (10), every e2e point through BOTH directions (7, key 7
tweak 9 hardcoded in three places that must keep agreeing), and both
rejected addresses; 4,392 literals self-verified on write. Agreement with
the harness round function is proved at the Api level
(theorem_check_encode/decode) through the same loop-agreement lemmas the
Feistel leg uses.

Falsified three ways: swapped word digits in the F* codec fail
verification; a flipped e2e word index fails the harness; a decode whose
rejection threshold is raised past the address space -- so it never says
None -- is caught by the two rejected-address vectors. One tooling lesson
recorded: a lone backslash at line end inside a Python heredoc writing F*
source is a silent line-continuation that mangles /\ conjunctions --
caught twice by the verifier, worth remembering once.

The codec review found no majors -- the first branch through clean -- and
three minors, all fixed rather than reworded: decode's rejected arm
promised "(and zeros)" that neither proof nor harness pinned (the
reviewer demonstrated a rejection returning garbage coordinates passing
everything; the ensures now pins the zeros, the harness checks them, and
the reviewer's exact tamper now fails); "the pure math fully ported"
silently skipped Api.bounds_of_point, the grid-overlay query -- now
ported (one composition, one appeal) with a harness leg replaying it on
all 13 grid vectors; and the stale-comment class the previous review
flagged had regrown in three places. The reviewer independently
fresh-verified all five Low modules, reproduced every falsification, and
confirmed both generated files byte-identical through the refactor.


## 2026-08-20: the world overview returns, and the map says when it is working

Two field reports from flying London-to-Georgia on a Georgia-only archive.
First: the world overview (planet at country level, ~45 MB, zoom 6,
merging under later downloads by design) was only ever OFFERED on a
completely empty map -- anyone who started with a region never saw it and
could never get it, so every flight crossed blank ocean. The download
card now asks the estimate whether the overview is still missing (its
incremental cost is ~zero once merged) and keeps offering it until it
is not, with wording that says why it helps. Second: nothing on screen
said the map was still working while detail streamed in. A 3-pixel
indeterminate bar now crosses the top of the map -- driven by MapLibre's
dataloading/idle events through a pure tracker (ui/src/core/loading.ts)
that holds it back through sub-300ms bursts so pans do not flicker it;
indeterminate on purpose, since MapLibre reports no stable done-vs-total
and a percentage would be theatre. Reduced-motion gets a static bar;
the bar names itself to screen readers.

Tests: 8 tracker checks under fake clocks (the load-bearing one: a burst
that settles early must NEVER flash); e2e raises the bar on real traffic
by delaying every tile through a route while a style swap refetches them,
then requires it gone at idle; a second e2e page on the archive-holding
server intercepts the world estimate and requires the offer BACK -- the
exact case the old rule got wrong. Two new message keys in all six
catalogues.

The map-loading review found two highs, both fixed in the app rather than
the test: reopening the download card served a STALE cached world estimate
synchronously (React Query serves invalidated data while refetching), so
the offer could flash for a world already on disk -- terminal job states
now DROP inactive estimate caches so a remounting card starts at pending;
and the tile-delay route in the e2e crashed the suite when MapLibre
aborted a request mid-delay -- tolerant continue. Honesty items: the bar
also shows during a longer flyTo while the camera settles (idle waits for
rest), which matches the user's ask -- "rendering but not done" -- and the
comments now say so instead of overclaiming "only when arrival lags"; the
world estimate no longer fires while a job runs; the view-before-world
order is asserted as DOM order, not existence; es-US now speaks tu like
the rest of its catalogue. One testing lesson earned the hard way: the
first bar test hung its trigger on a download's style swap and went
pass-fail-fail-pass across identical runs -- a coin-flip test asserts
nothing. It now drives the reload itself (setTiles under a delayed route),
proved right first in an isolated instrumented page, then twice green
back to back in the full suite.
