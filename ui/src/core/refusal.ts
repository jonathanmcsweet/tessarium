/* A refusal, said in the user's language.

   The worker cannot do this itself: it is plain JavaScript in public/ that no
   bundler touches, it has no access to the compiled message catalogue, and it
   runs before a locale has been settled. So it names the failure with a
   stable code and this is where the naming becomes a sentence.

   Two kinds arrive here and they are not treated alike. A REFUSAL is
   something the user did -- a mistyped word, a locked key, an address that
   names nothing -- and has an entry below. A FAULT is the core, the wasm
   modules or the glue being broken; those all arrive as `core_failed` with
   the English detail as their argument, and the catalogue entry says plainly
   that it is our defect, because a user cannot act on "the band table failed
   the core's shape check" and should not be left thinking they might.

   Codes with no entry fall back to the core's English. That is a worse
   outcome than a translation and a much better one than an empty toast, and
   ui/test/messages.mjs asserts that every code the worker or the core can
   produce is listed here -- and that nothing here is dead -- so the fallback
   stays a safety net rather than the normal path. */

import { m } from "../paraglide/messages";
import { CoreError, type Refusal } from "./client";

/* The argument is passed positionally from the worker and named here,
   because the name belongs to the sentence and the sentence differs per
   language -- a French entry may want the word somewhere English does not. */
const said: Record<string, (arg: string) => string> = {
  locked: () => m.err_locked(),
  point_out_of_range: () => m.err_point_out_of_range(),
  address_no_location: () => m.err_address_no_location(),
  insecure_context: () => m.err_insecure_context(),
  core_failed: (detail) => m.err_core_failed({ detail }),
  mnemonic_word_count: (count) => m.err_mnemonic_word_count({ count }),
  mnemonic_not_a_word: (word) => m.err_mnemonic_not_a_word({ word }),
  mnemonic_checksum: () => m.err_mnemonic_checksum(),
  passphrase_too_long: (bytes) => m.err_passphrase_too_long({ bytes }),
  address_not_four_digits: (text) => m.err_address_not_four_digits({ text }),
  address_not_a_word: (word) => m.err_address_not_a_word({ word }),
  address_part_count: (count) => m.err_address_part_count({ count }),
};

/* A `{ok: false, error}` result -- validate and unlock, where not-valid is
   the answer rather than an exception. */
export const sayRefusal = (refusal: Refusal): string =>
  said[refusal.code]?.(refusal.arg) ?? refusal.message;

/* A rejected promise, from anywhere. Anything that is not a CoreError with a
   code is shown as it arrived: a network failure or a bug in a component is
   not a refusal and dressing it as one would be a lie about whose fault it
   is. */
export const sayError = (e: unknown): string => {
  if (e instanceof CoreError && e.code !== null) {
    return said[e.code]?.(e.arg) ?? e.message;
  }
  return e instanceof Error ? e.message : String(e);
};
