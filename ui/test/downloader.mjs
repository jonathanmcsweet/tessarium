/* The offline-maps card, its progress panel, and the client under both.

   Every rule here is a bug that shipped and that nothing else could see: a
   button offering an operation the server no longer has, a success announced
   before the work started, a name sent beside the thing it names instead of
   inside it, a nudge pointing at verbs that are not on the row, a finished
   region drawn as one that never started, four sentences that reach a French
   user in English, and one class list pasted five times.

   None of them is a type error and none throws. They are decisions written in
   the source, so the source is what is read -- the same shape as
   night-flavor.mjs and icons.mjs. */

import { readdirSync, readFileSync } from "node:fs";

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

const read = (path) =>
  readFileSync(new URL(`../src/${path}`, import.meta.url), "utf8");

const card = read("components/DownloadCard.tsx");
const progress = read("components/MapProgress.tsx");
const client = read("core/basemap.ts");
const panel = read("components/AddressPanel.tsx");
const mapView = read("components/MapView.tsx");

/* The body of a named function declaration, to the line that closes it at
   column zero. Enough to scope a check to one component without pretending
   to parse TypeScript. */
const body = (source, name) => {
  const at = source.indexOf(`function ${name}(`);
  if (at < 0) return null;
  const end = source.indexOf("\n}\n", at);
  return source.slice(at, end < 0 ? source.length : end);
};

/* --------------------------------------------------- nothing to download */

/* A covered estimate used to turn the confirm button into "Keep track of
   this map", from when the server could RECORD an area it already held
   without fetching anything. Server-side adoption is gone: a covered area
   writes nothing and the job fails with "you already have the maps for that
   area", so every press produced a Failed job and an error toast from a
   button the card itself had offered. */
const offer = body(card, "Offer");
check("the offer is found", offer !== null);
check(
  "no adopt CTA is offered anywhere",
  !card.includes("map_download_adopt"),
);
const catalogues = new URL("../messages/", import.meta.url);
for (const file of readdirSync(catalogues).filter((f) => f.endsWith(".json"))) {
  const messages = JSON.parse(readFileSync(new URL(file, catalogues), "utf8"));
  check(
    `${file} carries no adopt message for a button that cannot exist`,
    !("map_download_adopt" in messages),
  );
}
check(
  "an estimate with nothing to write shows a state instead of a button",
  /nothingToWrite/.test(offer ?? ""),
);
/* And the button that remains is not merely disabled on the covered case:
   the whole action row goes, so there is nothing to press and nothing that
   looks pressable. */
check(
  "the action row is conditional on there being something to fetch",
  /\{!nothingToWrite && \(/.test(offer ?? ""),
);

/* ----------------------------------------------------- naming the regions */

/* Labels used to travel as a top-level array parallel to the regions -- a
   shape that can be one element short or one out of order and still be
   accepted. The "download this view" offer, which is the most common
   download there is, sent a ledger name and no array at all, so the progress
   panel read "Unnamed area" for the several minutes the user watched it
   while the ledger row said "London". */
const download = /useBasemapDownload\(\)[\s\S]*?\n\}/.exec(client)?.[0] ?? "";
check("the download mutation is found", download !== "");
check(
  "the download payload carries no parallel label array",
  !/\blabels\b/.test(download),
);
check(
  "a region carries its own label",
  /LabelledRegion/.test(client) && /label\?:\s*string/.test(client),
);
/* Every offer names its regions: the picker through its per-pick names, the
   world and the current view through the single label they have. */
const offers = [...card.matchAll(/<Offer\b[\s\S]*?\/>/g)].map((m) => m[0]);
check(`every offer is found (${offers.length})`, offers.length === 4);
offers.forEach((call, i) => {
  check(
    `offer ${i + 1} (${
      /className="([^"]*)"/.exec(call)?.[1] ?? "?"
    }) names its regions`,
    /\bnames=/.test(call) || /\bregionLabel=/.test(call),
  );
});

/* ------------------------------------------------ the import success toast */

/* The server answers the merge POST as soon as it has forked the job, and
   the merge itself runs for minutes and can fail. Announcing success there
   showed "Those maps were added" and then contradicted it with a failure
   toast about the same operation. The ending is reported from the status
   poll, which is watched from the map so a user who closed the card still
   hears it. */
const importer = body(card, "ImportFromFile");
check("the import control is found", importer !== null);
check(
  "the merge is not announced from the accepted POST",
  !/toastSuccess/.test(importer ?? ""),
);
check(
  "and the ending is reported when the job reaches it",
  /map_import_added/.test(mapView),
);

/* --------------------------------------------------- the staleness nudge */

/* "Update available" has to point at an Update button. Both verbs are gated
   on `partOfBaseMap` -- an entry with no archive of its own, which the server
   refuses the id of -- and the nudge was gated on `overview` alone. A legacy
   merged entry records completed = 0, so its age is unknown, so it is stale
   on any threshold: a permanent accent mark beside no verbs at all, with the
   global "Never" setting as the only escape, and that silences every row. */
const stale = /const stale = ([\s\S]*?);\n/.exec(card)?.[1] ?? "";
check("the staleness rule is found", stale !== "");
check(
  `the nudge is gated on the same rule as the verbs (${
    stale.split("\n")[0]?.trim()
  })`,
  /partOfBaseMap/.test(stale),
);

/* ------------------------------------------------ a region already on disk */

/* A region resumed with every tile already present accrues no fresh bytes,
   so its total is zero. Requiring `total_bytes > 0` before calling it Done
   left it reading "0 MB / 0 MB" at 0% for the life of the job -- which reads
   as a region that never started rather than one finished before it began.
   Cancel a two-country download after the first lands, then restart. */
const hint = /hint=\{([\s\S]*?)\}\n/.exec(progress)?.[1] ?? "";
check("the row hint is found", hint !== "");
check(
  "a fully-resumed region is Done rather than stuck at zero",
  /done_bytes >= r\.total_bytes/.test(hint) && !/total_bytes > 0/.test(hint),
);
check(
  "and its bar is drawn full rather than empty",
  /value=\{done >= total/.test(progress),
);

/* ------------------------------------------------------ words in six languages */

/* The four upload failures reach a toast verbatim through the card's error
   handler. They were English literals, so someone working in French who
   unplugged mid-upload got an English sentence while every other string in
   the application was translated. */
const upload = /useUploadImport\(\)[\s\S]*?\n\}/.exec(client)?.[0] ?? "";
check("the upload is found", upload !== "");
check(
  "every upload failure comes from the catalogue",
  (upload.match(/m\.err_upload_/g) ?? []).length === 4,
);
check(
  "and none is a literal English sentence",
  !/new Error\("[^"]* [^"]*"\)/.test(upload),
);

/* One fact, one source. The visible byte readout under each bar was a
   hardcoded template while the bar's own aria-label spent a message for the
   same numbers -- so the words on screen were unreachable by a translator
   and the two could drift. */
check(
  "the visible byte readout is a message, not a template",
  /m\.map_progress_bytes/.test(progress)
    && !/\}\s*\/\s*\$\{formatBytes/.test(progress),
);

/* ------------------------------------------------------- one look, one home */

/* The section label was twenty-eight characters of Tailwind pasted five
   times, and the ledger row's shell was duplicated between the two
   renderers that draw it -- so the carefully commented wrap fix on one of
   them would silently not apply to the other. */
const css = read("styles.css");
const shared = ["region-group", "ledger-row", "ledger-row-text", "ledger-name"];
for (const name of shared) {
  check(
    `.${name} is one rule in the stylesheet`,
    new RegExp(`@utility ${name} \\{`).test(css),
  );
  check(
    `.${name} is not also pasted as a class list in the card`,
    !new RegExp(`"${name} [a-z]`).test(card),
  );
}

/* ------------------------------------------------ who holds the status poll */

/* The job poll ticks once a second for the life of a download. The panel
   held it solely to pass the answer to the card, so the address, the
   coordinates and the footer re-rendered every second for the whole of an
   hour-long download, card closed or open. The card asks for itself; the map
   and the progress section keep the poll alive meanwhile. */
check(
  "the panel does not hold the poll on the card's behalf",
  !/useBasemapStatus/.test(panel),
);
check(
  "the card subscribes for itself",
  /useBasemapStatus\(\{\s*follow:\s*true\s*\}\)/.test(card),
);
/* And subscribes as a FOLLOWER, which is not a detail. The poll stops
   whenever nothing is running, so a job that started and ended without the
   map asking again leaves its ending sitting undelivered. A plain observer
   mounting fetches it right then, and the ending arrives as fresh news --
   to the watcher that closes the card on a job's ending. Opening the card
   mounted the observer, delivered the old ending, and shut the card again:
   one press, nothing on screen, nothing in the console. The end-to-end
   suite caught it as a click that did nothing. */
check(
  "as a follower, so opening it cannot re-deliver a finished job's ending",
  /refetchOnMount:\s*!follow/.test(client),
);
check(
  "and something else keeps the poll alive while the card is shut",
  /useBasemapStatus\(\)/.test(mapView) && /useBasemapStatus\(\)/.test(progress),
);

console.log(`\ndownloader: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
