/* The shared dropdown.

   This was two native `<select>` elements, and the comment on one of them
   argued the platform primitive was the right answer: keyboard-operable,
   screen-reader announced and touch-friendly everywhere without a line of
   behaviour code, and better than a hand-rolled listbox would be. That
   argument was correct and it was about HAND-ROLLING. It stops applying once
   the project has a vetted library for exactly this, which it does since the
   search box moved to React Aria -- so what is left is the reason to change:
   a native select is drawn by the operating system, and it is the one control
   in the application that does not look like the application.

   What is given up, and it is not nothing: on a phone, a native select opens
   the platform's own picker, which some people know better than any custom
   popover. React Aria's Select is built for touch and this is a considered
   trade rather than an oversight -- if it turns out to matter, the thing to
   restore is the native element on coarse pointers, not a second listbox. */

import { ChevronDown } from "lucide-react";
import {
  Button,
  Label,
  ListBox,
  ListBoxItem,
  Popover,
  Select,
  SelectValue,
} from "react-aria-components";

type Props<T extends string> = {
  /* Always present. `labelHidden` decides whether it is drawn, never
     whether it exists -- a dropdown with no accessible name is unusable
     and there is no way to build one with this. */
  label: string;
  labelHidden?: boolean;
  value: T;
  onChange: (value: T) => void;
  options: ReadonlyArray<{ value: T; label: string; }>;
  disabled?: boolean;
  className?: string;
};

export function Dropdown<T extends string>({
  label,
  labelHidden,
  value,
  onChange,
  options,
  disabled,
  className,
}: Props<T>) {
  return (
    <Select
      className={className ? `dropdown ${className}` : "dropdown"}
      selectedKey={value}
      onSelectionChange={(key) => onChange(key as T)}
      isDisabled={disabled ?? false}
    >
      <Label className={labelHidden ? "sr-only" : "dropdown-label"}>
        {label}
      </Label>
      <Button className="dropdown-button">
        <SelectValue />
        <ChevronDown size={16} aria-hidden="true" />
      </Button>
      <Popover className="dropdown-popover">
        <ListBox className="dropdown-listbox">
          {options.map((option) => (
            <ListBoxItem
              key={option.value}
              id={option.value}
              /* Written out rather than relying on the library's own key
                 attribute: this is what the end-to-end suite picks options
                 by, and a selector should not depend on an internal. */
              data-value={option.value}
              className="dropdown-option"
            >
              {option.label}
            </ListBoxItem>
          ))}
        </ListBox>
      </Popover>
    </Select>
  );
}
