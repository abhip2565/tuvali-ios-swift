# ISO mdoc review — 25 October 2026

Scope: `Sources/ios-tuvali-library/iso`, the async BLE implementation it uses, existing ISO
vectors/tests, and the new standalone demo. The legacy OpenID4VP path was outside this review.
This is a source review and simulator validation, not an ISO certification or independent audit.

## Findings addressed

| Priority | Finding | Change and regression coverage |
| --- | --- | --- |
| High | Notifications accumulated without a limit while the holder was deciding. The 1 MiB chunker limit did not protect that upstream queue. | Limit backlog to 4,096 notifications. Overflow ends the stream with an error and closes the connection instead of dropping protocol fragments silently. `AsyncGattClientNotificationsTests.testNotificationFloodFailsClosedWithoutSilentlyDroppingParts`. |
| Medium | Reader authentication ignored critical COSE headers and accepted a label in both header buckets. | Reject duplicate buckets, misplaced `crit`, unsupported/missing critical labels, invalid labels and duplicate critical labels. Validate label types before hashing them. `ReaderAuthenticatorTests`. |
| Medium | SwiftCBOR accepts nested indefinite string chunks and reserved two-byte simple values; composite map-key hashing depends on dictionary iteration order. | Preflight rejects these inputs before decoding. Arbitrary extension map keys are accepted. Duplicate keys are compared using stable fingerprints before dependency dictionary construction, including composite keys whose internal map order differs. Existing duplicate-key, trailing-data and depth checks remain. Total encoded input is limited to 1 MiB. `CborDecodingTests`. |
| Medium | DER parsing accepted non-minimal lengths/OID arcs and repeated certificate extensions; Foundation can normalize impossible calendar dates. | Require minimal encodings, unique extensions, a single extensions wrapper, valid critical flags/KeyUsage bits and dates that round-trip exactly. `ReaderCertificateTests`, including mutated certificate regressions. |
| Medium | Arbitrary certificate counts/sizes increased parsing and trust-evaluation work. | Reader `x5chain` limited to 1–8 certificates, each at most 64 KiB. `ReaderAuthenticatorTests.testRejectsExcessiveCertificateChains`. |
| Medium | A reader's status 10/11 after a response was counted as successful completion. | Expose a dedicated `readerReportedError(status:)` failure; only normal termination is confirmation. Android reports `READER_REPORTED_ERROR`, with the status in its detail. `MdocPresenterTests.testReaderErrorAfterResponseIsNotReportedAsSuccess`. |
| Medium | NaN/infinite/oversized configured timeouts could trap when converted to nanoseconds. | Reject invalid options before opening Bluetooth; internal timeout helper validates its argument too. Positive public timeouts are limited to one year. `MdocPresenterTests.testRejectsInvalidTimeoutsBeforeOpeningBluetooth`. |
| Low | Logging the entire presentation result could publish arbitrary wallet callback error text. | Log completion without its error detail; callers still receive the result and detail. |

## Security boundaries checked

- Fresh P-256 engagement key and service UUID per presentation. CryptoKit checks the reader's
  ephemeral point before ECDH. HKDF derivation and AES-GCM direction identifiers/counters match
  the existing independent session vectors. Counters are never reused after successful encryption;
  overflow fails; authentication failure ends the presentation.
- Transcript, reader key and ItemsRequest bytes used for signatures are preserved as received.
  ECDSA verification is delegated to CryptoKit, and trust-path evaluation to Security.framework.
  The handwritten DER reader extracts fields; it does not implement chain-signature verification.
- `.verified` requires a valid reader signature and a path to configured reader roots. No roots
  means `.unverified`, even for a valid signature. Network certificate fetching is disabled.
  No trust decision automatically authorizes disclosure: every request reaches the wallet callback.
- Cleanup closes transport and invalidates ephemeral/session keys on normal completion, decline,
  cancellation, timeout and failure. CryptoKit private keys are released, not provably zeroized.
  Array wiping cannot guarantee erasure of all copies previously made by Swift/CryptoKit.

## Performance and reliability

Measured on the local Apple Silicon iPhone 17 Pro simulator, iOS 26.5, Xcode 26.6, **Debug**,
10 XCTest measurement iterations. These are diagnostic CPU timings, not physical BLE throughput
or release-device latency guarantees. Tests live in `IsoPerformanceTests.swift`.

| Workload | Approximate mean |
| --- | --- |
| Decode a 1,000-entry request-shaped map | 3.6 ms per decode (10 decodes per sample) |
| Parse the test root certificate | 0.050 ms per parse (100 parses per sample) |
| Reassemble 64 KiB at 20-byte ATT values | 1.6 ms per message |

The CBOR preflight is iterative and bounded to 64 open containers; decoding and duplicate counting
perform additional passes. Outbound map encoding sorts labels and allocates intermediate arrays.
These are reasonable for small mdoc requests; the timings above do not justify replacing them.
BLE sending currently materializes all chunks, so memory scales with the outgoing response size.
The notification limit is a backlog limit: a legitimate large burst with a slow consumer may also
close the connection. The benchmark measures certificate parsing, not full `SecTrust` evaluation.

The final simulator run passed **368 tests**, up from the 344-test baseline. Android ISO tests passed **262 tests** after the selected parity fixes. The demo built for
both iOS Simulator and generic physical iOS (unsigned). Its initial screen was launched and
visually checked. Existing non-ISO compiler warnings were left outside scope.

## Remaining test gates and limitations

- Run real Bluetooth interoperability on an iPhone and a compatible reader. Simulator/mocked
  GATT tests cannot prove MTU behavior, radio performance, permissions, reader timing or reconnects.
- The demo follows Android: no credential store, no issuer credential, no device signature.
  It sends version 1.0/status 0 with document error 0 (data not returned) for each requested type.
  This supports session testing, not successful signed mDL disclosure/verification.
- QR engagement/BLE central-client mode only. No NFC, BLE peripheral mode, Wi-Fi Aware or full
  second-edition request semantics. Minor request versions are tolerated; `readerAuthAll` and
  `documentSets` are not implemented. EdDSA/brainpool reader keys are unsupported.
- Revocation, trust-list distribution and a complete Annex B certificate-profile assessment remain
  application/conformance work. KU/EKU restrictions are checked when present, matching Android;
  their absence is currently permitted. Reader names on unverified chains are untrusted claims.
- Callbacks and transports must cooperate with cancellation. Structured timeout groups wait for
  their child to finish; an uncooperative callback can delay cleanup beyond the nominal timeout.
- Resource limits are deliberate interoperability limits. Arbitrary extension-map keys are now accepted;
  the dependency still does not support encoding Float16 values, so internal comparison fingerprints
  preserve half-float keys separately instead of using its lossy encoder.

## Local standard review and selected follow-up fixes

Read the locally licensed ISO/IEC 18013-5:2021, including the relevant tables visually. Scratch
probes of both platforms matched Annex D.5.1 SKReader, SKDevice, request decryption and response
encryption byte for byte. No licensed PDF or extracted standard text is included in this repository.

Selected fixes completed on both platforms:

- Clause 8.1 numeric `major.minor` syntax is validated. Known major/unknown numeric minor is
  accepted without limiting the minor component to machine-integer size.
- Swift accepts ignorable `requestInfo` containing arbitrary nested keys while preserving the
  original ItemsRequest bytes for signatures. Duplicate composite keys are rejected before hashing.
- Reader statuses 10/11 have a dedicated remote-error result, including after a response was sent;
  normal status 20 and BLE End retain their completion behavior. Cleanup does not send another status.

Corrections to earlier conformance assumptions: duplicate map keys are prohibited by 8.1, not an
optional stricter rule. B.1.7/Table B.6 is a recommended reader-certificate profile. Table 22 requires
all curves for readers, not holders; QR/BLE central-client-only holder support is permitted.

Unselected findings remain open on Android: unbounded notification buffering, COSE critical-header
validation, truncating status/algorithm conversions, trailing certificate bytes and permissive ECDSA
raw-signature lengths. Both platforms still need an IACA-specific country/state validation policy
and revocation-information handling for a full certificate-validation claim. No new work on those
unselected findings was included in this follow-up.

## Protocol references

- ISO/IEC 18013-5:2021: engagement/session/reader-authentication clauses referenced in source
  comments and shared Android vectors. The subsequent local licensed-document review checked the implemented QR/BLE holder scope; this remains short of a full conformance certification.
- [RFC 8949](https://www.rfc-editor.org/rfc/rfc8949.html): CBOR well-formedness and indefinite strings.
- [RFC 9052 §3](https://www.rfc-editor.org/rfc/rfc9052.html#section-3): COSE headers and critical labels.
- [RFC 5280 §4.2](https://www.rfc-editor.org/rfc/rfc5280.html#section-4.2): unique certificate extensions.
- [Multipaz reader-certificate generator](https://developer.multipaz.org/kdocs/multipaz/org.multipaz.mdoc.util/-mdoc-util/generate-reader-certificate.html): Annex B.1.7 profile reference for subsequent interoperability checks.
