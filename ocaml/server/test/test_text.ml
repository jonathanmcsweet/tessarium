(* The seven call sites this module replaced each computed [String.sub]
   lengths by hand, so the cases worth pinning are the boundaries those
   computations get wrong: a separator first, last, absent, or repeated. *)

module Text = Tessarium_server.Text

let checks = ref 0
let failures = ref 0

let check name ok =
  incr checks;
  if not ok then begin
    incr failures;
    Printf.printf "  FAIL  %s\n" name
  end

let () =
  check "cut splits at the separator, keeping neither half's copy of it"
    (Text.cut '=' "path=etc" = Some ("path", "etc"));
  check "a missing separator is None, not an empty half"
    (Text.cut '=' "path" = None);
  check "a leading separator gives an empty left half"
    (Text.cut '=' "=etc" = Some ("", "etc"));
  check "a trailing separator gives an empty right half"
    (Text.cut '=' "path=" = Some ("path", ""));
  check "the empty string holds no separator" (Text.cut '=' "" = None);
  check "cut takes the FIRST separator, so the right half keeps the rest"
    (Text.cut '=' "a=b=c" = Some ("a", "b=c"));
  check "rcut takes the LAST, so the left half keeps the rest"
    (Text.rcut '=' "a=b=c" = Some ("a=b", "c"));
  check "rcut agrees with cut when there is only one"
    (Text.rcut '.' "index.js" = Some ("index", "js"));
  check "rcut on a separator-free string is None"
    (Text.rcut '.' "index" = None);

  check "before is the left half when there is a separator"
    (Text.before ';' "application/json; charset=utf-8" = "application/json");
  check "and the whole string when there is not"
    (Text.before ';' "application/json" = "application/json");
  check "before an empty string is empty" (Text.before ';' "" = "");
  check "a NUL-padded field stops at the NUL"
    (Text.before '\000' "name\000\000\000" = "name");

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1;
  print_endline "text cuts hold"
