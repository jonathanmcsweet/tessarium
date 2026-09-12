import { z } from "zod";

export type Cell = {
  latLo: number;
  latHi: number;
  lonLo: number;
  lonHi: number;
};

export type Bounds = {
  latLo: number;
  lonLo: number;
  latHi: number;
  lonHi: number;
};

/* A refusal names itself with a stable code, so the six locales can say it
   in their own words; `message` is the core's English and is what the edge
   falls back to for a code it has no entry for. See core/refusal.ts. */
const Refusal = z.object({
  code: z.string(),
  arg: z.string(),
  message: z.string(),
});

export type Refusal = z.infer<typeof Refusal>;

const OkOrError = z.object({
  ok: z.boolean(),
  error: Refusal.nullable(),
});

const Status = z.object({
  unlocked: z.boolean(),
  gridVersion: z.string(),
  derivationVersion: z.string(),
  totalCells: z.string(),
});

const Address = z.object({ address: z.string() });
const Point = z.object({ lat: z.number(), lon: z.number() });
const Mnemonic = z.object({ mnemonic: z.string() });
const HeldPhrase = z.object({ mnemonic: z.string().nullable() });
const AddressShape = z.object({
  shape: z.enum(["complete", "partial", "no"]),
});

/* The cells arrive as a transferred Float64Array, not a plain array: a z20
   viewport is a few thousand cells and copying that on every map movement is
   a frame budget spent on nothing. */
const GridSchema = z.object({
  cells: z.instanceof(Float64Array),
  count: z.number().int().nonnegative(),
  truncated: z.boolean(),
});

export type Grid = z.infer<typeof GridSchema>;

type Pending = {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
};

/* Carries the worker's code so the display edge can translate it. `code` is
   null for anything that was not a refusal -- a bug in the worker, a worker
   that failed to start -- and the edge shows those differently on purpose,
   because they are not something the user did. */
export class CoreError extends Error {
  readonly code: string | null;
  readonly arg: string;

  constructor(message: string, code: string | null = null, arg = "") {
    super(message);
    this.code = code;
    this.arg = arg;
  }
}

export class Core {
  #worker: Worker;
  #pending = new Map<number, Pending>();
  #nextId = 1;

  constructor() {
    /* Classic worker, matching the importScripts in core.worker.js. Vite
       leaves public/ untouched, so the core is served as its own
       cacheable file rather than being folded into a UI chunk that changes
       every time a component does. */
    this.#worker = new Worker("/core.worker.js");
    this.#worker.onmessage = (event: MessageEvent) => {
      const { id, result, error, code, arg } = event.data;
      const pending = this.#pending.get(id);
      if (!pending) return;
      this.#pending.delete(id);
      if (error) {
        pending.reject(
          new CoreError(
            String(error),
            typeof code === "string" ? code : null,
            typeof arg === "string" ? arg : "",
          ),
        );
      } else pending.resolve(result);
    };
    this.#worker.onerror = (event) => {
      const failure = new CoreError(
        `core worker failed to start: ${event.message}`,
      );
      for (const pending of this.#pending.values()) pending.reject(failure);
      this.#pending.clear();
    };
  }

  #call<T>(schema: z.ZodType<T>, op: string, payload?: unknown): Promise<T> {
    const id = this.#nextId++;
    return new Promise<unknown>((resolve, reject) => {
      this.#pending.set(id, { resolve, reject });
      this.#worker.postMessage({ id, op, payload });
    }).then((raw) => {
      const parsed = schema.safeParse(raw);
      if (!parsed.success) {
        throw new CoreError(
          `core returned an unexpected shape for "${op}": ${parsed.error.message}`,
        );
      }
      return parsed.data;
    });
  }

  /* Checksum and wordlist only -- no derivation, so this is instant and safe
     to call on every keystroke. */
  validate(mnemonic: string) {
    return this.#call(OkOrError, "validate", { mnemonic });
  }

  /* Slow by design: Argon2id at 64 MiB in the worker's wasm module.
     Expect ~150 ms plus a cold start, and show it in the UI rather than
     appearing to hang. */
  unlock(mnemonic: string) {
    return this.#call(OkOrError, "unlock", { mnemonic });
  }

  /* A fresh 24-word phrase from the platform CSPRNG. The bytes are drawn in
     the worker and never reach this thread; only the words come back. */
  generate() {
    return this.#call(Mnemonic, "generate");
  }

  /* The words the key was derived from, for the two controls that copy them.
     Null once the map is locked, and after a reload, because the worker holds
     them and nothing else does.

     Deliberately NOT a React Query hook: a cached phrase is a phrase living
     in this thread, which is the one thing the worker boundary exists to
     avoid. Callers ask at the moment of the press and keep nothing. */
  heldPhrase() {
    return this.#call(HeldPhrase, "heldPhrase");
  }

  lock() {
    return this.#call(z.object({ ok: z.boolean() }), "lock");
  }

  status() {
    return this.#call(Status, "status");
  }

  encode(lat: number, lon: number) {
    return this.#call(Address, "encode", { lat, lon });
  }

  addressShape(text: string) {
    return this.#call(AddressShape, "addressShape", { text });
  }

  decode(address: string) {
    return this.#call(Point, "decode", { address });
  }

  grid(bounds: Bounds, limit: number) {
    return this.#call(GridSchema, "grid", { ...bounds, limit });
  }
}

export const cellAt = (grid: Grid, index: number): Cell => ({
  latLo: grid.cells[index * 4]!,
  latHi: grid.cells[index * 4 + 1]!,
  lonLo: grid.cells[index * 4 + 2]!,
  lonHi: grid.cells[index * 4 + 3]!,
});
