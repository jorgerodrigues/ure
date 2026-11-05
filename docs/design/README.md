# Design

The Paper file [**Ure**](https://app.paper.design/file/01M3XMBQN7WXTGQBWF7QYKP790) is the source of truth for design. Its pages are **Brand**, **Logo**, **macOS 27**, and one page per feature issue, starting with **Watches · W003**. Each feature page ends with an implementation-notes artboard. This note keeps the decisions that affect code. Values marked approximate come from Apple's guidelines and reviews, not from Apple's design kit.

## Brand

The mood is **blued steel**: enamel white, dial black, one deep blue, and one ruby detail. The user approved implementing the Paper palette and design foundations on 4 October 2026. The typography uses the system text styles.

| Role | Name | Light | Dark | Use |
| --- | --- | --- | --- | --- |
| Accent | Blued steel | `#2340B0` | `#5068DB` | `AccentColor`. White text on it passes 4.5:1 in both appearances. |
| Detail | Ruby | `#B3123E` | `#B3123E` | App icon and brand graphics only. Never in app UI. |
| Text | Dial ink | `#111111` | n/a | Brand graphics only. The app uses semantic label colours. |
| Ground | Enamel | `#FFFFFF` | n/a | Brand graphics only. |

- macOS shows the accent only when the user's accent setting is Multicolor. Otherwise the user's choice replaces it.
- Status never depends on colour. Every stage, condition and part state has a text label.
- The app uses SF through the system text styles. It ships no custom fonts.
- The SF licence covers interface mock-ups, not logos. A wordmark needs its own drawn letters.

## App icon

The icon is **Pomme**: a Breguet hand in white on a blued-steel gradient, with a ruby jewel at the pivot. The source is [Ure/AppIcon.icon](../../Ure/AppIcon.icon), an Icon Composer 2 package for Xcode 27. The app target uses it through `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. The accent colour is `AccentColor` in [Ure/Assets.xcassets](../../Ure/Assets.xcassets), set through `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`.

| Group, front to back | Artwork | Settings |
| --- | --- | --- |
| Jewel | `jewel.svg`, ruby disc at the pivot | Glass on, chromatic shadow, translucency 20% |
| Hand | `hand.svg` in white; `hand-dark.svg` in `#7D93F5` for Dark | Glass on, neutral shadow, translucency 10% |
| Dial | `dial.svg`, white disc around the pivot at 12% opacity | No glass, no shadow |
| Background | Linear gradient `#3C58D1` to `#171C70`; near-black navy in Dark | Fill in `icon.json` |

- Keep the layers flat, opaque and crisp-edged. Icon Composer adds the highlights, refraction and shadows.
- Keep the same shapes in every appearance. Change only colour.
- Check the result at 16 and 32 pt, and in Default, Dark, Tinted and Clear.

Render an appearance from the command line:

```sh
"$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool" \
  Ure/AppIcon.icon --export-image --output-file "$HOME/Developer/test-assets/$(git branch --show-current | tr / -)/AppIcon-Default.png" \
  --platform macOS --rendition Default --width 512 --height 512 --scale 2 --design-generation 27
```

Renditions are `Default`, `Dark`, `TintedLight`, `TintedDark`, `ClearLight` and `ClearDark`.

## Screens

Screens follow macOS 27 Golden Gate as closely as possible. Standard SwiftUI controls give most of this without custom code. Don't override them.

The shared code foundation is `Ure/Design/UreLayout.swift` for the Paper window, column and row dimensions, and `RecordHeading` for saved-record titles. System text styles and semantic foreground styles supply typography and colour. `WorkshopSection` owns navigation symbols. Sidebar labels use equal icon slots, the user's accent, and a semibold selected title. Toolbar actions use SF Symbols with their existing accessible labels and menu commands. Editors keep one prominent Save action.

The current Icon Composer layers already match the Pomme v2 vectors in Paper. Keep those source layers and compile their appearances through Xcode. Paper's illustrative layer bounds and dashed guides are not part of the icon artwork.

### Window and sidebar

- Use one main window: sidebar, list, detail. The reference pane collapses like an inspector.
- Every window uses the same corner radius, about 20 pt. A view near a window corner follows its curve (`containerConcentric`). Don't use a fixed radius.
- The sidebar runs edge to edge and full height on a slightly darker background. It doesn't float.
- Sidebar icons are SF Symbols in the accent colour. Use a fixed colour only when it carries meaning.
- The selected sidebar row has a semibold label. The focused list shows an accent fill. An unfocused selection is grey.
- Put nothing important at the bottom of the sidebar.

### Toolbar

- Leading edge: the sidebar toggle, then a short title under 15 characters. Never use the app name. A subtitle is optional, for example "4 open jobs".
- Centre: actions people can customise. They fold into the system overflow menu as the window narrows. Set `visibilityPriority`. Never build an overflow menu by hand.
- Trailing edge: items that always stay visible, such as search and the reference pane toggle.
- Use at most three groups. Use symbols, not words. Keep a text-labelled action apart from symbol actions.
- Use at most one tinted action, such as Save or Done in an editor, on the trailing side. The main window has none.
- Put every toolbar command in a menu too, with a keyboard shortcut where it fits.

### Liquid Glass

- Glass belongs to controls: the toolbar, sidebar controls, popovers and sheets. Never put it on content such as lists, photos, notes or task rows.
- Let content run under the toolbar. The system draws the scroll edge effect. Don't add toolbar backgrounds or tints.
- Mark a custom glass control as interactive. Custom glass controls should be rare.
- People can set glass transparency with a slider. Test both ends of the slider, Reduce Transparency, light and dark, and inactive windows. Inactive windows dim their text and icons.

### Fields you write on

A Rework record page is a page you write on. A fact such as a caliber's beat rate is an in-place field: `FactField` holds its state on top of the W033 `AutosaveField`, and `FactRow` shows it with its label. A fact with a few fixed values, such as a winding, is a `FactPopUp`. The watch, job and part pages reuse them. The design is the "7 Typing" artboard on the Paper page "Rework · Simple", and the values below come from its JSX.

A fact is an 11 pt medium label above a 15 pt value. The value sits in a 32 pt box with an 8 pt corner radius and 8 pt of padding, and the label is indented 8 pt so it lines up with the text. On a page, the facts are outdented by 8 pt so their text lines up with the headings.

The field has six states:

1. At rest, it reads as plain text, with no box and no border. A unit such as "vph" is in the secondary colour.
2. Empty, it shows a quiet prompt, such as "Add lift angle", in tertiary grey like the notes prompt.
3. Pointing at it, a soft fill (`quaternarySystemFill`) and the text cursor say you can type.
4. Typing, the label turns to the accent colour. The box has the text background, a 1 pt accent outline and a 4 pt accent ring at 18%. The 11 pt secondary hint under it says "Saved as you type · Esc undoes this field".
5. Suggesting, the rest of the first match shows in tertiary grey after the typed text. A list under the field shows the library's matching values with a count, such as "Omega · 1 caliber". The first row has the accent fill, and Tab or Return takes it. A click takes any row.
6. Not valid yet, the label and a 1 pt outline turn red. A 12 pt red line with a filled exclamation mark says what to enter, such as "Enter a beat rate above 0 vph."

A pop-up fact shows its value or prompt and an up-and-down chevron in tertiary grey, with the same label and hover fill.

Typing rules:

- A change saves half a second after typing stops, when focus leaves, and before quitting. Esc puts back the field as it was when focus entered it. Undo and Redo go through the window and work after a save. A pop-up choice saves at once and is one Undo step.
- Validation runs when focus leaves. An invalid value stays visible, and the record keeps its last good value. While you correct a flagged field, the message stays until the text is valid.
- Tab and Shift-Tab move to the next and previous typed field in reading order, top to bottom and then left to right. Return in a one-line field moves to the next field. Tab, Return, or the Right Arrow at the end takes the first match.
- Numbers accept what you would write on paper, such as "35", "35mm" and "35,0 mm", and show in the Mac's region format with their unit. `NumberEntry` holds the rules.
- VoiceOver reads the field's label and value. The visible label is hidden from VoiceOver so it is not read twice.

### Pages you write on

The "5 Caliber" artboard sets the page: 40 pt at the top, 56 pt at the sides, 64 pt at the bottom, and 40 pt between sections. The header has a 104 pt photo tile with an 18 pt radius, the 26 pt bold title, and a 15 pt secondary line under it. The facts sit under a hairline in three columns, 32 pt apart, with 20 pt between rows. Each section has a 17 pt bold heading with a 13 pt secondary count or date on the right, from `PageSectionHeading`. List rows are 52 pt with a 32 pt thumbnail, the name at 15 pt, a 13 pt secondary detail and a chevron, between hairlines.

### Type, colour and menus

- Use only the system text styles. Body is 13 pt, Title 1 is 22 pt and Large Title is 26 pt. Nothing goes below 10 pt. macOS has no Dynamic Type.
- Use semantic colours (label, secondary label, separator, window background), not hex values.
- macOS 27 hides menu item icons by default. Give an icon only to a key action, such as New Job.

## Sources

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/): app icons, toolbars, sidebars, materials, color and typography, updated June 2026
- [WWDC26: Modernize your AppKit app](https://developer.apple.com/videos/play/wwdc2026/289/) and [What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/)
- [MacRumors: macOS Golden Gate](https://www.macrumors.com/roundup/macos-27/) and [Six Colors review](https://sixcolors.com/post/2026/09/macos-27-golden-gate-review-bridging-the-tahoe-gap/)
- [Icon Composer](https://developer.apple.com/icon-composer/)
