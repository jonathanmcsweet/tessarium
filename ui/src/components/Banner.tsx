import { m } from "../paraglide/messages";
import { IconButton } from "./IconButton";
import { X } from "./icons";

type Props = {
  message: string;
  /* An optional way out of the condition the banner reports -- "no basemap"
     gains a download button. A plain labelled button, not an icon. */
  action?: { label: string; onClick: () => void; };
  onDismiss?: () => void;
};

export function Banner({ message, action, onDismiss }: Props) {
  return (
    <div
      className="banner flex items-center gap-3 border-b border-notice-line bg-notice px-4 py-2.5 text-sm leading-normal text-warn"
      role="status"
    >
      <p className="flex-1">{message}</p>
      {action && (
        <button
          type="button"
          className="banner-action btn flex-none border-warn bg-warn text-on-ink"
          onClick={action.onClick}
        >
          {action.label}
        </button>
      )}
      {onDismiss && (
        <IconButton
          label={m.a11y_dismiss_banner()}
          icon={<X size={18} aria-hidden />}
          onClick={onDismiss}
        />
      )}
    </div>
  );
}
