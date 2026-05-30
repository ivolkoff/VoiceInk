# Running VoiceInk in Russian (verification procedure)

The shared scheme keeps the system language so normal development is unaffected.
To verify the Russian localization, force the app language at launch — no scheme
edit required.

## Option A — launch the built binary with an app-language override (preferred, CLI)

```bash
# Build once (Debug, no signing needed for local run):
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk \
  -destination 'platform=macOS' -derivedDataPath /tmp/vi_dd \
  build CODE_SIGNING_ALLOWED=NO

# Launch in Russian:
/tmp/vi_dd/Build/Products/Debug/VoiceInk.app/Contents/MacOS/VoiceInk \
  -AppleLanguages '(ru)' -AppleLocale ru_RU

# Launch in English (baseline comparison):
/tmp/vi_dd/Build/Products/Debug/VoiceInk.app/Contents/MacOS/VoiceInk \
  -AppleLanguages '(en)' -AppleLocale en_US
```

## Option B — Xcode scheme (interactive)

Edit Scheme → Run → Options → App Language → **Russian** (revert to *System Language*
when done). Do **not** commit this change to `VoiceInk.xcscheme`.

## Re-extracting / re-syncing the catalog after source edits

The string catalog is populated by building, then syncing the compiler-extracted
`.stringsdata` into the source `.xcstrings`:

```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk \
  -destination 'platform=macOS' -derivedDataPath /tmp/vi_dd \
  build CODE_SIGNING_ALLOWED=NO

# zsh array (zsh does NOT word-split unquoted vars):
args=(); while IFS= read -r f; do args+=(--stringsdata "$f"); done \
  < <(find /tmp/vi_dd -path '*VoiceInk.build*' -name '*.stringsdata')
xcrun xcstringstool sync VoiceInk/Resources/Localizable.xcstrings "${args[@]}"
```

`xcstringstool print VoiceInk/Resources/Localizable.xcstrings` lists every key.
