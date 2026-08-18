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
  "panel_find_placeholder",
  "panel_prefix_example",
];

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
  }
}

/* French demands a no-break space before a high punctuation mark, and the two
   French locales spell that space differently -- fr-FR narrow (U+202F), fr-CA
   full (U+00A0). Which one is a house style, not a rule, so this asserts
   CONSISTENCY inside each file rather than a particular character: one
   translation reaching for the other locale's space is invisible on screen,
   survives every other check here, and is exactly the mistake that gets made
   when a key is added to six files at once. */
for (const file of files.filter((f) => f.startsWith("fr-"))) {
  const messages = load(file);
  const spaces = new Map();
  for (const [key, value] of Object.entries(messages)) {
    if (typeof value !== "string") continue;
    for (let i = 0; i < value.length; i++) {
      if (!"  ".includes(value[i])) continue;
      if (!":;?!".includes(value[i + 1] ?? "")) continue;
      const name = value[i] === " " ? "U+00A0" : "U+202F";
      spaces.set(name, [...(spaces.get(name) ?? []), key]);
    }
  }
  const kinds = [...spaces.keys()];
  const odd = kinds.length < 2
    ? []
    : (spaces.get(kinds[0]).length < spaces.get(kinds[1]).length
      ? spaces.get(kinds[0])
      : spaces.get(kinds[1]));
  check(
    `${file} spells its no-break space one way before punctuation (stray: ${
      odd.join(", ") || "none"
    })`,
    kinds.length <= 1,
  );
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
}

console.log(`\nmessage catalogues: ${checks} checks, ${failures} failures`);
process.exit(failures ? 1 : 0);
