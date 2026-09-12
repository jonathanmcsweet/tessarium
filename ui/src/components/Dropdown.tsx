import {
  Button,
  Label,
  ListBox,
  ListBoxItem,
  Popover,
  Select,
  SelectValue,
} from "react-aria-components";
import { ChevronDown } from "./icons";

/* The closed control. 44px, a comfortable touch target, against the 22px
   system control it replaced. */
const TRIGGER =
  "dropdown-button focus-ring flex min-h-11 max-w-full flex-1 cursor-pointer "
  + "items-center justify-between gap-2 border border-line-strong "
  + "bg-card px-2 text-left text-sm text-ink "
  + "disabled:cursor-default disabled:opacity-55";

type Props<T extends string> = {
  /* Always present. `labelHidden` decides whether it is DRAWN, never
     whether it exists: a dropdown with no accessible name is unusable, and
     there is no way to build one with this. */
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
      className={`dropdown flex min-w-0 items-center gap-2${
        className ? ` ${className}` : ""
      }`}
      selectedKey={value}
      onSelectionChange={(key) => onChange(key as T)}
      isDisabled={disabled ?? false}
    >
      <Label className={labelHidden ? "sr-only" : "panel-note"}>
        {label}
      </Label>
      <Button className={TRIGGER}>
        <SelectValue />
        <ChevronDown
          size={16}
          aria-hidden="true"
          className="flex-none text-ink-soft"
        />
      </Button>
      <Popover className="dropdown-popover sheet w-(--trigger-width) min-w-fit">
        <ListBox className="block max-h-72 overflow-y-auto p-1 outline-none">
          {options.map((option) => (
            <ListBoxItem
              key={option.value}
              id={option.value}
              data-value={option.value}
              className="dropdown-option sheet-option selected:font-semibold"
            >
              {option.label}
            </ListBoxItem>
          ))}
        </ListBox>
      </Popover>
    </Select>
  );
}
