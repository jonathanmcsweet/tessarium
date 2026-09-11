/* The small wait: four squares filling in turn, for one section of a card.

   The application's other loading indicator is the bar across the top of the
   map (styles.css, `.map-loading`), which is about the whole view. This is
   for a section that is waiting on its own while everything around it is
   already there -- the estimate, which is real planning work on the server
   and takes as long as the area is large.

   A component rather than four elements copied into each caller: the mark is
   its markup AND its stylesheet rule, and a second copy is how one of them
   comes to have three squares.

   `aria-hidden`, always. Every caller puts this beside a sentence saying what
   is being waited for, in a region that announces itself -- a mark that also
   spoke would say the same thing twice. */
export function LoadingTiles() {
  return (
    <span className="loading-tiles" aria-hidden>
      <i />
      <i />
      <i />
      <i />
    </span>
  );
}
