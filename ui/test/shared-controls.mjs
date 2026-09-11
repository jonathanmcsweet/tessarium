/* A control offered in two places is one component.

   The theme is settable from the panel's settings popover and from the foot
   of the gate; the language, from the foot of the panel and the foot of the
   gate. Each of those pairs is one component rendered twice. Built twice
   instead, they drift one edit at a time -- an option renamed in one list,
   an icon added to one, a new theme appended to one -- and nothing fails,
   because both halves keep working. The screen just stops agreeing with
   itself.

   Read as text, like icons.mjs: this is a rule about how the source is
   arranged, and a running app cannot be asked whether the two dropdowns it
   drew came from one function. */

import { sourceFiles } from "./source.mjs";

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

const files = sourceFiles(new URL("../src/", import.meta.url));
check("there is source to read", files.length > 0);

const named = (path) => files.find((f) => f.path === path)?.text ?? "";
const holding = (pattern) =>
  files.filter((f) => pattern.test(f.text)).map((f) => f.path).sort();

/* The store's setters. One writer each: a second component calling setTheme
   is a second theme control, whatever it looks like. */
for (
  const [what, setter, home] of [
    ["theme", "setTheme", "components/ThemePicker.tsx"],
    ["locale", "setLocale", "components/LanguagePicker.tsx"],
  ]
) {
  const writers = holding(new RegExp(`\\bs\\.${setter}\\b`))
    .filter((p) => p !== "store.ts");
  check(
    `the ${what} is written from exactly one component (${
      writers.join(", ") || "none"
    })`,
    writers.length === 1 && writers[0] === home,
  );
}

/* And the option lists. The theme names are the case that bit: two spellings
   of "Cyberpunk dark", or a sixth theme added to the popover's list and not
   to the gate's. */
const themeNames = holding(/theme_cyber_dark/);
check(
  `the theme option names are written down once (${
    themeNames.join(", ") || "none"
  })`,
  themeNames.length === 1 && themeNames[0] === "components/ThemePicker.tsx",
);
const localeNames = holding(/\blocaleNames\b/).filter((p) => p !== "i18n.ts");
check(
  `the locale names are written down once (${
    localeNames.join(", ") || "none"
  })`,
  localeNames.length === 1
    && localeNames[0] === "components/LanguagePicker.tsx",
);

/* Both placements render the component rather than a dropdown of their own.
   Without this the checks above pass on a component nobody uses. */
const rendersThemePicker = holding(/<ThemePicker\b/);
check(
  `both placements render the theme picker (${rendersThemePicker.join(", ")})`,
  rendersThemePicker.length === 2
    && rendersThemePicker.includes("components/PhraseEntry.tsx")
    && rendersThemePicker.includes("components/AddressPanel.tsx"),
);
const rendersLanguagePicker = holding(/<LanguagePicker\b/);
check(
  `both placements render the language picker (${
    rendersLanguagePicker.join(", ")
  })`,
  rendersLanguagePicker.length === 2
    && rendersLanguagePicker.includes("components/PhraseEntry.tsx"),
);

/* The one thing the two theme placements are allowed to differ by, so a
   third difference has to be added here on purpose rather than by accident.
   `labelHidden` is the Dropdown's own prop, and both placements now pass it:
   each reads as a row beside the language. */
const picker = named("components/ThemePicker.tsx");
const props = [...picker.matchAll(/\{\s*([^{}]*?)\}:\s*\{/g)]
  .map((m) => m[1]).join(" ");
check(
  `the theme picker takes only placement props (${props.trim() || "none"})`,
  /className/.test(props) && /labelHidden/.test(props)
    && !/theme|onChange|options/.test(props),
);

/* The tooltip. Two controls wear one -- the icon buttons and the info icon
   beside a heading -- and both get it from Tip. A second file reaching for
   TooltipTrigger is a second tooltip: its own delay, its own dismiss, its own
   arrow drawn at its own angle. This is the duplication the info icon nearly
   introduced, because copying the overlay was the shorter diff. */
const tooltips = holding(/<TooltipTrigger\b/);
check(
  `the tooltip is drawn by exactly one component (${
    tooltips.join(", ") || "none"
  })`,
  tooltips.length === 1 && tooltips[0] === "components/Tip.tsx",
);
const wearsTip = holding(/<Tip\b/).filter((p) => p !== "components/Tip.tsx");
check(
  `and the controls that wear one render it (${wearsTip.join(", ") || "none"})`,
  wearsTip.length === 1 && wearsTip[0] === "components/IconButton.tsx",
);

/* Unavailable is `aria-disabled`, not the `disabled` attribute. A disabled
   button receives no hover and takes no focus, so the one control that
   cannot be pressed was also the only one that could not say what it was.
   Read as text, because a running app cannot be asked which mechanism drew a
   state it is not currently in. */
const iconButton = named("components/IconButton.tsx");
check(
  "the icon button marks unavailable with aria-disabled",
  /"aria-disabled": true/.test(iconButton) && !/isDisabled=/.test(iconButton),
);

/* And the tooltip is made of the application's own floating surface, the one
   the dropdown's list is made of. It was the inverted pair, `bg-ink` on
   `text-on-ink`, which in the four dark palettes is a pale box with black
   text: a system tooltip sitting on top of the theme rather than in it. */
const tip = named("components/Tip.tsx");
/* The attribute, not the file: the comment above it names the pair it stopped
   using, and a rule that reads prose fails on its own explanation. */
const tipSurface = /<Tooltip\s+className="([^"]*)"/.exec(tip)?.[1] ?? "";
check(
  `the tooltip is built from the shared floating surface (${
    tipSurface || "no className"
  })`,
  /\bsheet\b/.test(tipSurface) && !/bg-ink|text-on-ink/.test(tipSurface),
);

console.log(`\nshared controls: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
