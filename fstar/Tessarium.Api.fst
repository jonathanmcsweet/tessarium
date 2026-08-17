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
