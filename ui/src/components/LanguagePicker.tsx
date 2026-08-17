/* Language menu.

   A native <select>, deliberately. It is keyboard-operable, screen-reader
   announced and touch-friendly on every platform without a line of behaviour
   code, and a custom listbox would be a worse version of it. The rule about
   taking accessible primitives from a library rather than hand-rolling applies
   with more force to the primitives the platform already ships.

   The choice lasts for the session only -- see src/i18n.ts. */

import { Languages } from "lucide-react";
import { useId } from "react";
import { type Locale, localeNames, locales } from "../i18n";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";

export function LanguagePicker({ className }: { className?: string; }) {
  const id = useId();
  const locale = useAppStore((s) => s.locale);
  const setLocale = useAppStore((s) => s.setLocale);

  return (
    <div className={className ? `language ${className}` : "language"}>
      <Languages size={16} aria-hidden />
      <label className="sr-only" htmlFor={id}>
        {m.a11y_language()}
      </label>
      <select
        id={id}
        value={locale}
        onChange={(e) => setLocale(e.target.value as Locale)}
      >
        {locales.map((l) => (
          <option key={l} value={l}>
            {localeNames[l]}
          </option>
        ))}
      </select>
    </div>
  );
}
