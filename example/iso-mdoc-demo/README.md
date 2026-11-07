# Simple ISO mdoc session demo

Open `TuvaliMdocDemo.xcodeproj` in Xcode and select the `TuvaliMdocDemo` scheme. The project uses
the library from this checkout (`../..`). Requires iOS 16 or later; the library remains iOS 13+.
Select your signing team and a physical iPhone for Bluetooth testing.

1. Start an ISO 18013-5 proximity reader that supports mdoc **BLE central-client mode** (the reader
   advertises as a peripheral after scanning the QR). Multipaz Identity Reader is one candidate.
2. On the iPhone, tap **Start ISO mdoc presentation**, allow Bluetooth, and scan the QR with the reader.
3. Review document types, requested fields, retention flags and reader trust.
4. Tap **Send response** to exercise the encrypted response path, or **Decline** to end the
   session without answering. Each further request asks again.
5. Read/share the run log. Repeat with Cancel, Bluetooth off, reader disconnect and no-reader timeout.

The demo sends a bundled, public test mDL, filtered to requested elements, through OpenID4VP's
DeviceResponse builder. Its holder key and credential are test fixtures only. Unsupported document
types are not returned; the demo is a transport/integration harness, not a production wallet.
A reader's normal session termination confirms delivery; it does not prove issuer trust or claim validation.
The Android demo instead sends an errors-only response without a credential.

Reader signatures are shown as unverified by default. Optionally import your reader's trusted root
as a **DER X.509 certificate**, before starting. The root stays in memory for this app run. PEM is
not supported by the importer. Import only a root you intend to trust; reader names on unverified
chains are not verified identities. The demo never sends personal data, including for invalid readers.

The app cancels presentation when backgrounded. Keep both apps in the foreground. The QR changes
on every run. Logs stay in memory (up to 80 entries); use Share log before starting another run.

Build without signing:

```sh
xcodebuild -project example/iso-mdoc-demo/TuvaliMdocDemo.xcodeproj \
  -scheme TuvaliMdocDemo -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Run library tests from the repository root, selecting an installed simulator:

```sh
xcodebuild test -scheme ios-tuvali-library \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The simulator can check UI and builds; Bluetooth interoperability requires real hardware.
See [the ISO review](../../docs/iso-review.md) for findings, measurements and remaining conformance gates.
