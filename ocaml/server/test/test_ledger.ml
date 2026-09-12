(* What the ledger refuses to read back.

   A stored ledger was validated when it was written, so every rejection here
   is a corrupted or foreign archive rather than a user mistake -- which makes
   these the paths nothing else exercises. The Ok cases are covered by the
   region suite, which round-trips real downloads; this one is about the parse
   giving up, and about where it gives up first. *)

module Ledger = Tessarium_server.Ledger

let checks = ref 0
let failures = ref 0

let check name ok =
  incr checks;
  if not ok then begin
    incr failures;
    Printf.printf "  FAIL  %s\n" name
  end

let rejects name json =
  check name (Result.is_error (Ledger.of_json json))

let region ?(extra = []) () =
  `Assoc
    ([
       ("min_lon", `Float (-0.5));
       ("min_lat", `Float 51.3);
       ("max_lon", `Float 0.3);
       ("max_lat", `Float 51.7);
       ("max_zoom", `Int 12);
     ]
    @ extra)

let entry ?(regions = [ region () ]) ?(extra = []) () =
  `Assoc
    ([
       ("name", `String "London");
       ("completed", `Int 3);
       ("source", `String "http://example.invalid/map.pmtiles");
       ("bytes", `Int 4096);
       ("regions", `List regions);
     ]
    @ extra)

let ledger entries = `Assoc [ ("v", `Int 1); ("entries", `List entries) ]

(* Replace one field of an object, so each case below differs from a ledger
   that parses in exactly one way. *)
let with_field key value = function
  | `Assoc fields ->
      `Assoc ((key, value) :: List.remove_assoc key fields)
  | other -> other

let without key = function
  | `Assoc fields -> `Assoc (List.remove_assoc key fields)
  | other -> other

let () =
  check "a well-formed ledger reads back"
    (match Ledger.of_json (ledger [ entry () ]) with
    | Ok [ e ] -> e.Ledger.name = "London" && e.Ledger.bytes = 4096
    | _ -> false);

  rejects "a ledger with no version" (`Assoc [ ("entries", `List []) ]);
  rejects "a version this server does not understand"
    (`Assoc [ ("v", `Int 2); ("entries", `List []) ]);
  rejects "a ledger with no entries list" (`Assoc [ ("v", `Int 1) ]);
  rejects "a ledger that is not an object" (`List []);

  (* Each field, missing and then present with the wrong shape: the parse
     threads one Result through five lookups, and a mis-threaded one reports
     the wrong field or none at all. *)
  List.iter
    (fun key ->
      rejects (Printf.sprintf "an entry missing %s" key)
        (ledger [ without key (entry ()) ]))
    [ "name"; "completed"; "source"; "bytes"; "regions" ];

  rejects "a name that is not a string"
    (ledger [ with_field "name" (`Int 1) (entry ()) ]);
  rejects "an empty name"
    (ledger [ with_field "name" (`String "") (entry ()) ]);
  rejects "a name carrying a control character"
    (ledger [ with_field "name" (`String "Lon\tdon") (entry ()) ]);
  rejects "a negative completed count"
    (ledger [ with_field "completed" (`Int (-1)) (entry ()) ]);
  rejects "a source that is not a string"
    (ledger [ with_field "source" (`Bool true) (entry ()) ]);
  rejects "a negative byte count"
    (ledger [ with_field "bytes" (`Int (-1)) (entry ()) ]);
  rejects "an entry with no regions at all"
    (ledger [ with_field "regions" (`List []) (entry ()) ]);
  rejects "an entry that is not an object" (ledger [ `String "London" ]);

  rejects "a region missing a corner"
    (ledger [ entry ~regions:[ without "max_lat" (region ()) ] () ]);
  rejects "a corner that is not a number"
    (ledger
       [ entry ~regions:[ with_field "min_lon" (`String "west") (region ()) ] () ]);
  rejects "a max_zoom that is not an integer"
    (ledger
       [ entry ~regions:[ with_field "max_zoom" (`Float 12.5) (region ()) ] () ]);
  rejects "a region that is not an object"
    (ledger [ entry ~regions:[ `String "London" ] () ]);

  (* Integers are accepted where a float is expected -- a hand-edited or
     re-serialised ledger writes 51 rather than 51.0, and rejecting it would
     lose a real download. *)
  check "a whole-number corner is still a number"
    (Result.is_ok
       (Ledger.of_json
          (ledger [ entry ~regions:[ with_field "min_lat" (`Int 51) (region ()) ] () ])));

  (* The polygon is optional, and every ring is checked, not just the first:
     traverse stops at the first Error, so a bad second ring must still be
     found. *)
  let ring pts = `List (List.map (fun (x, y) -> `List [ `Float x; `Float y ]) pts) in
  let square = [ (-0.5, 51.3); (0.3, 51.3); (0.3, 51.7); (-0.5, 51.3) ] in
  check "a region with no polygon is fine"
    (Result.is_ok (Ledger.of_json (ledger [ entry () ])));
  check "a region with a polygon reads back"
    (Result.is_ok
       (Ledger.of_json
          (ledger
             [ entry
                 ~regions:[ region ~extra:[ ("polygon", `List [ ring square ]) ] () ]
                 () ])));
  rejects "a polygon that is not a list of rings"
    (ledger
       [ entry ~regions:[ region ~extra:[ ("polygon", `String "square") ] () ] () ]);
  rejects "a second ring that is not a list of points"
    (ledger
       [ entry
           ~regions:
             [ region
                 ~extra:[ ("polygon", `List [ ring square; `String "square" ]) ]
                 () ]
           () ]);
  rejects "a point that is not a pair"
    (ledger
       [ entry
           ~regions:
             [ region ~extra:[ ("polygon", `List [ `List [ `List [ `Float 0. ] ] ]) ] ()
             ]
           () ]);

  (* One bad entry fails the whole ledger rather than being skipped: a
     partially read ledger would report less disk in use than there is. *)
  rejects "one unreadable entry among good ones"
    (ledger [ entry (); `String "London"; entry () ]);

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1;
  print_endline "ledger rejections hold"
