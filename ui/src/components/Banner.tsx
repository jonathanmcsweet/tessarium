/* Site-wide notices, across the top of the screen.

   For conditions that affect the whole application rather than one action --
   a missing basemap, say. Anything that is the result of a button the user
   just pressed is a toast instead; the difference is whether it will still be
   true in a minute.

   `role="status"` rather than `alert`: these are degradations to work around,
   not interruptions, and an alert would cut across whatever the user was
   doing. */

import { X } from "lucide-react";
import { m } from "../paraglide/messages";
import { IconButton } from "./IconButton";

type Props = {
  message: string;
  /* An optional way out of the condition the banner reports -- "no basemap"
     gains a download button. A plain labelled button, not an icon. */
  action?: { label: string; onClick: () => void; };
  onDismiss?: () => void;
};

export function Banner({ message, action, onDismiss }: Props) {
  return (
    <div className="banner" role="status">
      <p>{message}</p>
      {action && (
        <button
          type="button"
          className="banner-action"
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
          className="banner-dismiss"
        />
      )}
    </div>
  );
}
