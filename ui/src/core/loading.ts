/* Tile-loading indicator state.

   MapLibre fires dataloading/idle in bursts on every pan, so a bar wired
   straight to the events would flicker constantly. The rule here: show
   only once loading has lasted SHOW_DELAY_MS without an idle in between,
   hide immediately on idle. Pure and timer-injected, so the node test
   drives it with fake clocks and the module under test is the module the
   app ships. */

export const SHOW_DELAY_MS = 300;

export interface LoadingTracker {
  loading: () => void;
  idle: () => void;
  dispose: () => void;
}

export function createLoadingTracker(
  show: (on: boolean) => void,
  delayMs: number = SHOW_DELAY_MS,
  setT: (fn: () => void, ms: number) => unknown = (fn, ms) =>
    setTimeout(fn, ms),
  clearT: (t: unknown) => void = (t) =>
    clearTimeout(t as ReturnType<typeof setTimeout>),
): LoadingTracker {
  let timer: unknown;
  let visible = false;
  let disposed = false;
  return {
    loading() {
      if (disposed || visible || timer !== undefined) return;
      timer = setT(() => {
        timer = undefined;
        if (!disposed) {
          visible = true;
          show(true);
        }
      }, delayMs);
    },
    idle() {
      if (disposed) return;
      if (timer !== undefined) {
        clearT(timer);
        timer = undefined;
      }
      if (visible) {
        visible = false;
        show(false);
      }
    },
    dispose() {
      disposed = true;
      if (timer !== undefined) {
        clearT(timer);
        timer = undefined;
      }
    },
  };
}
