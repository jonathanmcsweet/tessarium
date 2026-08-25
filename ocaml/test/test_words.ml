(* The shipped word lookup, against the proved one, over the real wordlist.

   `Tessarium.resolve_word` does not run the proved lookup on the common path.
   A word spelled in full goes through a hashtable, because walking 2048 byte
   lists costs 25x what a table lookup does and an address resolves three
   words; the proved `Tessarium_Words.resolve` is the fall-through. Two paths
   to one answer is exactly the shape that drifts, and the guard that is meant
   to keep them together -- one string comparison, plus the load-time
   duplicate check -- is an argument, not a test.

   So this is the test. Every word in the list, spelled in full and at every
   prefix length, through both paths, compared. That is 2048 words and a
   little over 13,000 spellings, which is the whole input space that matters:
   `resolve` can only answer about a typed string that is a prefix of some
   word, and anything else is covered by the negative cases below.

   This is the check the roadmap called the widest gap between what is proved
   and what is exercised: the theorem covers every input against every list,
   and until now the extracted code was exercised on three spellings. *)

let failures = ref 0
let checks = ref 0

let check name ok =
  incr checks;
  if not ok then begin
    incr failures;
    Printf.printf "  FAIL  %s\n" name
  end

let bytes_of_word w =
  List.init (String.length w) (fun i -> Z.of_int (Char.code w.[i]))

let word_bytes =
  lazy (List.init Tessarium.word_count Tessarium.word_at
  |> List.map bytes_of_word)

(* The proved lookup, with the fast path deliberately not in the way. *)
let proved w =
  match
    Tessarium_Words.resolve (bytes_of_word w) (Lazy.force word_bytes)
  with
  | Some i -> Some (Z.to_int i)
  | None -> None

let string_of_answer = function
  | None -> "none"
  | Some i -> string_of_int i

let () =
  check "the wordlist is the 2048 words the format is built on"
    (Tessarium.word_count = 2048);

  (* Every word, spelled in full. The hashtable answers all of these, so this
     is the path the proof does not run on. *)
  let full_disagreements = ref [] in
  for i = 0 to Tessarium.word_count - 1 do
    let w = Tessarium.word_at i in
    let shipped = Tessarium.resolve_word w in
    if shipped <> proved w || shipped <> Some i then
      full_disagreements := w :: !full_disagreements
  done;
  check
    (Printf.sprintf
       "every one of the %d words spelled in full resolves to its own index, \
        by both paths%s"
       Tessarium.word_count
       (match !full_disagreements with
       | [] -> ""
       | w :: _ -> Printf.sprintf " (first: %s)" w))
    (!full_disagreements = []);

  (* Every prefix of every word. This is where the two paths can differ
     without the wordlist being at fault: the hashtable misses, the proved
     lookup runs, and its answer is the only one. Counted rather than
     asserted one by one, so the message says how much was actually walked. *)
  let spellings = ref 0 and prefix_disagreements = ref [] in
  for i = 0 to Tessarium.word_count - 1 do
    let w = Tessarium.word_at i in
    for n = 1 to String.length w - 1 do
      let p = String.sub w 0 n in
      incr spellings;
      if Tessarium.resolve_word p <> proved p then
        prefix_disagreements := p :: !prefix_disagreements
    done
  done;
  check
    (Printf.sprintf
       "the two paths agree on all %d partial spellings%s" !spellings
       (match !prefix_disagreements with
       | [] -> ""
       | p :: _ -> Printf.sprintf " (first: %s)" p))
    (!prefix_disagreements = []);

  (* And the negative space: strings that are no word's prefix, and the
     too-short rule. Both paths must refuse, and refuse for the same reason. *)
  let negatives =
    [ ""; "q"; "zz"; "qqqq"; "abandonx"; "ABANDON"; " abandon"; "abandon " ]
  in
  List.iter
    (fun s ->
      check
        (Printf.sprintf "%S is refused by both paths (shipped %s, proved %s)" s
           (string_of_answer (Tessarium.resolve_word s))
           (string_of_answer (proved s)))
        (Tessarium.resolve_word s = None && proved s = None))
    negatives;

  (* The rule the proof exists for, named out loud, on the two spellings that
     made it. "cannot" is not a BIP-39 word and neither is "artistic"; both
     share their first four letters with one that is. The comparison that
     shipped once looked at the first four letters of the INPUT, which made
     "cannot" an abbreviation of "cannon" and "artistic" one of "artist" -- so
     a word the user never typed decoded to a square they never meant, and
     nothing said so. Both must be refused, by both paths. *)
  List.iter
    (fun (typed, resembles) ->
      check
        (Printf.sprintf
           "%S is refused rather than read as %S (shipped %s, proved %s)" typed
           resembles
           (string_of_answer (Tessarium.resolve_word typed))
           (string_of_answer (proved typed)))
        (Tessarium.resolve_word typed = None && proved typed = None))
    [ ("cannot", "cannon"); ("artistic", "artist") ];

  (* And the words they resemble still resolve to themselves. *)
  List.iter
    (fun w ->
      match Tessarium.resolve_word w with
      | Some i ->
          check
            (Printf.sprintf "%s still resolves to itself, not to a neighbour" w)
            (String.equal (Tessarium.word_at i) w)
      | None -> check (Printf.sprintf "%s is a word" w) false)
    [ "cannon"; "artist"; "carbon" ];

  (* A three-letter prefix is refused however unique it is: min_abbrev is 4,
     and "the shortest unique prefix" is not the rule. *)
  check "a unique three-letter prefix is still refused"
    (Tessarium.resolve_word "zoo" = Some 2047
    && Tessarium.resolve_word "zon" = None);

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1;
  print_endline "the shipped word lookup agrees with the proved one"
