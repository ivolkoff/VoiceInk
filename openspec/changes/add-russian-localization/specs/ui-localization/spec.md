## ADDED Requirements

### Requirement: Localization infrastructure
The app SHALL provide localization infrastructure based on Apple's String Catalog, with English as the base/development language and Russian as a supported locale. The Xcode project SHALL declare `ru` among its known regions and target localizations, and a `Localizable.xcstrings` catalog SHALL hold the canonical set of localizable keys.

#### Scenario: Project declares Russian locale
- **WHEN** the project is inspected for supported localizations
- **THEN** `ru` is present in the project's known regions and the target's localizations alongside `en`

#### Scenario: String Catalog is the source of keys
- **WHEN** the app is built
- **THEN** user-facing string literals are extracted into `Localizable.xcstrings` and each extracted key has an `en` (base) value and a `ru` translation

### Requirement: User-facing strings are localizable
All user-facing strings SHALL be localizable rather than hardcoded English literals. This covers SwiftUI text surfaces (`Text`, `Button`, `Label`, `Toggle`, `Picker`, `Section`, `TextField` prompts, `.help`, `.navigationTitle`, alerts) and AppKit/menu-bar surfaces (menu items, notification titles/bodies, dialogs). Strings built via interpolation or passed to non-`LocalizedStringKey` APIs SHALL be wrapped with `String(localized:)` (or `NSLocalizedString`) so they are extracted.

#### Scenario: SwiftUI literal is localized
- **WHEN** a SwiftUI view renders a string that has a Russian translation in the catalog and the app language is Russian
- **THEN** the Russian translation is displayed instead of the English literal

#### Scenario: Interpolated/AppKit string is localized
- **WHEN** the app shows a menu item, notification, or interpolated string under Russian language
- **THEN** the string resolves through the String Catalog and displays its Russian translation

#### Scenario: No user-facing literal is left unlocalized
- **WHEN** the codebase is audited for user-facing string literals
- **THEN** each such literal is either present as a key in the String Catalog or explicitly excluded as non-user-facing (e.g. identifiers, log messages, URLs)

### Requirement: Locale selection and fallback
The app SHALL select the display language from the macOS system/app language setting and SHALL fall back to English for any key without a Russian translation, without crashing or showing an empty string.

#### Scenario: System language drives UI language
- **WHEN** the macOS system (or per-app) language is Russian
- **THEN** the app launches with its interface in Russian

#### Scenario: Fallback to English
- **WHEN** a key has no Russian translation in the catalog and the app language is Russian
- **THEN** the app displays the English base value for that key

#### Scenario: English users are unaffected
- **WHEN** the app language is English
- **THEN** all interface strings are identical to the pre-change English text

### Requirement: Pluralization and dynamic values
Strings that vary by count SHALL use the String Catalog's pluralization (CLDR plural categories), so Russian plural forms render correctly, and strings with interpolated values SHALL preserve argument order and formatting across languages.

#### Scenario: Count-based plural in Russian
- **WHEN** a count-based string (e.g. number of words or transcriptions) is shown under Russian language for counts triggering different plural categories (1, 2, 5)
- **THEN** the correct Russian plural form is displayed for each count

#### Scenario: Interpolated value placement
- **WHEN** a string with an interpolated value is shown under Russian language
- **THEN** the interpolated value appears in the position required by Russian grammar with correct formatting
