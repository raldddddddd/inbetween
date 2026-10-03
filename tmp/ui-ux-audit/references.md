# External UI/UX references

Use these as design constraints, not as decorative citations.

## Apple Human Interface Guidelines

- Designing for macOS  
  https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/
  - Mac interfaces should support efficient keyboard/pointer use and comfortable information density.
  - Prefer presenting useful content with fewer nested levels.

- Popovers  
  https://developer.apple.com/design/human-interface-guidelines/popovers/
  - Popovers should expose a small amount of information or functionality and only a few related tasks.
  - Avoid making a popover too large.
  - On macOS, consider a detachable popover/panel when users benefit from keeping richer information visible.

- Layout  
  https://developer.apple.com/design/human-interface-guidelines/layout/
  - Use consistent alignment, spacing, and layout guides.
  - Apple specifically advises against putting critical controls/information at the bottom of a macOS window; in a long scroll surface, actions also should not appear unexpectedly offscreen.

- Charts  
  https://developer.apple.com/design/human-interface-guidelines/charts
  - Use a clear plot area and meaningful baseline/axes.
  - Maintain a consistent visual hierarchy where the data is most prominent.
  - In compact environments, maximize useful plot width and keep labels concise.
  - Color can clarify data, but must not be the only differentiator.

- Buttons  
  https://developer.apple.com/design/human-interface-guidelines/buttons
  - Buttons need clear purpose and visible interaction feedback.
  - Use a prominent style for the most likely action; avoid too many prominent actions.
  - Prefer system button styles/roles so macOS provides expected states and accessibility behavior.

- Labels  
  https://developer.apple.com/design/human-interface-guidelines/labels
  - Use system fonts and system label colors to communicate relative importance.

## Practical interpretation for Inbetween

- Treat the menu-bar popover as an **at-a-glance command surface**, not a full dashboard stuffed into a transient window.
- If History, Reflection, and analytics remain information-heavy, move them to a dedicated window/panel opened from the popover.
- Use semantic color sparingly: Productive, Distracted, Unclassified, AI state, selection, and the primary action should be visually distinguishable without turning the UI into a rainbow.
- Do not show empty/zero sections merely to preserve a fixed template.
- An action must reveal its result where the user is looking; never require the user to discover an offscreen editor after pressing a button.
