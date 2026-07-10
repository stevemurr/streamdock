# StreamDock for macOS

The native macOS 14+ application is the primary StreamDock editor and runtime.
It is a SwiftUI application with a reusable `StreamDockCore` package containing
configuration migration, action execution, key rendering, and the IOHID driver.

## Open and run

1. Install the full Xcode application.
2. Open `StreamDock.xcodeproj`.
3. Select the `StreamDock` scheme and run it on **My Mac**.

The target intentionally enables the hardened runtime and disables App Sandbox.
Arbitrary user-authored Python and shell execution, user-selected scripts, and
direct HID access are core product features and are not compatible with a normal
Mac App Store sandbox.

The app imports the first existing configuration it finds under
`~/.config/streamdock/`, then writes its versioned native configuration to:

```text
~/Library/Application Support/StreamDock/config.yaml
```

## Environment secrets

Keys, commands, and scripts frequently need tokens (`HA_TOKEN`, `OPENAI_API_KEY`,
…). Open **Secrets** from the editor toolbar (the key icon) or the menu-bar
item to manage them. Each secret is a `NAME`/`VALUE` pair that is injected into
the environment of every action the deck runs, so commands reference `$NAME`
instead of hardcoding the value.

Secrets are encrypted at rest with **AES-GCM**; the 256-bit key lives in the
login Keychain, and the ciphertext is written to
`~/Library/Application Support/StreamDock/secrets.dat` (never in the config
YAML). You can **import** an existing `.env` file into the store or **export**
the store back to a `.env`. At runtime, precedence is
login-shell environment → secrets → `env_file` → per-action environment, so a
per-key override always wins.

## Command-line verification

The core and SwiftUI executable can be compiled without launching the app:

```bash
swift build --target StreamDockApp
swift run StreamDockCoreChecks
```

The XCTest suite under `Tests/` is available when the project is built with a
full Xcode installation.
