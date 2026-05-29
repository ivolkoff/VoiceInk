## Context

VoiceInk is a macOS SwiftUI + AppKit menu-bar app (230 Swift files, ~85 SwiftUI views). It has **no localization infrastructure**: `developmentRegion = en`, `knownRegions = (en, Base)`, no `.strings`/`.xcstrings` files, and every user-facing string is a hardcoded literal. Toolchain is Xcode 16 (`objectVersion = 77`, `LastUpgradeCheck = 1600`), Swift 5, macOS deployment 14.4/15.0 — fully supporting Apple's modern **String Catalog** (`.xcstrings`, introduced Xcode 15).

Rough literal inventory in SwiftUI: `Text(` ×355, `Button(` ×64, `.help(` ×50, `Label(` ×37, `Picker(` ×24, `TextField(` ×23, `Toggle(` ×17, `alert(` ×15, `Section(` ×11. Plus AppKit surfaces: `MenuBarManager.swift`, `AppDelegate.swift`, `Notifications/`, `EmailSupport.swift`.

The key leverage: SwiftUI views take `LocalizedStringKey` parameters, so most of these literals are **already localizable** — they get auto-extracted into a String Catalog on build with no code change. The real work is (a) standing up the catalog, (b) catching the literals that *don't* auto-extract, and (c) translating.

## Goals / Non-Goals

**Goals:**
- Stand up reusable i18n infrastructure (String Catalog + project regions) so adding any future language is incremental.
- Ship a complete, correct Russian translation of the interface, including plurals and interpolated strings.
- Zero behavioral/visual change for English users (English stays the base language).

**Non-Goals:**
- Localizing transcribed audio or AI-enhanced *content* (user data, not UI).
- Right-to-left layout support.
- Languages other than Russian (infrastructure enables them; translations are out of scope here).
- Localizing developer-facing strings: log messages, identifiers/keys, URLs, accessibility identifiers used for testing.

## Decisions

### Decision 1: String Catalog (`.xcstrings`) over `.strings`/`.stringsdict`
Use a single `Localizable.xcstrings` in `VoiceInk/Resources/`. Rationale: Xcode auto-extracts SwiftUI/`String(localized:)` literals into it on build, tracks per-string translation state (new/needs-review/translated), and handles plurals inline (replacing the legacy `.stringsdict`). Alternatives: legacy `.strings` + `.stringsdict` (manual, error-prone, no extraction tooling) — rejected; third-party i18n libs — rejected (no dependency justified, native tooling is sufficient).

### Decision 2: English remains base; never hardcode Russian
Keep `developmentRegion = en`; the literal in source stays English and *is* the key. Add `ru` to `knownRegions` and the target. Rationale: keeps diffs minimal, preserves English as a guaranteed fallback, matches Apple's recommended workflow, and means future code keeps writing natural English literals that auto-extract.

### Decision 3: Auto-extraction first, then a manual sweep for the gaps
Phase order: (1) enable catalog + build to auto-populate, (2) manually fix what doesn't extract. Strings that need explicit wrapping with `String(localized:)` / `NSLocalizedString`:
- AppKit strings: `NSMenuItem` titles, `NSAlert`, `UNNotification` content — these take plain `String`, not `LocalizedStringKey`.
- String interpolations and strings stored in `let`/`var` before being passed to a view.
- Strings passed to custom view initializers typed `String` instead of `LocalizedStringKey` (audit custom components; prefer changing the param type to `LocalizedStringKey` where it's a reusable label).
Rationale: minimizes manual edits by letting the compiler/extractor do the bulk, then targeting only true gaps.

### Decision 4: Plurals via String Catalog "Vary by Plural"
For count-bearing strings, use the catalog's automatic-plural variation so Russian's `one/few/many/other` CLDR categories are all provided. Rationale: Russian plurals are non-trivial (1 слово, 2 слова, 5 слов); the catalog enforces all required categories.

### Decision 5: Verification by app-language override
Verify via Xcode scheme "App Language → Russian" (and/or `-AppleLanguages (ru)` launch arg) rather than changing system language. Rationale: fast, isolated, repeatable; lets reviewers spot untranslated (still-English) strings and layout truncation.

## Risks / Trade-offs

- **Missed literals (silent gaps)** → After translating, run with App Language = Russian and visually sweep every screen; additionally grep for residual user-facing literals not in the catalog. Untranslated keys fall back to English (no crash), so the failure mode is visible, not fatal.
- **String concatenation hides grammar** → Interpolated/concatenated strings can produce ungrammatical Russian. Mitigation: convert concatenations into single format strings with positional arguments before translating.
- **UI truncation** (Russian is often longer than English) → Review fixed-width controls/menus during the language sweep; rely on SwiftUI's dynamic layout, flag any clipped labels.
- **`project.pbxproj` merge friction** → Region edits touch the project file; keep them minimal and isolated in one commit.
- **Translation quality/consistency** → Maintain a small glossary for recurring domain terms (e.g. "transcription", "Power Mode", "prompt", "model") so the same Russian term is used everywhere.
- **Non-user-facing strings wrongly extracted** → Mark identifier/log/URL literals as "Don't Translate" in the catalog or keep them out of localized APIs.

## Migration Plan

1. Add `Localizable.xcstrings` to `VoiceInk/Resources/`; add `ru` to `knownRegions` + target localizations.
2. Build → auto-extract base (`en`) keys into the catalog.
3. Sweep AppKit/interpolated/custom-init gaps; wrap with `String(localized:)`; rebuild to extract them.
4. Add Russian translations for all keys; configure plural variations.
5. Verify with App Language = Russian across all screens + menu bar + notifications; confirm English unchanged.
6. Rollback: feature is additive — reverting the commit (and removing `ru` from regions) restores English-only with no data/state migration.

## Open Questions

- Translation source: human translation vs. machine-assisted draft then review? (Affects task effort, not architecture.)
- Should reusable custom view components have their `String` label params widened to `LocalizedStringKey` now (cleaner, slightly larger diff) or be wrapped at call sites? Default: widen where the param is clearly a display label.
