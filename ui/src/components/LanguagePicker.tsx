/* Language menu.

   The choice lasts for the session only -- see src/i18n.ts. The dropdown
   itself, and the reason it is no longer a native `<select>`, is in
   components/Dropdown.tsx. */

import { Languages } from "lucide-react";
import { type Locale, localeNames, locales } from "../i18n";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { Dropdown } from "./Dropdown";

export function LanguagePicker({ className }: { className?: string; }) {
  const locale = useAppStore((s) => s.locale);
  const setLocale = useAppStore((s) => s.setLocale);

  return (
    <div className={className ? `language ${className}` : "language"}>
      <Languages size={16} aria-hidden />
      <Dropdown<Locale>
        label={m.a11y_language()}
        labelHidden
        value={locale}
        onChange={setLocale}
        options={locales.map((l) => ({ value: l, label: localeNames[l] }))}
      />
    </div>
  );
}
