/* Locale handling, over Paraglide.

   Messages themselves come from `src/paraglide/messages.js`, which the build
   compiles from `messages/*.json`. They are ordinary typed functions, so a
   message that does not exist is a compile error rather than a key printed on
   screen, and messages nothing references are tree-shaken out.

   Paraglide is configured (in vite.config.ts) with the `globalVariable`
   strategy ahead of `preferredLanguage`: the language is read from the
   browser, and the menu overrides it in memory for the session. Deliberately
   not a cookie and not localStorage -- this application persists nothing, and
   the end-to-end test asserts exactly that. Choosing French therefore lasts
   until the tab is closed, which is the honest consequence of the guarantee
   rather than an oversight. */

import {
  getLocale,
  locales,
  setLocale as setParaglideLocale,
} from "./paraglide/runtime";

export type Locale = (typeof locales)[number];

/* Endonyms: a language menu is the one place a reader may not be able to read
   the current language, so each is named in itself. */
export const localeNames: Record<Locale, string> = {
  "en-US": "English (US)",
  "en-GB": "English (UK)",
  "en-CA": "English (Canada)",
  "fr-FR": "Français (France)",
  "fr-CA": "Français (Canada)",
  "es-US": "Español (EE. UU.)",
};

export { getLocale, locales };

/* `reload: false` because reloading would drop the derived key and send the
   user back to the phrase gate. React re-renders instead, driven by the store,
   and the message functions read the new locale on the next call. */
export function applyLocale(locale: Locale): void {
  setParaglideLocale(locale, { reload: false });
  document.documentElement.lang = locale;
}

/* Coordinates are numbers and are formatted for the reader's locale -- French
   readers expect a decimal comma. Addresses are never formatted: three words
   and four digits mean the same thing everywhere, and a separator inserted
   into one would be a bug rather than a courtesy. */
export const formatCoord = (value: number): string =>
  new Intl.NumberFormat(getLocale(), {
    minimumFractionDigits: 7,
    maximumFractionDigits: 7,
  }).format(value);
