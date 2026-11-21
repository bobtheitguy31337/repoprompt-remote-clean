# RepoPrompt Iroh transport spike

This package is the isolated Work item 1 feasibility spike. It exchanges only opaque, four-byte-length-prefixed echo frames and intentionally does **not** import `RepoPromptRemoteProtocol`, implement pairing, route application requests, or integrate a production client.

## Pinned stack

The direct dependencies are exact pins and the complete resolved graph is committed in `rust/Cargo.lock`:

| Component | Pin | Why this API is used |
|---|---:|---|
| Rust | 1.92.0 | Reproducible Apple static libraries; targets are declared in `rust/rust-toolchain.toml`. |
| Iroh | 1.0.3 | `Endpoint::builder`, caller-supplied 32-byte `SecretKey`, authenticated endpoint IDs, ALPN, bidirectional QUIC streams, relay/direct addressing, and connection path snapshots. |
| UniFFI | 0.31.2 | Proc-macro exports, async Swift bindings, C header/modulemap generation, and static-library linkage. |
| Tokio | 1.47.1 | One two-thread runtime owned by the Rust library. |
| zeroize | 1.9.0 | Clears Swift-supplied transient secret buffers after endpoint construction. |

Primary capability references (checked 2026-07-30):

- Iroh 1.0.3 crate and endpoint model: <https://docs.rs/iroh/1.0.3/iroh/>
- Iroh endpoint API: <https://docs.rs/iroh/1.0.3/iroh/endpoint/struct.Endpoint.html>
- Iroh connection/path API: <https://docs.rs/iroh/1.0.3/iroh/endpoint/struct.Connection.html>
- UniFFI Swift bindings: <https://mozilla.github.io/uniffi-rs/latest/swift/overview.html>
- UniFFI Xcode/static-library integration: <https://mozilla.github.io/uniffi-rs/latest/swift/xcode.html>

Iroh authenticates the endpoint ID cryptographically, but application authorization remains the caller's responsibility. This spike exposes the authenticated peer ID and does not treat it as RepoPrompt authorization.

## Security and ownership boundary

- Swift supplies exactly 32 secret bytes to `startEndpoint`; Rust does not generate, serialize, log, or write endpoint keys.
- The harnesses keep test secrets only in memory. To validate identity stability after relaunch, re-enter the same external test value.
- `repoprompt-remote/1` is the only ALPN used by the safe Swift convenience API.
- Frames use a four-byte big-endian length and are rejected before body allocation above 1,048,576 bytes.
- Each connection permits at most eight active bidirectional streams; each endpoint accepts at most sixteen live connections.
- Connect, frame I/O, and idle connections have explicit deadlines; timed-out peers are closed.
- UniFFI cancellation aborts the corresponding spawned runtime task. Endpoint shutdown aborts and awaits the accept task before awaiting Iroh endpoint close; `Drop` is a final abort/close safety net.

Swift remains the future persistence owner; production Keychain storage is deliberately outside Work item 1.

## Build and automated verification

Install the pinned toolchain/targets (rustup also reads `rust/rust-toolchain.toml` when run in that directory), then:

```bash
cargo fmt --manifest-path rust/Cargo.toml --check
cargo clippy --locked --manifest-path rust/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path rust/Cargo.toml
Scripts/build-xcframework.sh --locked
Scripts/verify-xcframework.sh
REPOPROMPT_IROH_USE_LOCAL_ARTIFACT=1 swift test
```

The generated XCFramework is ignored by Git. Normal app and SwiftPM builds download the same checksum-pinned release ZIP used by RepoPrompt CE. Set `REPOPROMPT_IROH_USE_LOCAL_ARTIFACT=1` for `swift test` or `xcodebuild` to use a locally generated framework. The transport CI builds and verifies that framework, and the Simulator job tests the uploaded copy.

The artifact contains:

- macOS arm64 + x86_64
- iOS device arm64
- iOS Simulator arm64 + x86_64
- generated Swift bindings, C headers, modulemaps, and UniFFI checksum guards

`verify-xcframework.sh` fails for a missing architecture, platform declaration, generated API, exported start symbol, header/modulemap, or any filesystem API added to the Rust bridge.

From `repoprompt-ce`:

```bash
swift build --product repoprompt-iroh-spike
swift run repoprompt-iroh-spike --self-test
```

The self-test verifies UniFFI/macOS linkage, deterministic caller-owned identity, authenticated peer ID, 10,000 framed echoes, and oversized-frame rejection.

Generate and build the iOS spike without signing:

```bash
cd ../repoprompt-remote
xcodegen generate --spec Spikes/IrohTransportSpikeIOS/project.yml
xcodebuild -project Spikes/IrohTransportSpikeIOS/IrohTransportSpike.xcodeproj \
  -scheme IrohTransportSpike \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

For a device linkage check, replace the SDK/destination with `iphoneos` and `generic/platform=iOS`. For a signed install, open the standalone project in Xcode, choose an explicit development team and physical device, then record the manual matrix below.

## Harness operation

The macOS listener prints its public endpoint ID and address JSON, never its secret:

```bash
swift run repoprompt-iroh-spike listen --secret-stdin
```

Paste `address_json` into the iOS spike, start the phone from its own 64-hex test secret, connect, and send 1–10,000 opaque echoes. The reverse direction can be exercised by copying the iOS address JSON and running:

```bash
swift run repoprompt-iroh-spike connect \
  --secret-stdin \
  --address '<ios-address-json>' \
  --count 10000
```

The CLI reads the 64-hex secret without echo from an interactive terminal (or as one line on standard input when scripted), so secrets never appear in process arguments or recommended shell history. The iOS field is masked and the inactive scene is covered. Use `--no-relay` / disable the UI relay toggle for direct-only validation. The harness reports Iroh's path snapshot rather than inferring a route from interface names.

For a repeatable Simulator gate, launch the installed standalone spike with the non-secret `--simulator-gate-listen` argument. It generates its secret in Swift memory, disables relay, and atomically writes `Documents/iroh-simulator-gate.json`; that ephemeral file contains only the public endpoint/address and, after connection, authenticated peer/path evidence. Feed the separate macOS test secret through `--secret-stdin`, never a launch argument.

## Manual physical-device/network gate (not automatable here)

Record OS versions, device model, both endpoint IDs, path snapshots, and failure diagnostics for each result:

- [ ] Signed arm64 build installs and starts on a physical iPhone.
- [ ] Trusted Wi-Fi selects a direct path and completes 10,000 echoes.
- [ ] Separate known-capable networks with relay disabled establish internet-direct transport.
- [ ] Direct UDP/addressing is blocked or removed and relay transport completes 10,000 echoes.
- [ ] Foreground/background, Wi-Fi↔cellular, lock/unlock, Mac sleep/wake, and endpoint restart recover cleanly.
- [ ] Re-entering the same Swift-owned test secret after app relaunch/device reboot yields the same endpoint ID.
- [ ] App container/log/crash inspection finds no endpoint secret bytes.

Until every box is signed off, later Iroh protocol, pairing, routing, and production integration work remains blocked.
