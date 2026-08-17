(* A token bucket, as a pure function of state and time.

   It exists for one endpoint. `/api/session` runs PBKDF2, which is
   deliberately slow — 2048 rounds of HMAC-SHA512, tens of milliseconds — and
   that is exactly what makes an unauthenticated endpoint calling it a lever
   for exhausting the host. Every other route is cheap enough not to care.

   The clock is a parameter rather than read here, so the behaviour can be
   tested at whatever times are interesting instead of by sleeping. *)

type t = {
  tokens : float;
  updated : float;  (** when [tokens] was last recomputed *)
}

type config = {
  rate : float;  (** tokens refilled per second *)
  burst : float;  (** ceiling, and the number available from cold *)
}

let default = { rate = 1.0; burst = 10.0 }

let create cfg = { tokens = cfg.burst; updated = neg_infinity }

(* [take cfg t ~now] is (allowed, state'). Refills for elapsed time, then
   spends one token if there is one.

   A bucket that has never been used has [updated = neg_infinity], which would
   make the elapsed time infinite and the refill a NaN. It starts full, so the
   first call just anchors the clock. *)
let take cfg t ~now =
  let refilled =
    if t.updated = neg_infinity then t.tokens
    else
      let elapsed = Float.max 0. (now -. t.updated) in
      Float.min cfg.burst (t.tokens +. (elapsed *. cfg.rate))
  in
  if refilled >= 1.0 then (true, { tokens = refilled -. 1.0; updated = now })
  else (false, { tokens = refilled; updated = now })

(* How long until one token is available, for a Retry-After header. Zero when
   one already is. *)
let retry_after cfg t ~now =
  let refilled =
    if t.updated = neg_infinity then t.tokens
    else Float.min cfg.burst (t.tokens +. (Float.max 0. (now -. t.updated) *. cfg.rate))
  in
  if refilled >= 1.0 then 0
  else int_of_float (Float.ceil ((1.0 -. refilled) /. cfg.rate))
