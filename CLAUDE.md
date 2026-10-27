# Bton: project rules

UI:
- A list's main action (New issue, and any like it) floats at the bottom right over the list with
  `.floatingAction(...)` (Components.swift): never a button in a row or bar above the list. Actions
  inside a form or a conversation (Send, Create issue, Apply) stay in the footer under their content.
- Everything clickable shows the pointing-hand cursor: use `PillButton`, `IconButton`, a button with
  `PressStyle`, or `.pointingHandCursor()`. A native `Menu` or `Picker` does not, so build selectors
  from a button and a popover.
- A choice that belongs to the screen's title (which repo the new issue goes in) sits under the
  title, not in a block of its own with the same value repeated elsewhere.
