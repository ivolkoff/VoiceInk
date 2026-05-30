# Building VoiceInk

This guide provides detailed instructions for building VoiceInk from source.

## Prerequisites

Before you begin, ensure you have:
- macOS 14.4 or later
- Xcode (latest version recommended)
- Swift (latest version recommended)
- Git (for cloning repositories)

## Quick Start with Makefile (Recommended)

The easiest way to build VoiceInk is using the included Makefile, which automates the entire build process including building and linking the whisper framework.

### Simple Build Commands

```bash
# Clone the repository
git clone https://github.com/Beingpax/VoiceInk.git
cd VoiceInk

# Build everything (recommended for first-time setup)
make all

# Or for development (build and run)
make dev
```

### Available Makefile Commands

- `make check` or `make healthcheck` - Verify all required tools are installed
- `make whisper` - Clone and build whisper.cpp XCFramework automatically
- `make setup` - Prepare the whisper framework for linking
- `make build` - Build the VoiceInk Xcode project
- `make local` - Build for local use (no Apple Developer certificate needed)
- `make run` - Launch the built VoiceInk app
- `make dev` - Build and run (ideal for development workflow)
- `make all` - Complete build process (default)
- `make clean` - Remove build artifacts and dependencies
- `make help` - Show all available commands

### How the Makefile Helps

The Makefile automatically:
1. **Manages Dependencies**: Creates a dedicated `~/VoiceInk-Dependencies` directory for all external frameworks
2. **Builds Whisper Framework**: Clones whisper.cpp and builds the XCFramework with the correct configuration
3. **Handles Framework Linking**: Sets up the whisper.xcframework in the proper location for Xcode to find
4. **Verifies Prerequisites**: Checks that git, xcodebuild, and swift are installed before building
5. **Streamlines Development**: Provides convenient shortcuts for common development tasks

This approach ensures consistent builds across different machines and eliminates manual framework setup errors.

---

## Building for Local Use (No Apple Developer Certificate)

If you don't have an Apple Developer certificate, use `make local`:

```bash
git clone https://github.com/Beingpax/VoiceInk.git
cd VoiceInk
make local
open ~/Downloads/VoiceInk.app
```

This builds VoiceInk with ad-hoc signing using a separate build configuration (`LocalBuild.xcconfig`) that requires no Apple Developer account.

### How It Works

The `make local` command uses:
- `LocalBuild.xcconfig` to override signing and entitlements settings
- `VoiceInk.local.entitlements` (stripped-down, no CloudKit/keychain groups)
- `LOCAL_BUILD` Swift compilation flag for conditional code paths

Your normal `make all` / `make build` commands are completely unaffected.

### Persistent permissions across rebuilds (`make local-signed`)

`make local` uses **ad-hoc** signing, which generates a *new code identity on
every build*. macOS keys TCC permissions (Accessibility, Input Monitoring) to
that identity, so **every rebuild silently drops the permissions you granted** —
the global hotkeys (e.g. toggle recording) then stop working until you re-grant
Accessibility. Resetting with `tccutil reset Accessibility com.prakashjoshipax.VoiceInk`
and re-adding the app only helps until the next rebuild.

Fix: build with a **stable self-signed certificate** so the code's Designated
Requirement stays pinned to one cert. Then you grant Accessibility **once** and
it survives rebuilds.

```bash
make local-signed                 # builds, re-signs with "VoiceInk Local", installs to /Applications
make run-direct                   # launch it (see "Global hotkeys" below for why not `open`)
```

One-time certificate setup (named `VoiceInk Local`, must be a **Code Signing**
self-signed cert). Either:

- **Keychain Access** → Certificate Assistant → *Create a Certificate…* →
  Name `VoiceInk Local`, Identity Type *Self Signed Root*, Certificate Type
  *Code Signing*, → Create. Or
- **CLI** (note: Homebrew OpenSSL 3.x **requires `-legacy`** for the PKCS#12
  export, otherwise `security import` fails with *"MAC verification failed …
  (wrong password?)"*):

  ```bash
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout key.pem -out cert.pem \
    -subj "/CN=VoiceInk Local" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"
  openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem \
    -name "VoiceInk Local" -out id.p12 -passout pass:vi
  security import id.p12 -k ~/Library/Keychains/login.keychain-db \
    -P vi -A -T /usr/bin/codesign
  ```

Verify the identity exists (a self-signed cert is **not** "valid" by policy, so
use `find-identity` **without** `-v`, and confirm `codesign` accepts it):

```bash
security find-identity -p codesigning | grep "VoiceInk Local"
codesign -dvv ~/Downloads/VoiceInk.app 2>&1 | grep Authority   # → Authority=VoiceInk Local
```

Override the identity name with `make local-signed SIGN_IDENTITY="Your Cert"`.

**Why re-signing happens in two steps** (see `scripts/resign-local.sh`):
`xcodebuild` ignores the cert and falls back to ad-hoc (a self-signed cert is
not policy-valid), so the Makefile re-signs the built `.app` afterward. It signs
the `.local-build` build-products copy **before** `ditto`-ing it to the install
dir, and the script strips Backblaze placeholder symlinks (`.BC.D_*`) that
otherwise break the framework code seal (*"unsealed contents present in the root
directory of an embedded framework"*). The app installs to **`/Applications`** by
default (`LOCAL_INSTALL_DIR`), not `~/Downloads`, because `~/Downloads` is often
under a backup/sync tool (Backblaze) that keeps re-injecting those placeholder
files and can break the signature seal.

### Global hotkeys: launch with `make run-direct`, not `open`

A self-signed (non Developer ID) app has a quirk: when launched through **Launch
Services** (`open`, Finder, Dock), macOS applies **stricter Input Monitoring
enforcement** to the app's `CGEventTap`, so **global hotkeys silently receive no
events** — even when both *Input Monitoring* and *Accessibility* are granted in
System Settings. The tap is created but never fires; nothing logs an error.

Launching the Mach-O binary **directly** bypasses Launch Services and the hotkeys
work:

```bash
make run-direct
# equivalent to: /Applications/VoiceInk.app/Contents/MacOS/VoiceInk
```

The app still appears in the Dock and behaves normally; stdout/stderr go to
`~/Library/Logs/VoiceInk-direct.log`.

Permissions to grant once (System Settings → Privacy & Security):
- **Input Monitoring** — required: the global-shortcut event tap is gated on
  `CGPreflightListenEventAccess()`; without it the tap is never installed.
- **Accessibility** — required: the tap uses `.defaultTap` (interception), and
  capturing the current selection needs it too.

The only real fix that makes `open`/Finder work is signing with a **Developer ID**
certificate + hardened runtime (paid Apple Developer account). For local dev,
`make run-direct` is the workaround.

---

## Troubleshooting: whisper framework build fails

### `No CMAKE_C_COMPILER could be found` / `compiler identification is unknown`

`make whisper` runs whisper.cpp's `build-xcframework.sh`, which cross-compiles
for iOS/visionOS/tvOS with CMake's Xcode generator (`-G Xcode` +
`CMAKE_SYSTEM_NAME=iOS`). On recent Xcode (26.x) an **old CMake cannot identify
the compiler** for those cross-compile slices and the script aborts (it runs
under `set -e`, so the first failing slice kills the whole build). VoiceInk only
needs the macOS slice, but the script builds all platforms.

Two fixes, both required:

1. **Update CMake** (Homebrew ships an old one on some setups; check
   `cmake --version`, and that `which cmake` is the up-to-date one — a stale
   `/usr/local/bin/cmake` can shadow `/opt/homebrew/bin/cmake`):

   ```bash
   brew install cmake     # 4.x
   ```

2. **Force the compiler** so the Xcode generator can identify it. In
   `~/VoiceInk-Dependencies/whisper.cpp/build-xcframework.sh`, add these to the
   `COMMON_CMAKE_ARGS` array (applies to all platform slices):

   ```bash
   -DCMAKE_C_COMPILER=$(xcrun -f clang)
   -DCMAKE_CXX_COMPILER=$(xcrun -f clang++)
   ```

> ⚠️ This patch lives in the **vendored** whisper.cpp clone under
> `~/VoiceInk-Dependencies`, **not** in this repo. `make clean` deletes that
> directory, so after a clean you must re-apply the patch (or re-update CMake)
> before `make whisper` / `make local` will succeed again.

---

## Manual Build Process (Alternative)

If you prefer to build manually or need more control over the build process, follow these steps:

### Building whisper.cpp Framework

1. Clone and build whisper.cpp:
```bash
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
./build-xcframework.sh
```
This will create the XCFramework at `build-apple/whisper.xcframework`.

### Building VoiceInk

1. Clone the VoiceInk repository:
```bash
git clone https://github.com/Beingpax/VoiceInk.git
cd VoiceInk
```

2. Add the whisper.xcframework to your project:
   - Drag and drop `../whisper.cpp/build-apple/whisper.xcframework` into the project navigator, or
   - Add it manually in the "Frameworks, Libraries, and Embedded Content" section of project settings

3. Build and Run
   - Build the project using Cmd+B or Product > Build
   - Run the project using Cmd+R or Product > Run

## Development Setup

1. **Xcode Configuration**
   - Ensure you have the latest Xcode version
   - Install any required Xcode Command Line Tools

2. **Dependencies**
   - The project uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for transcription
   - Ensure the whisper.xcframework is properly linked in your Xcode project
   - Test the whisper.cpp installation independently before proceeding

3. **Building for Development**
   - Use the Debug configuration for development
   - Enable relevant debugging options in Xcode

4. **Testing**
   - Run the test suite before making changes
   - Ensure all tests pass after your modifications

## Troubleshooting

If you encounter any build issues:
1. Clean the build folder (Cmd+Shift+K)
2. Clean the build cache (Cmd+Shift+K twice)
3. Check Xcode and macOS versions
4. Verify all dependencies are properly installed
5. Make sure whisper.xcframework is properly built and linked

For more help, please check the [issues](https://github.com/Beingpax/VoiceInk/issues) section or create a new issue. 