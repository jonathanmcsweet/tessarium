import { createContext, type ReactNode, useContext, useId } from "react";
import { InfoTip } from "./Tip";

const Depth = createContext(0);

export function PanelSection(
  { title, info, action, className, children }: {
    title: string;
    info?: string | undefined;
    action?: ReactNode | undefined;
    className?: string | undefined;
    children?: ReactNode | undefined;
  },
) {
  const depth = useContext(Depth);
  const Heading = depth === 0 ? "h2" : "h3";
  const id = useId();
  return (
    <section
      className={`${depth === 0 ? "panel-section" : "panel-group"}${
        className === undefined ? "" : ` ${className}`
      }`}
      aria-labelledby={id}
    >
      <header className="panel-section-head">
        <Heading id={id} className="panel-title">{title}</Heading>
        {info !== undefined && <InfoTip label={info} />}
        {action !== undefined && (
          <div className="panel-section-action">{action}</div>
        )}
      </header>
      <Depth.Provider value={depth + 1}>{children}</Depth.Provider>
    </section>
  );
}
