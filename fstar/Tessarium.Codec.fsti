module Tessarium.Codec

/// Mixed radix (2048, 2048, 2048, 10000) and the top-level API.
/// NOT YET VERIFIED.

open FStar.Mul
open Tessarium.Spec
open Tessarium.Grid

type word_idx = w:nat{w < words}
type num_idx  = n:nat{n < num_max}
type address  = word_idx & word_idx & word_idx & num_idx

val to_address   : index:nat{index < addr_space} -> address
val from_address : address -> n:nat{n < addr_space}

/// THEOREM. The mixed-radix decomposition is a bijection.
val theorem_codec_roundtrip (i: nat{i < addr_space})
  : Lemma (from_address (to_address i) == i)

val theorem_codec_roundtrip_rev (a: address)
  : Lemma (to_address (from_address a) == a)

(* ------------------------------------------------------------ end to end *)

val encode : Tessarium.Feistel.round_fn -> Tessarium.Feistel.key -> lat_ns -> lon_ns -> address

/// Decode is partial: about 35% of addresses map to an index at or above
/// total_cells and resolve to nothing. That is deliberate — it is what makes
/// a mistyped address get rejected rather than silently resolving somewhere
/// plausible.
val decode : Tessarium.Feistel.round_fn -> Tessarium.Feistel.key -> address
           -> option (lat_ns & lon_ns)

/// THE THEOREM THAT MATTERS. Encoding a point and decoding the result
/// returns a point in the same cell. A silent mismatch here is the failure
/// mode this entire development exists to rule out: nothing crashes, no
/// error surfaces, and the answer is confidently wrong.
val theorem_end_to_end (f: Tessarium.Feistel.round_fn) (k: Tessarium.Feistel.key)
                       (lat: lat_ns) (lon: lon_ns)
  : Lemma (match decode f k (encode f k lat lon) with
           | None -> False
           | Some (lat', lon') -> point_to_cell lat' lon' == point_to_cell lat lon)

/// Encoding never yields an address that fails to decode.
val theorem_encode_total (f: Tessarium.Feistel.round_fn) (k: Tessarium.Feistel.key)
                         (lat: lat_ns) (lon: lon_ns)
  : Lemma (Some? (decode f k (encode f k lat lon)))
