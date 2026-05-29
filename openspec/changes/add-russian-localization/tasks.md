## 1. Localization infrastructure

- [ ] 1.1 Add `Localizable.xcstrings` String Catalog to `VoiceInk/Resources/` and include it in the app target's resources
- [ ] 1.2 Add `ru` to `knownRegions` in `VoiceInk.xcodeproj/project.pbxproj` and to the target's localizations (keep `developmentRegion = en`)
- [ ] 1.3 Build the app and confirm SwiftUI literals auto-extract into the catalog with an `en` base value
- [ ] 1.4 Add an Xcode scheme option / launch arg (`-AppleLanguages (ru)`) procedure to run the app in Russian for verification

## 2. Audit and externalize string gaps

- [ ] 2.1 Audit AppKit/menu-bar surfaces (`MenuBarManager.swift`, `AppDelegate.swift`, `Notifications/`, `EmailSupport.swift`) and wrap user-facing strings with `String(localized:)` / `NSLocalizedString`
- [ ] 2.2 Audit interpolated and pre-stored (`let`/`var`) user-facing strings across views; convert to single format strings with positional arguments and wrap them
- [ ] 2.3 Audit custom/reusable view components for `String` label params; widen to `LocalizedStringKey` where clearly a display label, or wrap at call sites
- [ ] 2.4 Mark non-user-facing literals (identifiers, log messages, URLs, test/accessibility IDs) as "Don't Translate" or keep them out of localized APIs
- [ ] 2.5 Rebuild and confirm the newly externalized strings now appear as keys in the catalog

## 3. Russian translation

- [ ] 3.1 Create a short glossary for recurring domain terms (transcription, Power Mode, prompt, model, etc.) for consistent Russian terms
- [ ] 3.2 Provide Russian translations for all extracted keys in `Localizable.xcstrings`
- [ ] 3.3 Configure plural variations ("Vary by Plural") for count-bearing strings with all required Russian CLDR categories (one/few/many/other)
- [ ] 3.4 Verify interpolated strings keep correct argument order/formatting in the Russian translations
- [ ] 3.5 Mark all translated keys as reviewed/translated in the catalog (no remaining "new"/"needs review" state)

## 4. Verification

- [ ] 4.1 Run with App Language = Russian and sweep every screen (settings, history, Power Mode, onboarding, transcription views) for untranslated or clipped strings
- [ ] 4.2 Verify menu-bar items, notifications, and dialogs display in Russian
- [ ] 4.3 Verify plural strings at counts 1, 2, and 5 render the correct Russian form
- [ ] 4.4 Verify English (App Language = English) is visually identical to pre-change behavior
- [ ] 4.5 Grep the codebase for residual user-facing literals not present in the catalog; resolve any found
