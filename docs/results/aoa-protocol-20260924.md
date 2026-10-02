# Windows AOA protocol receipt — 2026-09-24

Target: Samsung Galaxy S23, SM8550. Host: Windows PowerShell 7.4 or newer.
Probe: `tools/UsbAoa.ps1 -StopAdb` from commit `55eec22` plus the label-only
cleanup committed with this receipt.

The probe stopped the competing adb server, resolved the one present Samsung
ADB WinUSB device interface, opened it with an overlapped file handle,
initialized WinUSB, and issued the Android Open Accessory `GET_PROTOCOL`
control request. The phone returned exactly two bytes encoding protocol
version 2. The WinUSB and file handles then closed. The adb server was restarted
and the device returned to its attached state.

```text
WinUsbInitialize=True
GetProtocolBytes=2
AoaProtocol=2
HandlesClosed=True
AdbRestored=True
Passed=True
```

This proves that the PowerShell-owned Windows negotiation path reaches the
physical phone and that the phone supports AOA protocol 2. It does not prove
accessory-mode re-enumeration, bulk endpoint discovery, the Android accessory
descriptor, or a framed command round trip. The currently installed preview
APK does not advertise the USB accessory attachment action, so those claims
remain gated on the appliance APK integration.
