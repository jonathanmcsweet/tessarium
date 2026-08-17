module Tessarium.Api

/// Point <-> address, end to end.
///
/// Decode is partial: about 35% of addresses permute back to an index at or
/// above total_cells and resolve to nothing. That is deliberate — it is what
/// makes a mistyped address get rejected rather than silently resolving
/// somewhere plausible.

module G = Tessarium.Grid
module F = Tessarium.Feistel
module C = Tessarium.Codec
module T = Tessarium.Table

open Tessarium.Spec

let encode (#key #tweak: Type) (f: F.round_fn key tweak) (k: key) (t: tweak) (lat: lat_ns) (lon: lon_ns)
  : C.address =
  T.lemma_fits ();
  C.to_address (F.encrypt f k t (G.point_to_cell lat lon))

let decode (#key #tweak: Type) (f: F.round_fn key tweak) (k: key) (t: tweak) (a: C.address)
  : option (lat_ns & lon_ns) =
  let i = F.decrypt f k t (C.from_address a) in
  if i < T.total_cells then Some (G.cell_to_point i) else None

/// Cell bounds for a point, which is what draws the grid overlay.
let bounds_of_point (lat: lat_ns) (lon: lon_ns) : int & int & int & int =
  G.cell_bounds (G.point_to_cell lat lon)

(* ================================================================ theorems *)

/// Decoding an encoded point returns that point's cell. Never `None`: the
/// partiality of `decode` applies to addresses nobody encoded, not to ones this
/// system produced.
val theorem_decode_encode
      (#key #tweak: Type) (f: F.round_fn key tweak) (k: key) (t: tweak)
      (lat: lat_ns) (lon: lon_ns)
  : Lemma (decode f k t (encode f k t lat lon)
           == Some (G.cell_to_point (G.point_to_cell lat lon)))
let theorem_decode_encode f k t lat lon =
  T.lemma_fits ();
  let c = G.point_to_cell lat lon in
  F.theorem_roundtrip f k t c;
  C.theorem_roundtrip (F.encrypt f k t c)

/// And the property a user would state: what comes back names the same square
/// they started in. Composes the grid round trip onto the one above, so it
/// depends on every layer being right rather than on any one of them.
val theorem_end_to_end
      (#key #tweak: Type) (f: F.round_fn key tweak) (k: key) (t: tweak)
      (lat: lat_ns) (lon: lon_ns)
  : Lemma (match decode f k t (encode f k t lat lon) with
           | None -> False
           | Some (lat', lon') ->
               G.point_to_cell lat' lon' == G.point_to_cell lat lon)
let theorem_end_to_end f k t lat lon =
  theorem_decode_encode f k t lat lon;
  G.theorem_roundtrip (G.point_to_cell lat lon)

/// Two points get the same address only if they were in the same cell. This is
/// the whole chain's injectivity: grid, then permutation, then codec.
val theorem_injective
      (#key #tweak: Type) (f: F.round_fn key tweak) (k: key) (t: tweak)
      (lat1: lat_ns) (lon1: lon_ns) (lat2: lat_ns) (lon2: lon_ns)
  : Lemma (requires encode f k t lat1 lon1 == encode f k t lat2 lon2)
          (ensures  G.point_to_cell lat1 lon1 == G.point_to_cell lat2 lon2)
let theorem_injective f k t lat1 lon1 lat2 lon2 =
  T.lemma_fits ();
  let c1 = G.point_to_cell lat1 lon1 in
  let c2 = G.point_to_cell lat2 lon2 in
  C.theorem_injective (F.encrypt f k t c1) (F.encrypt f k t c2);
  F.theorem_injective f k t c1 c2
