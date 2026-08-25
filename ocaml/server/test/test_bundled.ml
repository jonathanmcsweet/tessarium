(* Seeding a map directory from the bundle a package ships.

   The point of the bundle is that the app opens on a drawn planet instead
   of a blank one, so what matters here is not that a copy happened but that
   it happened exactly once and completely: a second run must not undo a
   deeper world overview the user fetched, and a run interrupted mid-copy
   must not leave a font directory that is missing half its glyphs. Both are
   states no later code can detect -- a short font directory answers every
   request it can and 404s the rest -- so they are checked here. *)

let checks = ref 0
let failures = ref 0

let check name ok =
  incr checks;
  if not ok then begin
    incr failures;
    Printf.printf "  FAIL  %s\n" name
  end

let write path contents =
  Eio.Path.save ~create:(`Or_truncate 0o644) path contents

let read path = try Some (Eio.Path.load path) with Eio.Io _ -> None
let exists path = Eio.Path.kind ~follow:true path <> `Not_found

let () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let root = Filename.temp_dir "tessarium-bundled" "" in
  let dir name = Filename.concat root name in

  (* A bundle in the shape a package builds: the overview, a glyph tree two
     levels deep, and the sprites beside them. *)
  let bundle = dir "bundle" in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 Eio.Path.(fs / bundle / "fonts" / "Noto Sans Regular");
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 Eio.Path.(fs / bundle / "sprites" / "v4");
  write Eio.Path.(fs / bundle / "world.pmtiles") "PMTiles-world";
  write Eio.Path.(fs / bundle / "fonts" / "Noto Sans Regular" / "0-255.pbf") "glyphs";
  write Eio.Path.(fs / bundle / "sprites" / "v4" / "light.json") "{}";
  (* Something the packager did not mean to ship. A bundle is assembled by a
     script, and a stray file in it must not become a write to the user's
     map directory. *)
  write Eio.Path.(fs / bundle / "notes.txt") "not part of the bundle";

  (* ------------------------------------------------- an empty first run *)
  let fresh = dir "fresh" in
  Tessarium_server.Bundled.seed ~fs ~from:bundle ~into:fresh;
  check "a missing map directory is created"
    (Eio.Path.kind ~follow:true Eio.Path.(fs / fresh) = `Directory);
  check "the world overview lands"
    (read Eio.Path.(fs / fresh / "world.pmtiles") = Some "PMTiles-world");
  check "so do the glyphs, at their own depth"
    (read Eio.Path.(fs / fresh / "fonts" / "Noto Sans Regular" / "0-255.pbf")
     = Some "glyphs");
  check "and the sprites"
    (read Eio.Path.(fs / fresh / "sprites" / "v4" / "light.json") = Some "{}");
  check "nothing outside the bundle's own entries is copied"
    (not (exists Eio.Path.(fs / fresh / "notes.txt")));
  check "and no half-copied entry is left behind"
    (List.for_all
       (fun n -> not (String.ends_with ~suffix:".seeding" n))
       (Eio.Path.read_dir Eio.Path.(fs / fresh)));

  (* ------------------------------------------------------ the second run *)
  (* What a user gets after fetching the world in the app: their overview is
     deeper than the shipped one, and every restart must leave it alone. *)
  write Eio.Path.(fs / fresh / "world.pmtiles") "the deeper one they fetched";
  write Eio.Path.(fs / fresh / "fonts" / "Noto Sans Regular" / "0-255.pbf") "theirs";
  Tessarium_server.Bundled.seed ~fs ~from:bundle ~into:fresh;
  check "a second run does not overwrite the world overview"
    (read Eio.Path.(fs / fresh / "world.pmtiles")
     = Some "the deeper one they fetched");
  check "nor reach inside a directory it already seeded"
    (read Eio.Path.(fs / fresh / "fonts" / "Noto Sans Regular" / "0-255.pbf")
     = Some "theirs");

  (* --------------------------------------------------- a partial directory *)
  (* Half a bundle is the state left by a package that grew an entry: what
     is missing is seeded, what is there is not touched. *)
  let partial = dir "partial" in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 Eio.Path.(fs / partial);
  write Eio.Path.(fs / partial / "world.pmtiles") "already here";
  Tessarium_server.Bundled.seed ~fs ~from:bundle ~into:partial;
  check "an entry already present is left as it was"
    (read Eio.Path.(fs / partial / "world.pmtiles") = Some "already here");
  check "an entry that is missing is seeded beside it"
    (read Eio.Path.(fs / partial / "sprites" / "v4" / "light.json") = Some "{}");

  (* ------------------------------------------------ an interrupted first run *)
  (* The directory a killed copy leaves. It cannot be resumed -- nothing
     records how far it got -- so it must be discarded rather than renamed
     into place, which would publish a font directory with one glyph in it. *)
  let torn = dir "torn" in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755
    Eio.Path.(fs / torn / "fonts.seeding" / "Noto Sans Regular");
  write
    Eio.Path.(fs / torn / "fonts.seeding" / "Noto Sans Regular" / "0-255.pbf")
    "torn";
  Tessarium_server.Bundled.seed ~fs ~from:bundle ~into:torn;
  check "a torn copy is discarded rather than published"
    (read Eio.Path.(fs / torn / "fonts" / "Noto Sans Regular" / "0-255.pbf")
     = Some "glyphs");
  check "and its temporary directory does not survive"
    (not (exists Eio.Path.(fs / torn / "fonts.seeding")));

  (* ------------------------------------------------------- a stray link *)
  (* A bundle is assembled by a script, and a link in one would be an
     accident. Following it would copy whatever it points at into the user's
     map directory, which is somewhere between wrong and a way out of the
     tree; leaving the entry unseeded is the safe reading of a bundle that
     needs fixing. *)
  let linked = dir "linked" in
  let elsewhere = dir "elsewhere" in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 Eio.Path.(fs / elsewhere);
  write Eio.Path.(fs / elsewhere / "0-255.pbf") "not ours to ship";
  let bundle_with_link = dir "bundle-link" in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 Eio.Path.(fs / bundle_with_link);
  (* Pointed at a perfectly readable directory on purpose: a link to
     somewhere unreadable would leave this passing because the copy failed,
     which is passing for the wrong reason. *)
  Eio.Path.symlink ~link_to:elsewhere
    Eio.Path.(fs / bundle_with_link / "fonts");
  write Eio.Path.(fs / bundle_with_link / "world.pmtiles") "PMTiles-world";
  Tessarium_server.Bundled.seed ~fs ~from:bundle_with_link ~into:linked;
  check "a linked entry is not followed"
    (not (exists Eio.Path.(fs / linked / "fonts")));
  check "and the entries beside it still land"
    (read Eio.Path.(fs / linked / "world.pmtiles") = Some "PMTiles-world");

  (* ---------------------------------------------------------- no bundle *)
  (* A source build, and the common case: there is nothing to seed and
     nothing to say. It must not create the map directory either -- a server
     run with --basemap pointing somewhere wrong should fail the way it
     always did, not silently make it. *)
  let nowhere = dir "nowhere" in
  Tessarium_server.Bundled.seed ~fs ~from:(dir "absent") ~into:nowhere;
  check "no bundle means no map directory is invented"
    (not (exists Eio.Path.(fs / nowhere)));

  (* ------------------------------------------------------- where it looks *)
  (* Derived from the running executable so that a tarball, /usr/bin and an
     AppImage all find their own. The test binary is not installed anywhere,
     so what is checkable here is the shape. *)
  let default = Tessarium_server.Bundled.default_dir () in
  check ("the default bundle sits under share/tessarium/basemap (" ^ default ^ ")")
    (String.ends_with ~suffix:"/share/tessarium/basemap" default);
  check "and is named relative to the binary's prefix, not the cwd"
    (Filename.is_relative default = Filename.is_relative Sys.executable_name);

  Eio.Path.rmtree ~missing_ok:true Eio.Path.(fs / root);

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  print_endline
    (if !failures = 0 then "bundle seeding holds" else "bundle seeding FAILED");
  if !failures > 0 then exit 1
