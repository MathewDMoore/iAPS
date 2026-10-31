# External insulin history and InPen receive-only reader

Status: draft implementation; not installed or validated on pen hardware.

Settings > Extra Features > External insulin / InPen opens a separate, persistent
history for long-acting injections and externally delivered Fiasp. This history is
observation-only. It is never supplied to pump history, oref0, insulin-on-board,
SMB, or automated insulin delivery. The existing Afrezza pathway is preserved.

## What is implemented

- Manual Toujeo U-300 and Fiasp U-100 logging with explicit timestamps, insulin
  identity, source IDs, and durable atomic storage. Units are pen-dial units;
  concentration never multiplies or divides a dose.
- Positive InPen dispense packets are saved as `needsReview`; the user can classify
  them as injection or prime. Negative dispenses remain rewind records.
- A CoreBluetooth history reader discovers the InPen service, reconnects a saved
  peripheral, checks authorization, reads its clock/index and requests up to 80
  recent records. Records have length, CRC and range checks, stable pen-event IDs,
  raw packet provenance, and visible sync/permission/storage errors.
- Versioned JSON export/import with stable IDs and conflict detection. Exports
  include currently retained Afrezza events in labeled cartridge units, never
  converted to injected units. No HealthKit writeback creates an import loop.

## Boundaries that must be visible

**New manufacturer pairing is not implemented.** The reader works only if the pen
accepts this iPhone's existing authorization. It reports a blocking message if
pairing is required. It does not guess advertising offsets, authentication keys,
or pairing commands. Existing OS bonding may or may not suffice for a given pen.
No functioning Bluetooth connection has yet been demonstrated by this change.

Background CoreBluetooth restoration is enabled but not yet hardware tested.
Foreground timer polling is not a promise of minute-by-minute background updates.
Backfill is limited to the latest 80 indices and may time out on missing/invalid
records or a wrapped index. A sync is only marked complete after all requested
records have been received and saved; it is not a full-history recovery guarantee.

PDF reports and screenshots are source evidence, not a machine-readable dose log.
Do not reconstruct exact injection times from chart positions or import summary
averages as doses. Archive original reports separately from active history.

Before combining any external insulin with automated dosing, a separate model,
validation, duplicate reconciliation with pump/HealthKit data, and a fail-safe for
stale/absent pen data are required. This change does not implement that stage.

## MetabolicTwin integration

The shared archive schema is `org.metabolictwin.external-insulin-history`, version
1. `ExternalInsulinRecord.swift` is the Foundation-only format and decoder to reuse.
`ExternalInsulinStore.swift` supplies the observation-only local store; the separate
app must keep it outside dosing recommendations unless independently validated.
Dates use ISO 8601 UTC with one-second precision; raw InPen bytes preserve finer
wire timestamps. Identity is source + device ID + sourceRecordID, with a stable id.
All re-import conflicts abort the entire incoming merge.

MetabolicTwin's accessible repository currently contains a `MetabolicTwin` gitlink,
not the application's Swift source or Xcode project. Its matching import UI and
HealthKit integration therefore remain blocked on access to that nested source.
Do not claim automatic cross-app syncing: the current bridge is a file export/import.
Do not assume ordinary iOS apps share an app sandbox or App Group entitlement.

## Integrating with a newer Mac checkout

This draft is based on the saved `feature/afrezza-support` branch. A newer checkout
may include Siri, Watch and pump work absent from GitHub. Preserve all local work;
apply the additive changes with conflict review. Do not reset to this branch and
never replace the app or local history to make the patch apply.

## Validation

Run `swift test` for parser, checksum, timestamp, archive, deduplication and storage
checks. On macOS the package
also type-checks the CoreBluetooth reader. An actual Xcode app
build, on-device UI check, Bluetooth authorization/pairing, reconnect/background,
prime classification, time accuracy, and duplicate-history tests are still needed.
Never inject extra insulin just to test logging. Use pre-existing records first.

## Protocol references and provenance

Wire field layout follows the existing open-source xDrip+ implementation by
jamorham (GPL-3.0), not a public manufacturer SDK. No manufacturer support for
third-party iAPS access is implied. Retain the repository's GPL license.

- https://github.com/NightscoutFoundation/xDrip/blob/master/app/src/main/java/com/eveningoutpost/dexdrip/insulin/inpen/Constants.java
- https://github.com/NightscoutFoundation/xDrip/blob/master/app/src/main/java/com/eveningoutpost/dexdrip/insulin/inpen/messages/RecordRx.java
- https://github.com/NightscoutFoundation/xDrip/blob/master/app/src/main/java/com/eveningoutpost/dexdrip/insulin/inpen/messages/TimeRx.java
- https://github.com/NightscoutFoundation/xDrip/blob/master/app/src/main/java/com/eveningoutpost/dexdrip/insulin/inpen/InPenService.java

Record fields are big-endian; PEN_TIME, record-index and request bounds are
little-endian. CRC16 uses initial 0xFFFF, polynomial 0x8005, MSB first, covering
bytes 0 through 13. Tests use synthetic fixtures and must not be mistaken for
captured pen validation.
