module Tessarium.Low.Api

/// Point <-> address end to end, over machine integers: the composition of
/// the three ported stages, generic over the round function exactly as the
/// spec Api is. Decode's partiality crosses the C boundary as a flag word
/// rather than an option, so the C signature stays plain integers.

module S  = Tessarium.Spec
module T  = Tessarium.Table
module F  = Tessarium.Feistel
module A  = Tessarium.Api
module G  = FStar.Ghost
module LF = Tessarium.Low.Feistel
module LG = Tessarium.Low.Grid
module LC = Tessarium.Low.Codec
module U64 = FStar.UInt64

unfold noextract
let v64 (x: U64.t) : int = U64.v x

let total_cells64 : (c: U64.t{v64 c == T.total_cells}) =
  assert_norm (T.total_cells == 55692067744000); 55692067744000uL

let encode_low
    (#key #tweak: Type) (#rf: G.erased (F.round_fn key tweak))
    (cum: LG.cum_low) (f: LF.round_low rf) (k: key) (t: tweak)
    (dlat: U64.t{U64.v dlat <= S.lat_span})
    (dlon: U64.t{U64.v dlon <= S.lon_span})
  : Pure (U64.t & U64.t & U64.t & U64.t)
      (requires True)
      (ensures  fun (w1, w2, w3, n) ->
        (let (sw1, sw2, sw3, sn) =
           A.encode (G.reveal rf) k t (S.lat_min + U64.v dlat)
                                      (S.lon_min + U64.v dlon) in
         v64 w1 == sw1 /\ v64 w2 == sw2 /\ v64 w3 == sw3 /\ v64 n == sn))
  = T.lemma_fits ();
    let cell = LG.point_to_cell_low cum dlat dlon in
    LC.to_address_low (LF.encrypt_low f k t cell)

/// Decode: flag = 1 and the centre offsets when the address resolves,
/// flag = 0 (and zeros) when it permutes past the grid -- the spec's None.
let decode_low
    (#key #tweak: Type) (#rf: G.erased (F.round_fn key tweak))
    (cum: LG.cum_low) (f: LF.round_low rf) (k: key) (t: tweak)
    (w1: U64.t{U64.v w1 < S.words}) (w2: U64.t{U64.v w2 < S.words})
    (w3: U64.t{U64.v w3 < S.words}) (n: U64.t{U64.v n < S.num_max})
  : Pure (U64.t & U64.t & U64.t)
      (requires True)
      (ensures  fun (flag, dlat, dlon) ->
        (match A.decode (G.reveal rf) k t (U64.v w1, U64.v w2, U64.v w3, U64.v n) with
         | None -> v64 flag == 0
         | Some (slat, slon) ->
             v64 flag == 1 /\
             v64 dlat == slat - S.lat_min /\ v64 dlon == slon - S.lon_min))
  = T.lemma_fits ();
    let i = LF.decrypt_low f k t (LC.from_address_low w1 w2 w3 n) in
    if U64.lt i total_cells64 then begin
      let (dlat, dlon) = LG.cell_to_point_low cum i in
      (1uL, dlat, dlon)
    end
    else (0uL, 0uL, 0uL)

/// The user-facing theorem, restated on the machine composition: encoding
/// a point and decoding the result lands in the same cell -- for any
/// round function and any conforming table lookup.
val theorem_end_to_end_low
    (#key #tweak: Type) (#rf: G.erased (F.round_fn key tweak))
    (cum: LG.cum_low) (f: LF.round_low rf) (k: key) (t: tweak)
    (dlat: U64.t{U64.v dlat <= S.lat_span})
    (dlon: U64.t{U64.v dlon <= S.lon_span})
  : Lemma (let (w1, w2, w3, n) = encode_low cum f k t dlat dlon in
           U64.v w1 < S.words /\ U64.v w2 < S.words /\
           U64.v w3 < S.words /\ U64.v n < S.num_max /\
           (let (flag, cdlat, cdlon) = decode_low cum f k t w1 w2 w3 n in
            U64.v flag == 1 /\ U64.v cdlat <= S.lat_span /\ U64.v cdlon <= S.lon_span /\
            LG.point_to_cell_low cum cdlat cdlon
              == LG.point_to_cell_low cum dlat dlon))
let theorem_end_to_end_low #key #tweak #rf cum f k t dlat dlon =
  let lat = S.lat_min + U64.v dlat in
  let lon = S.lon_min + U64.v dlon in
  A.theorem_decode_encode (G.reveal rf) k t lat lon;
  A.theorem_end_to_end (G.reveal rf) k t lat lon;
  let (w1, w2, w3, n) = encode_low cum f k t dlat dlon in
  let (flag, cdlat, cdlon) = decode_low cum f k t w1 w2 w3 n in
  U64.v_inj (LG.point_to_cell_low cum cdlat cdlon)
            (LG.point_to_cell_low cum dlat dlon)
