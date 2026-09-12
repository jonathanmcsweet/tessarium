/* The application's own icon set.

   Every control in the edgerunner palettes is cut at 45 degrees -- the button,
   the field, the dropdown, the icon button. The glyphs inside them were
   lucide's: a humanist set with round caps, round joins and true circles.
   The mismatch is loudest where the two meet, a circular magnifier four
   pixels inside a chamfered field.

   They are drawn here, to a spec, and `test/icons.mjs` reads that spec back
   off every glyph.

   ONLY in those palettes. The plain three cut nothing, and a lattice glyph
   on a square button is the same contradiction the other way round -- so
   each icon is two, and which one renders is `glyphSet` in `theme.ts`, the
   one place that classification is written. That test used to say "no file may draw an <svg>",
   which was the right rule while the set came from a package: a hand-written
   cross once shipped beside the banner's lucide one at a different stroke
   weight and the whole suite passed. The rule it enforces now is the same
   promise made the other way round -- one file draws them all, and the
   geometry is checked rather than the location.

   THE SPEC, which the test enforces:

     BOX       24 units, 2-unit stroke. Unchanged from lucide, so a glyph can
               be swapped one at a time and nothing reflows.
     JOINERY   Square caps, mitred joins. No round anything, at any size.
     LATTICE   Every segment is horizontal, vertical, or an exact 45-degree
               diagonal. No curves and no arbitrary angles.
     CHAMFER   An enclosing box cuts 4 units off its top-right and its
               bottom-left -- the same two corners, at the same ratio, as the
               44-pixel button it sits in. It is the signature.
     SOLIDS    A filled shape is a square on the lattice, not a circle: two
               units for a pip -- a dice spot, the dot on an i -- and four for
               a swatch.
     COLOUR    currentColor, always. All five palettes drive these from the
               text colour around them, as lucide's did. */

import {
  Check as SharedCheck,
  ChevronDown as SharedChevronDown,
  ChevronRight as SharedChevronRight,
  Copy as SharedCopy,
  Dices as SharedDices,
  Download as SharedDownload,
  Eye as SharedEye,
  EyeOff as SharedEyeOff,
  Info as SharedInfo,
  Languages as SharedLanguages,
  Lock as SharedLock,
  Palette as SharedPalette,
  PanelRightClose as SharedPanelRightClose,
  PanelRightOpen as SharedPanelRightOpen,
  Search as SharedSearch,
  X as SharedX,
} from "lucide-react";
import {
  type ComponentType,
  createContext,
  type ReactNode,
  type SVGProps,
  useContext,
  useEffect,
} from "react";
import { useAppStore } from "../store";
import { glyphSet, useResolvedTheme } from "../theme";

/* `f` marks a filled solid -- a pip -- rather than a stroked path. */
type Path = { d: string; f?: 1; };

const GLYPHS = {
  search: [{ d: "M4 4H12L16 8V16H8L4 12Z" }, { d: "M16 16 21 21" }],
  download: [
    { d: "M12 3V14" },
    { d: "M7 10 12 15 17 10" },
    { d: "M3 16V19L5 21H19L21 19V16" },
  ],
  lock: [
    { d: "M4 11H16L20 15V21H8L4 17Z" },
    { d: "M8 11V7L11 4H13L16 7V11" },
  ],
  /* A lens, not a box: the one enclosing shape that does not take the
     chamfer, because an eye with two square corners reads as a television. */
  eye: [{ d: "M2 12 7 7H17L22 12 17 17H7Z" }, { d: "M10 10H14V14H10Z" }],
  eyeOff: [
    { d: "M2 12 7 7H17L22 12 17 17H7Z" },
    { d: "M10 10H14V14H10Z" },
    { d: "M3 3 21 21" },
  ],
  copy: [{ d: "M8 3H17L21 7V16" }, { d: "M3 8H12L16 12V21H7L3 17Z" }],
  check: [{ d: "M4 12 9 17 20 6" }],
  chevronDown: [{ d: "M6 9 12 15 18 9" }],
  chevronRight: [{ d: "M9 6 15 12 9 18" }],
  x: [{ d: "M5 5 19 19" }, { d: "M19 5 5 19" }],
  dices: [
    { d: "M3 3H17L21 7V21H7L3 17Z" },
    { d: "M7 7H9V9H7Z", f: 1 },
    { d: "M15 7H17V9H15Z", f: 1 },
    { d: "M11 11H13V13H11Z", f: 1 },
    { d: "M7 15H9V17H7Z", f: 1 },
    { d: "M15 15H17V17H15Z", f: 1 },
  ],
  info: [
    { d: "M4 4H16L20 8V20H8L4 16Z" },
    { d: "M12 11V16" },
    { d: "M11 7H13V9H11Z", f: 1 },
  ],
  /* The A and the mark beside it, both rebuilt on the lattice: lucide's A
     rises at about 70 degrees and its second glyph has none of its strokes
     on one either, so this is the one shape that is redrawn rather than
     re-jointed.

     Redrawn twice. The first attempt kept lucide's stroke COUNT as well as
     its composition -- a bar, a stem under it and two legs under that, four
     strokes stacked down nine units -- and at the 16 pixels this is actually
     rendered at, square caps closed every gap between them and the mark came
     out a blot. The stem is gone and the mark is wider, which is the same
     character with room to be read. */
  languages: [
    { d: "M6 6 2 10V18" },
    { d: "M6 6 10 10V18" },
    { d: "M2 15H10" },
    { d: "M12 8H22" },
    { d: "M17 10 12 15" },
    { d: "M17 10 22 15" },
  ],
  /* Swatches on a card, which is what the control below it actually picks.
     lucide draws a painter's palette -- a blob with a thumb hole -- and the
     blob is a curve, so at this size the honest translation is the thing
     being chosen rather than the object that holds it. Four units, not the
     pip's two: three 2-unit dots in a box read as a luggage tag. */
  palette: [
    { d: "M3 4H17L21 8V20H7L3 16Z" },
    { d: "M6 7H10V11H6Z", f: 1 },
    { d: "M13 7H17V11H13Z", f: 1 },
    { d: "M6 13H10V17H6Z", f: 1 },
    { d: "M13 13H17V17H13Z", f: 1 },
  ],
  panelRightClose: [
    { d: "M3 4H17L21 8V20H7L3 16Z" },
    { d: "M15 4V20" },
    { d: "M8 12H12" },
    { d: "M10 10 12 12 10 14" },
  ],
  panelRightOpen: [
    { d: "M3 4H17L21 8V20H7L3 16Z" },
    { d: "M15 4V20" },
    { d: "M12 12H8" },
    { d: "M10 10 8 12 10 14" },
  ],
} satisfies Record<string, readonly Path[]>;

/* `size` rather than width and height, and every other SVG attribute passed
   through: the call sites were lucide's and this is the shape they were
   already written against, so the set landed as an import change. */
type Props = Omit<SVGProps<SVGSVGElement>, "width" | "height"> & {
  size?: number;
};

/* True where the palette cuts its corners. The default is the default
   palette, which is edgerunner dark -- so an icon rendered outside the
   provider draws what the stylesheet is painting around it rather than the
   wrong set. */
const Cut = createContext(true);

/* One subscription for the whole tree, rather than one per glyph. It also
   keeps `data-icons` honest: applyTheme writes it on every choice, but a
   device that flips to dark at dusk changes the answer without anybody
   choosing anything, and the stylesheet paints MapLibre's controls off that
   attribute. */
export function IconSet({ children }: { children: ReactNode; }) {
  const set = glyphSet(useResolvedTheme(useAppStore((s) => s.theme)));
  useEffect(() => {
    document.documentElement.setAttribute("data-icons", set);
  }, [set]);
  return <Cut.Provider value={set === "cut"}>{children}</Cut.Provider>;
}

function glyph(name: keyof typeof GLYPHS, Shared: ComponentType<Props>) {
  return function Icon({ size = 24, ...rest }: Props) {
    if (!useContext(Cut)) {
      return <Shared aria-hidden="true" size={size} {...rest} />;
    }
    return (
      <svg
        /* Decorative by default, and every call site is a decoration: the
           name of the thing lives on the control around the glyph, which
           `IconButton` makes both the tooltip and the accessible name. A
           caller that needs otherwise overrides it -- the spread is last. */
        aria-hidden="true"
        /* A stable handle for the end-to-end suite, which has to tell a copy
           glyph from the tick that replaces it and cannot do that by the
           label without pinning one locale. lucide shipped a class for the
           same reason; an attribute rather than a class, so a caller styling
           this through `className` is not fighting one set here. */
        data-glyph={name}
        width={size}
        height={size}
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth={2}
        strokeLinecap="square"
        strokeLinejoin="miter"
        {...rest}
      >
        {(GLYPHS[name] as readonly Path[]).map((path) => (
          <path
            key={path.d}
            d={path.d}
            {...(path.f === undefined
              ? {}
              : { fill: "currentColor", stroke: "none" })}
          />
        ))}
      </svg>
    );
  };
}

export const Search = glyph("search", SharedSearch);
export const Download = glyph("download", SharedDownload);
export const Lock = glyph("lock", SharedLock);
export const Eye = glyph("eye", SharedEye);
export const EyeOff = glyph("eyeOff", SharedEyeOff);
export const Copy = glyph("copy", SharedCopy);
export const Check = glyph("check", SharedCheck);
export const ChevronDown = glyph("chevronDown", SharedChevronDown);
export const ChevronRight = glyph("chevronRight", SharedChevronRight);
export const X = glyph("x", SharedX);
export const Dices = glyph("dices", SharedDices);
export const Info = glyph("info", SharedInfo);
export const Languages = glyph("languages", SharedLanguages);
export const Palette = glyph("palette", SharedPalette);
export const PanelRightClose = glyph("panelRightClose", SharedPanelRightClose);
export const PanelRightOpen = glyph("panelRightOpen", SharedPanelRightOpen);
