# Issue Triage — 2026-08-29

Repo: `stevelea/xpcardata`. Analysis date: 2026-08-29. Working tree at `v1.4.24`.

## Summary

8 open issues, 6 closed. Two open issues have confirmed or strongly-evidenced
root causes and are actionable now (#14, #12). The rest are enhancement or
distribution items.

## P0 — #14: "Package conflict" on in-app update

**Root cause (confirmed via `apksigner --print-certs`):** the APK signing
identity changed at v1.4.23.

| Version range | Signing certificate (DN) | SHA-256 |
|---------------|--------------------------|---------|
| ≤ v1.2.5      | `CN=Android Debug, O=Android, C=US` | `a5b4df0d…` |
| v1.3.86 – v1.4.22 | `CN=Android Debug, O=Android, C=US` | `96e79bed…` |
| v1.4.23 – v1.4.24 | `CN=Steve Lea, OU=XPCarData…` | `9d1330ec…` |

The v1.4.23 commit ("Add release signing with permanent keystore") was the
intended migration away from machine-specific debug keys. Side effect: every
device running ≤ v1.4.22 is signed with a debug key and Android refuses an
in-place update to a release-signed APK ("conflict with a package").

**Action:** one-time uninstall/reinstall for affected users. Communicate
prominently (release notes + issue #14 comment). No code fix possible. Lock the
keystore (already gitignored) and confirm the off-repo backup exists.

## P1 — #12: WiCAN byte-order gaps in cell-voltage parsing

**Root cause (confirmed against WiCAN firmware source):** the two parsers use
different byte-buffer layouts, so community-profile `B` offsets misalign.

WiCAN's `parse_elm327_response()` (`main/autopid.c`) builds its `data[]` buffer
by splitting the ELM327 response on `\r\n`, stripping **only the per-frame CAN
ID**, and concatenating every remaining byte verbatim — including the ISO-TP
first-frame PCI byte (`10`), the length byte, the service byte (`62`), the PID
echo (`01 02`), and the consecutive-frame **sequence bytes** (`21`, `22`, `23`,
`24`…). Its `expression_parser.c` then evaluates `B0`, `B1`, `[B4:B5]` against
that raw buffer.

This is exactly why WiCAN profiles skip B16/B24/B32/B40 — those are the inline
sequence bytes — and why the first cell voltage lands at B10. Confirmed by
mapping the reporter's `620102FFFFFFFFC2C2…` trace onto the firmware layout
(6+7+7+7+5 = 32 cells, gaps at every 8th byte).

XPCarData's `parseWithFormula()` strips differently: it removes only the
**first** 3-nibble CAN header, and its multi-frame branch targets the `ATCAF1`
format (`0:`, `1:`, `2:` prefixes). The app initializes with `ATH1` (headers
on), not `ATCAF1`, so the remaining `784 21 …` / `784 22 …` headers and sequence
bytes stay embedded in the stream and get misparsed as data.

**Fix direction:** replicate WiCAN's `parse_elm327_response` byte-for-byte in
`parseWithFormula` (strip CAN ID per frame, keep PCI/length/sequence bytes).
Posted diagnosis to #12 requesting a raw `[OBD Traffic]` TX/RX block for
`220102` to lock exact offsets for the reporter's car before patching.

Caller map (grep `parseWithFormula` vs `parseCellVoltages`):

- Built-in single-frame BMS/VCU PIDs (≈40) → `parseWithFormula`. Correct for
  single-frame; unaffected by the multi-frame bug.
- Built-in cell PIDs `221122` / `221123` → `getParserForType(…cellVoltages…)` →
  dedicated multi-frame path. Correct.
- **All WiCAN community profiles** (`vehicle_profile_service.dart:68`) →
  `parseWithFormula(response, formula)`. This is the broken path: Kia/Hyundai
  multi-signal/cell PIDs (e.g. `220102` with 32 cell voltages) are multi-frame
  and hit the generic branch that cannot strip ISO-TP framing under `ATH1`.
- Custom JSON PIDs (`obd_pid_config.dart` `fromJson`) → `parseWithFormula` if a
  formula is present, else `getParserForType`. Same exposure.

**Fix direction:** route multi-frame PIDs through a single header-aware cleaner
(the `784`-split approach already in `parseCellVoltages`), and make WiCAN
formula indexing consistent with it. Need a raw `[OBD Traffic]` TX/RX trace for
`220102` from the reporter as a deterministic test fixture before patching.

## P1 — #13: `obd_pids.json` not findable

**Root cause (confirmed):** `obd_pid_config_screen.dart` writes `obd_pids.json`
to `getApplicationDocumentsDirectory()` (private app sandbox), with a hardcoded
`/data/data/com.example.carsoc/files/obd_pids.json` fallback when path_provider
fails. Both are private internal storage — not the `Card/Phone/Android/data/…`
external folders the reporter browsed, which the app never uses (hence empty).
Non-rooted file managers cannot reach `/data/data/…`; only `adb`/root can.

**Action taken:** posted explanation to #13 — file is present and working, the
reporter was looking in the wrong (external) directory. Pointed to the in-app
**+ Add Custom PID** button and the Backup → Share path as the supported ways to
add/export PIDs.

**Proposed fix (not yet implemented):** mirror `obd_pids.json` into the
app-specific external folder (`Android/data/com.example.carsoc/files/`) and/or
add an explicit "Export PIDs" button on the PID configuration screen.

## P2 — #10: MQTT + Tailscale connection flakiness

Intermittent; likely a watchdog/keepalive gap rather than a parser bug. Needs
reproduction with debug log.

## P2 — #6: Multisignal PID optimization

Kia/Hyundai PIDs pack ~20 values into one PID; app re-requests per value. Valid
performance enhancement, no correctness risk.

## P2 — #3: Unknown HA entities / charge-port state

Partially resolved (IEC 61851 status codes landed v1.4.5). Remaining gap is
State B/C (port-connected vs charging) detection.

## P3 — #2: current-vs-historical indicator

Effectively done via `last_collected` attribute (also closed #4). Just close.

## P3 — #15: Play Store release

Distribution decision, not a defect.

## Closed (verified fixed)

#4 last_collected → v1.4.16; #5 parser `\r` → v1.4.23; #8/#9 profile
export/MQTT → v1.4.21–22; #11 2026 G6 odometer → v1.4.18; #7 brand config.
