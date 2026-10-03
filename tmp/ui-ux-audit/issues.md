# UI/UX issues to address

## User-reported problems — required

1. **Redundant top status blocks**
   - The top of the menu-bar surface has separate large rows for “Listening for Codex” and “Nothing needs review.”
   - They consume scarce vertical space and read like two separate list/status sections before the actual useful content.
   - Consolidate current state + review state into a compact header/status area. Do not keep two large stacked status blocks unless computer-use testing proves both are necessary.

2. **The interface is overwhelmingly gray**
   - Cards, backgrounds, buttons, text, and disabled states blur together.
   - Establish intentional visual hierarchy using macOS system materials, label levels, semantic status color, and the app accent color.
   - Do not make everything colorful; use color intentionally for primary actions, status, selection, and data encoding.

3. **Reflection dominates the popover**
   - The Reflection card is too tall and pushes the information the user actually checks downward.
   - The default menu-bar view should prioritize current state, review needs, and the most useful recent/7-day summary.
   - Make Reflection substantially more compact: collapsed by default, concise summary row, or open it in a dedicated detail surface/window. The AI explanation text should not take over the menu-bar popover.

4. **The 7-day bar chart violates its baseline / plot area**
   - The Today stacked bar visually extends through/past the baseline instead of sitting cleanly on it.
   - Fix plot geometry, baseline alignment, clipping, and padding using Swift Charts conventions.
   - The chart must remain legible at compact popover widths.

5. **Zero-value categories should not take space**
   - Example: `Unclassified 0s` appears as a full row even when there is nothing to communicate.
   - Hide zero-value categories in summaries/charts unless zero itself is meaningful to the current task.
   - This applies to Productive/Distracted/Unclassified/Not Recorded where appropriate; do not hide a category if it is needed to explain a state or action.

6. **Create Rule gives poor action feedback and reveals UI offscreen**
   - Pressing “Create rule” appears to do nothing because the rule editor/action area is rendered at the very bottom of the long scroll surface.
   - The action must immediately reveal its result in the user’s current context.
   - Prefer a sheet, popover, inline expansion anchored to the tapped row, or programmatic scroll + focus. Do not silently mutate content outside the viewport.

## Additional issues visible in the supplied screenshots — inspect, do not blindly implement

7. **Popover contains too many distinct jobs**
   - Current status, review, AI Reflection, 7-day analytics, recent weeks, and detailed History are all competing inside one scrolling menu-bar popover.
   - Apple’s popover guidance recommends a small amount of information/functionality and a few related tasks.
   - Use computer-use inspection to decide whether the menu-bar popover should become a compact “at a glance + actions” surface while History/Reflection/analytics open in a dedicated window or detachable panel.

8. **History detail is control-dense**
   - Expanded History repeats Productive / Distracted / Unclassified / Reset / Create rule for every slice.
   - This is visually noisy and makes the data hard to scan.
   - Explore a more compact per-slice interaction: selected classification as a compact control, secondary actions in a context menu, or edit-on-selection. Preserve fast correction and keyboard access.

9. **Nested cards/materials reduce hierarchy instead of improving it**
   - Reflection contains a card inside a large card, while the surrounding popover also uses large rounded containers.
   - Audit whether grouping can be expressed through spacing, separators, typography, and system materials instead of repeated gray rounded rectangles.

10. **Primary and secondary actions are not visually differentiated enough**
    - Disabled and secondary buttons often resemble the rest of the gray UI.
    - Use system button roles/styles and accent color intentionally. Keep only one or two visually prominent actions in a view.

11. **Information density is inverted**
    - Explanatory copy and empty/zero states take significant space while History/current metrics are pushed below the fold.
    - Optimize the first visible viewport for the user’s frequent questions: “Is Codex working?”, “Do I need to review anything?”, “How did I spend the wait?”, and “What happened recently?”

12. **AI configuration state needs a user-facing path**
    - A disabled Reflection button plus “AI reflection isn’t configured on this Mac” is a dead end in the UI.
    - If this can happen in the normal app, provide a clear configuration/action path or move setup into Settings. Do not expose shell-environment implementation details in the normal product UI.

## Required computer-use audit

Do not treat this list as exhaustive. Launch the real built app and use computer-use/manual visual inspection to inspect at least these states:

- fresh/no-history state;
- listening/no-review state;
- Needs Review with several items;
- AI suggestion loading/success/error;
- Reflection unconfigured/generating/success/error;
- Last 7 Days with 0, 1, and multiple nonzero categories;
- expanded Productive/Distracted/Unclassified sections;
- expanded History session with many slices;
- Create Rule from an item near the top and near the bottom;
- scrolling the full popover;
- light and dark appearance if supported;
- narrow/long content and truncated titles;
- keyboard navigation and focus visibility.

Record only actionable findings. Do not create a long historical design diary.
