# Comms

A minimalist messaging app for macOS and iOS that looks and feels like Apple Messages and brings every channel into one place: WhatsApp, Telegram, Discord, Messenger and X through the Matrix bridges, iMessage and SMS through BlueBubbles, and email. An optional agent (Omni) is one tap away for drafting replies.

Comms is a thin native client of a [Prism](https://github.com/omniharmonic/prism) server: the server's `comms` module holds the bridges, the message store and every send; the app never talks to a network directly and never holds a vault token.

## Requirements

- macOS 26 with Xcode 26 (Swift 6.2). iOS 26 for the phone app.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- A checkout of Prism for its `swift/PrismKit` package (published in the public Prism repository from the snapshot after Prism PR 208; until then, build against a Prism source tree that has `swift/PrismKit`).
- To use the app: a Prism server with `COMMS_ENABLED=true` (see Prism's `docs/onboarding.md`). Without one, the apps run in demo mode on built-in fixtures.

## Build

Comms depends on PrismKit, which lives inside the Prism repository (`swift/PrismKit`). Swift Package Manager can only fetch a package whose manifest is at a repository's root, so PrismKit is a local path dependency. Clone both repositories side by side:

```sh
git clone https://github.com/omniharmonic/prism.git
git clone https://github.com/omniharmonic/comms-oss.git comms
cd comms
```

`CommsKit/Package.swift` looks for `../prism/swift/PrismKit` by default. To use a checkout elsewhere, set `PRISMKIT_PATH` to its `swift/PrismKit` directory (an absolute path, or relative to `CommsKit/`) before building:

```sh
export PRISMKIT_PATH=/path/to/prism/swift/PrismKit
```

Then:

```sh
# The shared package: models, transport, UI and tests
cd CommsKit && swift build && swift test

# The apps (regenerate the Xcode project after editing Apps/project.yml)
Apps/generate-project.sh
open Apps/Comms.xcodeproj   # schemes: CommsMac, CommsiOS, CommsGallery
```

Before signing, set your own identity in `Apps/project.yml` (then regenerate the project):

- `DEVELOPMENT_TEAM`: your Apple team id (empty by default).
- `PRODUCT_BUNDLE_IDENTIFIER`: the bundle ids default to `com.example.comms*`; change them to an id you own. The Keychain service name in `CommsKit/Sources/CommsCore/TokenStorage.swift` follows the bundle id.
- The server's `COMMS_APNS_TOPIC` must equal the app's bundle id for push notifications. Push needs your own APNs key on your Prism server.

The default server shown on the sign-in screen is `https://prism.example.com` (`CommsUI/RootView.swift`); type your own server's address there.

## Layout

- `Apps/`: XcodeGen spec, the macOS and iOS app targets, UI tests and a design gallery app.
- `CommsKit/`: the Swift package. `CommsCore` (state, sync, sending), `CommsUI` (SwiftUI views), `CommsTestSupport` (a fixture backend with fictional data, also used by demo mode).
- `design/tokens.json`: bubble geometry, spacing and colours; `scripts/gen-tokens.swift` generates `CommsUI/Tokens.swift` from it. `design/CALIBRATION.md` records where each value came from.
- `docs/`: [PRD](docs/PRD.md), [architecture](docs/ARCHITECTURE.md), [decisions](docs/DECISIONS.md) and research notes. They were written for one person's install and mention it in places.

Some code comments point at design reference captures (`design/fidelity`, `design/refs`, `docs/research/refs`) that are not part of this repository; tests that write or read them run only when asked (`RECORD_SNAPSHOTS=1`, `RENDER_COMPARISON=1`).

## Licence

Comms is free software: you can redistribute it and/or modify it under the terms of the **GNU Affero General Public License, version 3** (AGPL-3.0-only) as published by the Free Software Foundation. See [`LICENSE`](LICENSE) for the full text.

Copyright (C) 2026 the Comms contributors.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.

Third-party material:

- Network marks are transcribed from [Simple Icons](https://github.com/simple-icons/simple-icons) (CC0 1.0); the marks are trademarks of their owners and are used only to show which network a conversation is on. See `CommsKit/Sources/CommsUI/List/NetworkMarks-LICENSE.md`.
- PrismKit (from Prism) is AGPL-3.0-only.
