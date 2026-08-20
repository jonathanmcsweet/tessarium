/* Typed promise wrapper over the core worker.

   The worker holds the key; this is the only way to reach it, and it is
   deliberately narrow. Note what is absent: there is no `getKey`. The key
   cannot be read back out, so no amount of misuse from a component can put it
   somewhere it should not be.

   Everything crossing back from the worker is parsed rather than asserted.
   `postMessage` delivers whatever the other side sent, and TypeScript has no
   opinion about it at runtime -- a cast would only be a promise we made to
   ourselves. Zod checks it. The costly bug this guards against is real and has
   happened here before: the worker once returned failures nested inside a
   success value, and the main thread, having cast rather than checked, flew
   the map to NaN. */

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

const OkOrError = z.object({
  ok: z.boolean(),
  error: z.string().nullable(),
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

export class CoreError extends Error {}

export class Core {
  #worker: Worker;
  #pending = new Map<number, Pending>();
  #nextId = 1;

  constructor() {
    /* Classic worker, matching the importScripts in core.worker.js. Vite
       leaves public/ untouched, so the 4.4 MB core is served as its own
       cacheable file rather than being folded into a UI chunk that changes
       every time a component does. */
    this.#worker = new Worker("/core.worker.js");
    this.#worker.onmessage = (event: MessageEvent) => {
      const { id, result, error } = event.data;
      const pending = this.#pending.get(id);
      if (!pending) return;
      this.#pending.delete(id);
      if (error) pending.reject(new CoreError(String(error)));
      else pending.resolve(result);
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
  unlock(mnemonic: string, passphrase: string) {
    return this.#call(OkOrError, "unlock", { mnemonic, passphrase });
  }

  /* A fresh 24-word phrase from the platform CSPRNG. The bytes are drawn in
     the worker and never reach this thread; only the words come back. */
  generate() {
    return this.#call(Mnemonic, "generate");
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
