## 1. Localization infrastructure

- [x] 1.1 Add `Localizable.xcstrings` String Catalog to `VoiceInk/Resources/` and include it in the app target's resources
- [x] 1.2 Add `ru` to `knownRegions` in `VoiceInk.xcodeproj/project.pbxproj` and to the target's localizations (keep `developmentRegion = en`)
- [x] 1.3 Build the app and confirm SwiftUI literals auto-extract into the catalog with an `en` base value
- [x] 1.4 Add an Xcode scheme option / launch arg (`-AppleLanguages (ru)`) procedure to run the app in Russian for verification

## 2. Audit and externalize string gaps

- [x] 2.1 Audit AppKit/menu-bar surfaces (`MenuBarManager.swift`, `AppDelegate.swift`, `Notifications/`, `EmailSupport.swift`) and wrap user-facing strings with `String(localized:)` / `NSLocalizedString`
- [x] 2.2 Audit interpolated and pre-stored (`let`/`var`) user-facing strings across views; convert to single format strings with positional arguments and wrap them
- [x] 2.3 Audit custom/reusable view components for `String` label params; widen to `LocalizedStringKey` where clearly a display label, or wrap at call sites
  - Widened: `InfoTip`, `PermissionCard`, `ExpandableSettingsRow`, `OnboardingPermission`; wrapped `LocalizedError` descriptions (CloudTranscription, VoiceInkEngine, EnhancementError, PowerModeValidator, CustomCloudModelManager).
  - Deferred (low value / high risk): `SetupCardData` (Metrics setup card, 40+ String props), model/prompt registry descriptions, ~40–148 language names, keyboard-key labels (`Shortcut.swift`). These stay English; documented as follow-up.
- [x] 2.4 Mark non-user-facing literals (identifiers, log messages, URLs, test/accessibility IDs) as "Don't Translate" or keep them out of localized APIs
- [x] 2.5 Rebuild and confirm the newly externalized strings now appear as keys in the catalog

## 3. Russian translation

- [x] 3.1 Create a short glossary for recurring domain terms (transcription, Power Mode, prompt, model, etc.) for consistent Russian terms
- [x] 3.2 Provide Russian translations for all extracted keys in `Localizable.xcstrings`
- [x] 3.3 Configure plural variations ("Vary by Plural") for count-bearing strings with all required Russian CLDR categories (one/few/many/other)
- [x] 3.4 Verify interpolated strings keep correct argument order/formatting in the Russian translations
- [x] 3.5 Mark all translated keys as reviewed/translated in the catalog (no remaining "new"/"needs review" state)

## 4. Verification

- [ ] 4.1 Run with App Language = Russian and sweep every screen (settings, history, Power Mode, onboarding, transcription views) for untranslated or clipped strings — **needs GUI run (procedure in `verification.md`)**
- [ ] 4.2 Verify menu-bar items, notifications, and dialogs display in Russian — **needs GUI run**
- [ ] 4.3 Verify plural strings at counts 1, 2, and 5 render the correct Russian form — **CLDR forms confirmed in compiled `ru.stringsdict`; runtime render needs GUI**
- [ ] 4.4 Verify English (App Language = English) is visually identical to pre-change behavior — **needs GUI run; English is base/unchanged by design**
- [x] 4.5 Grep the codebase for residual user-facing literals not present in the catalog; resolve any found
  - Scanned; resolved the high-value view/error/tooltip set. Remaining residuals are non-UI (logs, shell scripts, prompt seed text), brand names (model providers), key labels, or the deferred items above.
