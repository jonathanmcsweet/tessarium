/* Message catalogue checks.

   Paraglide makes a missing *key* a compile error, which is most of the
   problem. What it cannot see is a catalogue that has drifted: a locale short
   a message, a translator who dropped a placeholder, or an example address
   that got translated along with the prose around it.

   That last one matters more than it looks. The wordlist is English BIP-39 in
   every language, so `dream.tourist.creek.2703` is not a phrase to localise --
   it is a literal that has to survive translation intact, and a well-meaning
   translation of it would show every French reader an address that cannot be
   typed in. */

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dir = join(root, "messages");
const base = "en-US.json";

/* Literals, not prose: these carry BIP-39 words and a four-digit number, and
   mean the same thing in every language. */
const NOT_TRANSLATABLE = [
  "app_name",
  "gate_phrase_placeholder",
  "search_prefix_example",
];

/* The same protection for a message that is prose AROUND a literal, where
   equality across locales is the wrong test. The address example moved into
   the search placeholder when the panel's lookup form was retired, and its
   old key left this list -- so the literal was translatable again, silently,
   which is the exact failure the list above exists to prevent. A translated
   example would show a French reader an address that cannot be typed in. */
const MUST_CONTAIN = {
  search_placeholder: "dream.tourist.creek.2703",
};

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

const load = (f) => JSON.parse(readFileSync(join(dir, f), "utf8"));
const keysOf = (o) => Object.keys(o).filter((k) => !k.startsWith("$"));
const placeholders = (s) =>
  [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();

const files = readdirSync(dir).filter((f) => f.endsWith(".json")).sort();
const reference = load(base);
const referenceKeys = keysOf(reference);

check(`${files.length} locales present`, files.length >= 2);

for (const file of files) {
  const messages = load(file);
  const keys = keysOf(messages);

  const missing = referenceKeys.filter((k) => !keys.includes(k));
  const extra = keys.filter((k) => !referenceKeys.includes(k));
  check(
    `${file} has every message (missing: ${missing.join(", ") || "none"})`,
    missing.length === 0,
  );
  check(
    `${file} has no messages the base locale lacks (${
      extra.join(", ") || "none"
    })`,
    extra.length === 0,
  );

  for (const key of keys) {
    const value = messages[key];
    check(
      `${file}:${key} is a non-empty string`,
      typeof value === "string" && value.trim() !== "",
    );

    if (!referenceKeys.includes(key)) continue;

    /* A dropped placeholder renders as prose with a hole in it, and nothing
       else in the build notices. */
    const want = placeholders(reference[key]);
    const got = placeholders(value);
    check(
      `${file}:${key} keeps its placeholders (want ${
        want.join(",") || "none"
      }, got ${got.join(",") || "none"})`,
      JSON.stringify(want) === JSON.stringify(got),
    );

    if (NOT_TRANSLATABLE.includes(key)) {
      check(
        `${file}:${key} is left untranslated (it is a literal)`,
        value === reference[key],
      );
    }
    if (key in MUST_CONTAIN) {
      check(
        `${file}:${key} still carries the untranslatable ${MUST_CONTAIN[key]}`,
        typeof value === "string" && value.includes(MUST_CONTAIN[key]),
      );
    }
  }
}

/* Both lists must name keys that exist, or an entry retired with its message
   stops protecting anything and nothing says so. That happened: the address
   example's key was renamed and its guard was left pointing at the old
   name. */
for (const key of [...NOT_TRANSLATABLE, ...Object.keys(MUST_CONTAIN)]) {
  check(`the guard for ${key} names a message that exists`, key in reference);
}

/* French puts a no-break space before a high punctuation mark, and there are
   two of them: narrow (U+202F) and full (U+00A0). Which one belongs where is
   a real typographic rule, not a preference, but it differs by mark -- so
   asserting one spelling per FILE would reject a correctly typeset catalogue.
   What must hold is that a given mark is spaced the same way everywhere in a
   locale: a single message reaching for the other space is invisible on
   screen, survives every other check here, and is exactly the slip made when
   a key is added to six files at once.

   Silence about a mark with no space at all is deliberate. Canadian usage
   drops it before ; ! ? and both catalogues rely on that. */
for (const file of files.filter((f) => f.startsWith("fr-"))) {
  const messages = load(file);
  const NO_BREAK = { "\u00a0": "U+00A0", "\u202f": "U+202F" };
  const byMark = new Map();
  for (const [key, value] of Object.entries(messages)) {
    if (typeof value !== "string") continue;
    for (let i = 0; i < value.length - 1; i++) {
      const name = NO_BREAK[value[i]];
      if (!name) continue;
      const mark = value[i + 1];
      if (!":;?!".includes(mark)) continue;
      const seen = byMark.get(mark) ?? new Map();
      seen.set(name, [...(seen.get(name) ?? []), key]);
      byMark.set(mark, seen);
    }
  }
  for (const [mark, seen] of byMark) {
    const spellings = [...seen.entries()]
      .map(([name, keys]) => `${name} in ${keys.join(", ")}`);
    check(
      `${file} spaces "${mark}" the same way throughout (${
        spellings.join("; ")
      })`,
      seen.size <= 1,
    );
  }
}

/* And the catalogue has to have reached the compiler.

   Paraglide treats a plugin it cannot import as a WARNING and then reports
   success, having compiled nothing. The path to the message-format plugin is
   resolved from the working directory, so it is exactly the kind of thing that
   breaks quietly when something else moves. Checking the compiled output
   against the catalogue turns that back into a failure. */
const compiled = join(root, "src", "paraglide", "messages", "_index.js");
if (!existsSync(compiled)) {
  check("compiled messages exist (run: npm run paraglide)", false);
} else {
  const index = readFileSync(compiled, "utf8");
  const absent = referenceKeys.filter((k) => !index.includes(k));
  check(
    `every message reached the compiler (absent: ${
      absent.slice(0, 5).join(", ") || "none"
    })`,
    absent.length === 0,
  );

  /* Keys reaching the compiler is not the same as TEXT reaching it. The
     compiled output is a gitignored artifact, and until `npm run build`
     was made to compile it, editing a catalogue and building shipped the
     previous wording -- silently, because every key was still present.
     Compare the words themselves for the reference locale. Messages with
     placeholders are skipped: those compile to template expressions rather
     than a literal, and the placeholder checks above already cover them. */
  const stale = [];
  for (const key of referenceKeys) {
    const value = reference[key];
    if (typeof value !== "string" || value.includes("{")) continue;
    const file = join(root, "src", "paraglide", "messages", `${key}.js`);
    if (!existsSync(file)) {
      stale.push(key);
      continue;
    }
    /* The compiler escapes backticks and ${; nothing else in this catalogue
       needs unescaping to be found verbatim. */
    if (!readFileSync(file, "utf8").includes(value)) stale.push(key);
  }
  check(
    `compiled text matches the catalogue (stale: ${
      stale.slice(0, 5).join(", ") || "none"
    })`,
    stale.length === 0,
  );
}

/* ------------------------- refusal codes have entries ---------------------

   A refusal names itself with a stable code and src/core/refusal.ts turns the
   code into a sentence. Nothing in the type system connects the two: the
   codes are string literals in a worker that no bundler reads and in OCaml
   that compiles to a separate artifact, so a new one with no entry falls
   through to the core's English and nobody notices, in English.

   Textual, deliberately. The alternative is importing refusal.ts, which is
   TypeScript this script cannot load, and the codes are literals in both
   producers -- if one ever becomes a computed string this check goes quiet,
   which is why it also asserts it found a plausible number of them. */
{
  const said = readFileSync(join(root, "src", "core", "refusal.ts"), "utf8");
  /* The keys of the `said` map: two-space indented identifiers before a
     colon, inside the object literal. */
  const body = said.slice(said.indexOf("const said"), said.indexOf("};"));
  const known = new Set(
    [...body.matchAll(/^ {2}([a-z_]+):/gm)].map((mm) => mm[1]),
  );

  const worker = readFileSync(
    join(root, "public", "core.worker.js"),
    "utf8",
  );
  const produced = new Set([
    ...[...worker.matchAll(/new Refused\(\s*"([a-z_]+)"/g)].map((mm) => mm[1]),
    ...[...worker.matchAll(/code:\s*"([a-z_]+)"/g)].map((mm) => mm[1]),
  ]);
  /* The core's own refusals -- a mistyped word, a bad address -- are raised
     in OCaml and carry their codes from there. */
  const lib = readFileSync(
    join(root, "..", "ocaml", "lib", "tessarium.ml"),
    "utf8",
  );
  for (const mm of lib.matchAll(/code = "([a-z_]+)"/g)) produced.add(mm[1]);

  check(
    `found refusal codes to check (${produced.size})`,
    produced.size >= 10,
  );
  const orphans = [...produced].filter((c) => !known.has(c));
  check(
    `every refusal code has a message (missing: ${
      orphans.join(", ") || "none"
    })`,
    orphans.length === 0,
  );
  /* The other direction is a smaller problem -- an entry nobody throws is
     dead text, not a user seeing English -- but it is just as cheap to see. */
  const unused = [...known].filter((c) => !produced.has(c));
  check(
    `and every message has a refusal (unused: ${unused.join(", ") || "none"})`,
    unused.length === 0,
  );
}

console.log(`\nmessage catalogues: ${checks} checks, ${failures} failures`);
process.exit(failures ? 1 : 0);
