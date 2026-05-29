## Why

VoiceInk's interface is English-only — every user-facing string is a hardcoded literal and the Xcode project ships a single `en` localization. Russian-speaking users (a large share of dictation users) must navigate the app in a non-native language. Adding a Russian UI localization makes the app accessible to them and establishes the i18n infrastructure the project currently lacks, so future languages become incremental rather than greenfield work.

Note: Russian *transcription* already works (`ru` is in `LanguageDictionary`). This change is strictly about the application's **interface language**.

## What Changes

- Introduce localization infrastructure: a String Catalog (`Localizable.xcstrings`) and add `ru` to the project's known regions / localizations (currently only `en` + `Base`).
- Make user-facing strings localizable across SwiftUI views (~355 `Text`, 64 `Button`, 37 `Label`, 24 `Picker`, 23 `TextField`, 17 `Toggle`, 50 `.help`, 15 `alert`, 11 `Section`) and AppKit/menu-bar surfaces (`MenuBarManager`, notifications, `AppDelegate`).
- Externalize strings that aren't auto-extracted: string interpolations, values passed to non-`LocalizedStringKey` APIs, and AppKit strings (via `String(localized:)` / `NSLocalizedString`).
- Provide Russian translations for all extracted keys, including pluralization rules where counts appear (e.g. "N words", "N transcriptions").
- Keep English as the development/base language and default; Russian is selected automatically by macOS system language or via Xcode scheme/app language override.

This change is **non-BREAKING** for existing English users — the base language and all behavior are unchanged.

## Capabilities

### New Capabilities
- `ui-localization`: The app's user-facing interface can be presented in multiple languages, with Russian as the first non-English locale. Covers the localization infrastructure (String Catalog, project regions), the requirement that user-facing strings be localizable rather than hardcoded, locale selection/fallback behavior, and pluralization handling.

### Modified Capabilities
<!-- None — openspec/specs/ is empty; no existing capability requirements change. -->

## Impact

- **Project config**: `VoiceInk.xcodeproj/project.pbxproj` — add `ru` to `knownRegions` and target localizations.
- **New resource**: `VoiceInk/Resources/Localizable.xcstrings` (String Catalog) with `en` (base) + `ru` translations.
- **SwiftUI views** (~85 view files under `VoiceInk/Views/`, `VoiceInk/PowerMode/`, `VoiceInk/Transcription/`, etc.): string literals reviewed; most localize automatically via String Catalog, interpolated/dynamic ones wrapped explicitly.
- **AppKit / non-SwiftUI**: `MenuBarManager.swift`, `AppDelegate.swift`, `Notifications/`, `EmailSupport.swift` — wrap strings with `String(localized:)`.
- **No new third-party dependencies**; uses Apple's built-in String Catalog (Xcode 15+/Swift 5, already on Xcode 16, macOS 14.4+).
- **Out of scope**: localizing transcribed/AI-enhanced *content*, right-to-left layout, and languages beyond Russian (infrastructure makes them easy to add later).
