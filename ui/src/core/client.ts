/* Typed promise wrapper over the core worker.

   The worker holds the key; this is the only way to reach it, and it is
   deliberately narrow. Note what is absent: there is no `getKey`. The key
   cannot be read back out, so no amount of misuse from a component can put it
   somewhere it should not be. */

export type Cell = {
  latLo: number;
  latHi: number;
  lonLo: number;
  lonHi: number;
};

export type Grid = {
  cells: Float64Array;
  count: number;
  truncated: boolean;
  addresses?: string[];
};

export type Bounds = {
  latLo: number;
  lonLo: number;
  latHi: number;
  lonHi: number;
};

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
      if (error) pending.reject(new CoreError(error));
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

  #call<T>(op: string, payload?: unknown): Promise<T> {
    const id = this.#nextId++;
    return new Promise<T>((resolve, reject) => {
      this.#pending.set(id, {
        resolve: resolve as (value: unknown) => void,
        reject,
      });
      this.#worker.postMessage({ id, op, payload });
    });
  }

  /* Checksum and wordlist only -- no derivation, so this is instant and safe
     to call on every keystroke. */
  validate(mnemonic: string): Promise<{ ok: boolean; error: string | null }> {
    return this.#call("validate", { mnemonic });
  }

  /* Slow by design: 2048 rounds of PBKDF2-HMAC-SHA512. Expect hundreds of
     milliseconds, and show it in the UI rather than appearing to hang. */
  unlock(
    mnemonic: string,
    passphrase: string,
  ): Promise<{ ok: boolean; error: string | null }> {
    return this.#call("unlock", { mnemonic, passphrase });
  }

  lock(): Promise<{ ok: boolean }> {
    return this.#call("lock");
  }

  status(): Promise<{
    unlocked: boolean;
    gridVersion: string;
    totalCells: string;
  }> {
    return this.#call("status");
  }

  encode(lat: number, lon: number): Promise<{ address: string }> {
    return this.#call("encode", { lat, lon });
  }

  decode(address: string): Promise<{ lat: number; lon: number }> {
    return this.#call("decode", { address });
  }

  grid(bounds: Bounds, limit: number): Promise<Grid> {
    return this.#call("grid", { ...bounds, limit });
  }

  gridWithAddresses(bounds: Bounds, limit: number): Promise<Grid> {
    return this.#call("gridWithAddresses", { ...bounds, limit });
  }
}

export const cellAt = (grid: Grid, index: number): Cell => ({
  latLo: grid.cells[index * 4]!,
  latHi: grid.cells[index * 4 + 1]!,
  lonLo: grid.cells[index * 4 + 2]!,
  lonHi: grid.cells[index * 4 + 3]!,
});

export const cellContains = (cell: Cell, lat: number, lon: number): boolean =>
  /* Half-open at the high edge, matching the core exactly. A point on a shared
     edge belongs to one cell, not to both. */
  lat >= cell.latLo && lat < cell.latHi &&
  lon >= cell.lonLo && lon < cell.lonHi;
