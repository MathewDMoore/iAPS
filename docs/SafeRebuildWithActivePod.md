# Safe Rebuild With Active DASH Pod

This checklist reduces the chance of UI/pairing confusion when rebuilding while a pod is active.

## Before Rebuild

1. Keep the same app bundle identifier and signing team/profile.
2. Do not delete the app from the phone.
3. Prefer `Run` over uninstall/reinstall.
4. Keep Bluetooth enabled on phone.

## Rebuild Steps

1. In Xcode, select target device and run (`Cmd+R`).
2. Wait for app launch and open Pump settings.
3. Trigger a status read/refresh.

## Expected Result

- Pod remains controllable.
- If Home briefly shows stale pump text, verify control in pump settings first.

## If UI says "No Pod" but control works

1. Force-quit app and reopen.
2. Toggle Bluetooth off/on.
3. Recheck Pump settings status/read.

This is a display mismatch case, not immediate loss of control.

## If control is lost

1. Do not assume delivery stopped; pod may still be delivering.
2. Confirm current delivery state with available clinical-safe checks.
3. Escalate to pod recovery/new pod workflow per your normal safety process.
