# iOS Developer Toolkit (Swift)

<p align="center">
  <img src="App/iOSDeveloperToolkit/Assets.xcassets/Logo.imageset/logo.png" width="200" alt="iOS Developer Toolkit (Swift) logo">
</p>

**A native macOS app for working with iPhones, iPads, and simulators — device information, live logs, location simulation, app installs, backups, packet capture, readiness checks, documented evidence collection, and local security analysis.**

[![CI](https://github.com/hideouts-io/iOS-Developer-Toolkit-Swift/actions/workflows/ci.yml/badge.svg)](https://github.com/hideouts-io/iOS-Developer-Toolkit-Swift/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/hideouts-io/iOS-Developer-Toolkit-Swift?display_name=tag)](https://github.com/hideouts-io/iOS-Developer-Toolkit-Swift/releases/latest)
![Platform](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
[![License](https://img.shields.io/badge/license-MIT-2da44e)](LICENSE)

![Overview](docs/screenshots/overview.png)

iOS Developer Toolkit is written in Swift and SwiftUI. It talks to devices through macOS's own
device service (usbmuxd and lockdown), Xcode's CoreDevice service (`devicectl`), `simctl`, and
Instruments. It needs no Python, no Homebrew packages, and no administrator rights.

> **Scope.** This is a tool for devices you own or are authorized to examine. It does not
> jailbreak iOS, bypass a passcode, disable the sandbox, defeat code signing, decrypt protected
> traffic, or provide unrestricted file-system access.

## Contents

- [What it does](#what-it-does)
- [Screenshots](#screenshots)
- [Requirements](#requirements)
- [Install](#install)
- [First steps](#first-steps)
- [Workspaces](#workspaces)
- [Developer images](#developer-images)
- [Firmware](#firmware)
- [Command-line tool](#command-line-tool)
- [Security and privacy](#security-and-privacy)
- [Troubleshooting](#troubleshooting)
- [Build from source](#build-from-source)
- [Project status and limitations](#project-status-and-limitations)
- [Contributing, support, and license](#contributing-support-and-license)

## What it does

| Area | What you get |
|---|---|
| **Devices** | Automatic discovery of USB and Wi-Fi–synced devices (event-driven, no polling), Xcode-paired network devices, and simulators — shown in separate *Physical Devices* and *Simulators* sections. |
| **Plain-language device details** | Name, model, hardware identifier, UDID, iOS version and build, architecture, connection, trust, Developer Mode, and developer-service status, each with an explanation. Identifying values stay hidden until you choose to show them. |
| **Readiness Check** | A read-only check of every prerequisite (Xcode, the macOS device service, connection, trust, Developer Mode, Xcode's device service, developer services, Instruments, lock state, logging and backup services, Safari Web Inspector) with a next step for anything not ready. |
| **Live Logs** | Unified Logging and classic syslog streamed from physical devices, and the simulator's unified log; plus two collected sources: an **OSLog archive** (the device's saved log history for a time window, kept as a `.logarchive` for Console) and **DVT logging** (os_log recorded through Instruments, kept as a `.trace`). Every byte is spooled and hashed; the view can be paused and filtered (literal or regex) without affecting capture. Mark findings, then export the raw capture, filtered lines, or an evidence bundle. |
| **Location Lab** | Set a coordinate (offline world map, map-link parsing, nudges, saved places), move along a route at constant speed, or replay a GPX track. Always clearable; every change is logged. |
| **Firmware** | Apple's firmware (IPSW) for the connected model; resumable downloads with catalog SHA-1 comparison when available; a local library; recovery and DFU mode; and Update (keeps data) or Restore (erases) with bundled `idevicerestore`, gated by fresh checks for the exact file, device and install identity. |
| **Apps** | Search and sort installed apps (with sizes over USB), launch, and remove with confirmation. |
| **Install App** | Inspect an `.ipa` on the Mac first — contents, provisioning profile, and code signature verified with Security.framework — then install it on a device, or install an `.app` on a simulator. |
| **Actions** | Over 40 guided actions (diagnostics, battery, IORegistry, provisioning and configuration profiles, crash reports, screenshots, sysdiagnose, Instruments recordings, packet capture, Bluetooth capture, Safari and web view tabs, network discovery, launch, open URL, simulated location, restart, simulator controls), each showing its risk, what it needs, and exactly how it runs. An Advanced Mode runs `devicectl` subcommands bound to the selected device. |
| **Backup** | Encrypted local backups with the same protocol Finder uses, full or incremental, with progress. Turn on backup encryption with a new password (never stored or logged). |
| **Evidence Capture** | A documented case folder with snapshots, optional timed streams (Unified Logs, syslog, packet capture), a screenshot, and crash reports, plus a manifest and SHA-256 hashes. Failed steps are recorded as coverage gaps. |
| **Security Analysis** | Analyze a decrypted backup, unpacked sysdiagnose, local file or folder, or existing MVT results against attributable JSON/STIX intelligence. Correlate investigative leads and export owner-only JSON, CSV, or HTML reports. Evidence stays local; a non-detection is never presented as proof that a device is clean. |
| **Packet capture** | Device-side network packets written as a standard `.pcap` file for Wireshark or tcpdump, as an action or as part of Evidence Capture. |
| **External tools** | Optional handoffs to separately installed [MVT](https://github.com/mvt-project/mvt), [UFADE](https://github.com/prosch88/UFADE), and [idb Companion](https://github.com/facebook/idb), validated by path and SHA-256. |
| **Session Activity** | Everything run in this session, with exportable manifests (output hashes, never raw output). |
| **Tool Reference** | The exact help text of the installed `devicectl`, `simctl`, and `xctrace`, and a Toolchain Check that confirms every command the app relies on exists in your Xcode. |

## Screenshots

The demo screenshots use the built-in **Demo Mode** (a clearly labelled simulated iPhone) or a
real iOS simulator. They contain no real device data.

| Readiness Check | Device details (simulator) |
|---|---|
| [![Readiness Check](docs/screenshots/readiness-check.png)](docs/screenshots/readiness-check.png) | [![Device](docs/screenshots/device-simulator.png)](docs/screenshots/device-simulator.png) |

| Live Logs (simulator) | Location Lab |
|---|---|
| [![Live Logs](docs/screenshots/live-logs.png)](docs/screenshots/live-logs.png) | [![Location Lab](docs/screenshots/location-lab.png)](docs/screenshots/location-lab.png) |

| Actions | Apps |
|---|---|
| [![Actions](docs/screenshots/actions.png)](docs/screenshots/actions.png) | [![Apps](docs/screenshots/apps.png)](docs/screenshots/apps.png) |

| Backup | Evidence Capture |
|---|---|
| [![Backup](docs/screenshots/backup.png)](docs/screenshots/backup.png) | [![Evidence Capture](docs/screenshots/evidence-capture.png)](docs/screenshots/evidence-capture.png) |

More: [Install App](docs/screenshots/install-app.png) · [External Tools](docs/screenshots/external-tools.png) · [Scope & Safety](docs/screenshots/scope-and-safety.png)

## Requirements

| | |
|---|---|
| **macOS** | macOS 14 Sonoma or later. |
| **Mac** | Apple silicon or Intel (universal binary). Tested on Apple silicon. |
| **Devices** | iPhone and iPad (iOS/iPadOS). Developer-service features on physical devices need iOS 17 or later through Xcode's device service; iOS 16 and earlier are supported for identity, logs, backups, diagnostics, and apps. |
| **Simulators** | Any iOS simulator installed with Xcode. |
| **Connection** | A data-capable USB cable, or Wi-Fi sync / Xcode network pairing after first pairing over USB. |
| **Xcode** | Optional — see below. |

### What needs Xcode

Many features use only macOS's built-in device service and work on a Mac **without Xcode**.
Features that use Xcode's developer tools need Xcode installed (open it once to finish setup):

| Works without Xcode | Needs Xcode |
|---|---|
| Device discovery (USB and Wi-Fi sync), identity, trust, Developer Mode status | Simulators (everything in the Simulators section) |
| Live Logs from physical devices (Unified and classic syslog) | Location simulation on iOS 17 and later |
| Packet capture; Bluetooth capture (with Apple's logging profile); Safari and web view tab listing (with Web Inspector on); checking the developer image, and mounting it over USB from an image Xcode installed or a folder you choose ([Developer images](#developer-images)) | Xcode's device service (`devicectl`) route for the developer image |
| Encrypted backups and encryption setup | Screenshots, launch app, open URL, stop a process |
| Diagnostics, battery, IORegistry, MobileGestalt, running processes, configuration profiles | Lock state, displays |
| Installed apps (with sizes), removing apps, installing `.ipa` packages | Sysdiagnose and Instruments recordings |
| Provisioning profiles, crash reports, Media folder listing | Restart device, Advanced Mode (`devicectl`), Tool Reference |
| IPA inspection, Evidence Capture (without the Xcode-only steps) | Readiness rows for Xcode's device service and Instruments |

The Command Line Tools alone are not enough for the Xcode column: `devicectl`, `simctl`, and
`xctrace` ship with Xcode.app.

## Install

### Download a release

1. Download `iOS-Developer-Toolkit-Swift-VERSION-macOS-universal.zip` and `SHA256SUMS.txt` from the
   [latest release](https://github.com/hideouts-io/iOS-Developer-Toolkit-Swift/releases/latest).
2. Verify the download:

   ```bash
   shasum -a 256 -c SHA256SUMS.txt --ignore-missing
   ```

   Optionally verify GitHub's build attestation:

   ```bash
   gh attestation verify iOS-Developer-Toolkit-Swift-VERSION-macOS-universal.zip --repo hideouts-io/iOS-Developer-Toolkit-Swift
   ```

3. Unzip it and move **iOS Developer Toolkit (Swift).app** to `/Applications`.
4. Release builds are ad-hoc signed and not notarized, so macOS asks for confirmation the first
   time. Control-click the app, choose **Open**, and confirm. If there is no Open button, go to
   **System Settings › Privacy & Security** and choose **Open Anyway**. Do not disable Gatekeeper.

Nothing else needs to be installed. The release also contains `idt`, the command-line tool, at
`iOS Developer Toolkit (Swift).app/Contents/MacOS/idt`.

### Build it yourself

See [Build from source](#build-from-source).

## First steps

1. **Connect and trust.** Connect the iPhone or iPad with a USB cable, unlock it, and tap
   **Trust**. Enter the passcode on the device — never in this app.
2. **Choose the target.** Use the device menu at the left of the toolbar. Physical devices and
   simulators are listed separately, and every page shows which one it acts on.
3. **Run the Readiness Check.** It tells you exactly what works and what to fix next.
4. **Turn on Developer Mode if needed** (iOS 16+): *Settings › Privacy & Security › Developer
   Mode*, then restart and confirm. **Device › Developer Mode Guide** walks through it.
5. **Mount the developer image** for screenshots, location simulation, and launching apps: the
   **Developer Image** section within **Device & DDI** shows its state; click **Check Again**, then **Mount Developer Image**.
   See [Developer images](#developer-images).
6. **Clean up** when finished: stop streams and clear simulated locations. Quitting the app
   clears a location this session simulated.

No device handy? Turn on **Device › Demo Mode** to explore every workspace with a simulated iPhone.

## Workspaces

The main sidebar follows the Python edition's workspace names and order. Existing workspace
identifiers remain compatible with profiles and launch arguments.

1. **Home** — selected-device status, suggested next steps, and workspace shortcuts.
2. **Device & DDI** — Device Information and Developer Image sections: identity, connection
   diagnostics, Developer Mode, local/Xcode images, mount/unmount, and Apple tool handoffs.
   Choose **Check Again** to read DDI state; opening the workspace does not query the device.
3. **Capability Matrix** — **Current Device** prerequisite checks and **Real-Device Compatibility**
   history with sanitized JSON/Markdown export. Checks run only when requested.
4. **Location Lab** — offline map, coordinates, saved places, repeated routes, and GPX playback.
5. **Live Logs** — Unified Logs and Classic Syslog streams; bounded **DVT OSLog** recordings
   through Instruments, OSLog archives, and simulator logs. Sessions can open in separate windows.
6. **Command Center** — native guided commands under six familiar categories, plus Simulator
   extras, with parameters, prerequisite checks, previews, confirmations, and Advanced Mode.
7. **Installed Apps** — explicit inventory loading, search, sort, sizes, launch, and confirmed removal.
8. **Backup** — **MobileBackup2**, **UFADE External**, and **MVT Analysis** sections. The latter
   two validate separately installed tools and retain their existing consent/confirmation flows.
9. **Sideload IPA** — inspect an IPA or simulator app before eligible installation.
10. **Evidence Capture** — guided case intake, collection, hashes, and coverage results.
11. **Ecosystem Tools** — validate Meta idb Companion and run its bounded inventory probe.
12. **Man Pages** — installed help for Apple's devicectl, simctl, and xctrace, with command handoff.
13. **Scope & Safety** — supported access, confirmations, privacy, and interpretation limits.

**Additional Swift Tools** keeps **Firmware** and **Security Analysis** directly accessible.
Firmware retains its library, signing checks, and confirmed installation; recovery/DFU watching
and Apple catalog checks require explicit controls. Security Analysis retains its local evidence,
indicators, correlated findings, coverage, and reports.

Below the workspace list are **Action Palette**, **Session Activity**, **Export Workspace**, and
**Import Workspace**. The toolbar holds device selection, retry scan, the palette, and **Workspace
Controls** for reconnect, Demo Mode, keyboard help, and support bundles. Import changes defaults
only and retains its preview and confirmation.

The navigation milestone does not add Python backends: the 46 native commands are not the
Python edition's 49 presets; direct Python DVT service streams/path listing and its downloaded
personalized-DDI cache workflows are absent. Instruments recordings provide the existing DVT
telemetry. Bluetooth captures use native PacketLogger `.pklg` rather than Python PCAPNG.
Man Pages uses installed Apple help rather than the Python 59-entry help inventory.

Press **⌘K** for the palette, **⌘R** to refresh devices, and **⇧⌘R** for an explicit readiness check.
The original **⌘1–⌘9** assignments remain: Home, Device Information, Developer Image, Firmware,
Capability Matrix, Installed Apps, Sideload IPA, Location Lab, and Live Logs. **⌥⌘←** / **⌥⌘→**
follow the new sidebar order and Session Activity. **Help › Keyboard Shortcuts** (**⌘/**) lists them.

### How changes are confirmed

| Risk | Example | Confirmation |
|---|---|---|
| Read-only | Battery snapshot, lock state | Runs immediately |
| Saves files on this Mac | Screenshot, crash reports, backup | Review sheet; files are never overwritten |
| Changes the device | Launch app, set location, install | Type `RUN` plus the last six characters of the device's UDID |
| High impact | Restart device, remove an app, erase a simulator | Also confirm a current backup and type `IRREVERSIBLE` plus the same code |

Because the code comes from the target's UDID, a confirmation can never apply to a different
device. Each operation also captures its target when it starts, and lockdown sessions verify
that the device answering is the one you selected.

## Developer images

Screenshots, location simulation, launching apps, and Instruments need Apple's developer image
(Developer Disk Image) mounted on the device. In **Device & DDI › Developer Image**, **Check Again**
reads its state and shows one of these results; Device Information shows a summary:

[![Developer image card](docs/screenshots/developer-image.png)](docs/screenshots/developer-image.png)


| State | Meaning |
|---|---|
| Mounted | A compatible image is mounted. Nothing is mounted again. |
| Available | A compatible image is on this Mac and can be mounted now (the device already holds Apple's personalization for it, or it is an iOS 16-or-earlier image). |
| Personalization required | A compatible image is on this Mac; Apple must sign it for this device first (iOS 17 and later, needs the internet). |
| Missing | No compatible image is on this Mac. |
| Incompatible | The image on this Mac (or the one mounted) does not fit this device or iOS version. |
| Needs attention | Trust, Developer Mode, unlocking, or a USB connection is needed first. |
| Failed | The check or the last mount attempt failed; the card shows why and what to do. |
| Not required | Simulators and the demo device. |

The details list the iOS version and build, model, architecture, chip and board used to choose the
image, where it is mounted, and which image on this Mac would be used.

**iOS 17 and later** use a *personalized* image. Xcode installs it in
`/Library/Developer/DeveloperDiskImages/iOS_DDI`. Mounting picks the build identity for the
device's chip and board and, unless the device already holds a personalization for that image,
asks Apple's signing server (`gs.apple.com`) for one — sending the device's chip, board, and ECID
with a one-time nonce, exactly as Xcode does. The confirmation says so before anything is sent.

**iOS 16 and earlier** use `DeveloperDiskImage.dmg` and its `.signature` for the exact iOS
`major.minor` version. Current Xcode versions no longer include them; add a folder that contains
them (for example an older Xcode's `Platforms/iPhoneOS.platform/DeviceSupport/16.4`) with
**Add Image Folder…** on the Developer Image page.

**How it mounts** (Developer Image › How to mount): *Automatic* uses Xcode's device service (`devicectl`)
when it can reach the device on iOS 17 and later, and otherwise the built-in client, which talks
to the device's image-mounter service over USB and works without Xcode's device service. The app
never downloads images from third parties.

## Firmware

The **Firmware** page (sidebar, under Additional Swift Tools) installs iPhone and iPad firmware (IPSW files) the
way Finder does, using `idevicerestore` and `irecovery` from the
[libimobiledevice](https://libimobiledevice.org) project, bundled with the app as separate programs
(see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).

- **Device and mode.** The selected iPhone or iPad, or a device in recovery or DFU mode (found
  every few seconds after enabling **Watch Recovery / DFU**). **Enter Recovery Mode** and **Exit Recovery Mode**,
  and step-by-step DFU instructions.
- **Apple's firmware.** Apple's firmware list (`itunes.apple.com/check/version`, the one Finder
  uses) gives the current firmware for the model, with Apple's SHA-1 when supplied. **Check Signing** asks
  Apple's signing server whether it still signs the matching build identity — reading only the build manifest from
  Apple's server, and sending a random device ID, never the device's. **Download** saves the IPSW
  to the library and continues an interrupted download where it stopped. A supplied catalog SHA-1
  must match or the staged file is deleted. Without it, the result explicitly says Apple's checksum
  is unavailable. A local SHA-256 identifies the bytes; it does not prove Apple provenance or signing.
- **Library.** IPSW files in `~/Library/Application Support/iOS Developer Toolkit (Swift)/Firmware`.
  Add your own, check signing, verify (SHA-1 and SHA-256), show in Finder, or move to the Trash.
- **Install.** Choose an IPSW and **Update** (keeps apps and data) or **Restore** (erases the
  device). **Check Before Installing** establishes readiness without changing the device. After
  confirmation, every mandatory check runs again: file identity, exact target/board, the requested
  Update or Erase identity, current Apple TSS signing for that identity, and `--no-action` device
  detection. A failed or unknown result blocks installation. Update requires a Customer Upgrade
  identity and never falls back to erase. Update needs the typed `RUN` confirmation; Restore needs
  the high-impact confirmation and backup acknowledgement. Progress is shown step by step.
  At the critical firmware-writing boundary, **Stop** and normal Quit are refused until
  the helper exits, including failure exits; closing the last window cannot terminate the app then.
  Sudden-termination protection is balanced around that phase. Force Quit, SIGKILL, power loss,
  kernel panic and cable removal can still interrupt it. Logs are kept in the library's `Logs` folder.

During an install, Apple's signing server receives the device's chip, board, and ECID to sign
the firmware for it, as with Finder. Firmware that Apple no longer signs cannot be installed.
The app does not offer jailbreak-style exploits or downgrades.

## Command-line tool

`idt` provides the automation-friendly parts of the app:

```bash
idt devices --simulators                      # list devices and simulators
idt readiness --udid <UDID>                   # read-only readiness check
idt inspect-ipa App.ipa [--json]              # inspect a package
idt collect --udid <UDID> --output-root ~/Cases --duration 120 --include-unified-logs
idt ddi status --udid <UDID> [--json]         # developer image state (exit 0 mounted, 2 mountable)
idt ddi mount --udid <UDID> --confirm "RUN ABC123" [--mechanism automatic|core-device|native]
idt ddi unmount --udid <UDID> --confirm "RUN ABC123"
idt toolchain                                 # check the installed Xcode
```

`--include-oslog-archive` adds the device's saved Unified Log history for the last hour (`log collect`); `--include-dvt-logs` records os_log through Instruments (DVT) for the stream duration. `--include-oslog`, the 0.3.x flag for the DVT OSLog stream, is still accepted and selects DVT logging.

`idt collect` exits with `0` when complete, `2` when finished with coverage gaps, and `1` when the
device could not be identified.

## Security and privacy

- **Least privilege.** No administrator rights and no `sudo`. The app never reads
  `/var/db/lockdown`, never creates pairing records, and never restarts system services. Pairing
  material is requested from macOS's device service and kept only in memory.
- **Verified connections.** Lockdown sessions use TLS with this Mac's pairing certificate, pin the
  device certificate from the pairing record, and confirm the device's UDID before any request.
- **No shell.** External tools run from fixed paths with an argument vector and a minimal
  environment; nothing is interpreted by a shell. All process launches go through one audited
  runner with timeouts and cancellation.
- **Untrusted input.** Device responses, backup file paths, IPA archives, GPX files, and workspace
  profiles are validated; path traversal, symbolic links, encrypted or oversized archive entries,
  and XML entities are rejected.
- **Local only.** Nothing is uploaded, with one confirmed exception: mounting a developer image on
  iOS 17 and later asks Apple's signing server (`gs.apple.com`) to personalize it, sending the
  device's chip, board, and ECID with a one-time nonce — as Xcode does. Installing firmware sends
  the same kind of request, as Finder does; checking whether Apple signs a firmware uses a random
  device ID. The Firmware page reads Apple's firmware list and downloads IPSWs from Apple. Security Analysis keeps selected evidence local; an explicit threat-intelligence update downloads a commit-pinned source with SHA-256 provenance. Captures, backups, cases, and reports are written with
  owner-only permissions. The app's own log records outcomes rather than device content, and marks
  identifiers as private.
- **Sanitized sharing.** **iOS Developer Toolkit › Create Support Bundle…** and the readiness
  report exports remove names, identifiers, paths, and addresses. Review them before sharing.
- **Hardened runtime**, no App Sandbox: the app must reach the system's device service socket and
  run Xcode's tools. See [SECURITY.md](SECURITY.md) to report a vulnerability.

## Troubleshooting

| Problem | Try this |
|---|---|
| The device does not appear | Use a data cable, unlock the device, tap **Trust**, try another port, and check **Connection diagnostics** on the Device page. If nothing appears after reconnecting, restart the Mac. |
| “This device has not trusted this Mac” | Unlock the device and reconnect it; tap **Trust**. If no prompt appears, reset *Settings › General › Transfer or Reset › Reset › Reset Location & Privacy*. |
| Developer Mode is missing on the device | Connect it and open Xcode › *Window › Devices and Simulators* once. |
| Developer features say they need Xcode | Install Xcode, open it once, and check *Xcode › Settings › Locations › Command Line Tools*. |
| The developer image will not mount | Read the Developer Image page: it names the problem (Developer Mode, lock, missing or incompatible image) and the fix. On iOS 17 and later keep the Mac online (Apple personalizes the image); if one route fails, switch **How to mount** on the Developer Image page. |
| A backup stops with “must stay unlocked” | Unlock the device and keep it awake until the backup finishes. |
| Firmware will not install | Run **Check Before Installing** on the Firmware page. Apple must still sign the firmware; keep the device connected by USB and the Mac online. If the device is left in recovery mode, install again with **Restore**. The log is in the library's `Logs` folder. |
| An `.ipa` cannot be installed | Check the inspection: the signature must be valid and the profile must include the device. |
| Live logs are very busy | Filter the view or pause it; capture continues in the background. |
| Something else | Run the **Readiness Check**, then create a support bundle and open a discussion. |

More detail: [docs/troubleshooting.md](docs/troubleshooting.md).

## Build from source

Requirements: macOS 14+, Xcode 16 or later (Swift 6).

```bash
git clone https://github.com/hideouts-io/iOS-Developer-Toolkit-Swift.git
cd iOS-Developer-Toolkit

swift test                                    # unit and integration tests
swift build -c release --product idt          # the command-line tool

xcodebuild -project iOSDeveloperToolkit.xcodeproj -scheme iOSDeveloperToolkit \
  -configuration Release -destination 'platform=macOS' build

scripts/build-release.sh                      # universal, ad-hoc-signed release ZIP, SBOM, checksums in build-output/release/
```

The release includes the firmware helpers, which `scripts/build-release.sh` builds with
`scripts/build-restore-helpers.sh` from pinned sources. That needs
`brew install autoconf automake libtool pkg-config cmake`. To try the Firmware page from a
development build, build the helpers once and point the app at them:

```bash
scripts/build-restore-helpers.sh
open --env IDT_RESTORE_HELPERS="$PWD/build-output/restore-helpers/out/bin" "iOS Developer Toolkit (Swift).app"
```

The app icon and logo come from one image, `docs/brand/logo-source.png`:
`xcrun swift scripts/generate-icons.swift` writes the app icon at every size, the in-app logo, and
`docs/brand/` (`icon-1024.png`, `iOSDeveloperToolkitSwift.icns`, `logo-1024.png`, `logo-512.png`,
`logo.svg`, and the repository's `social-preview.png`).

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
and committed, so you only need XcodeGen when you change the project structure (`xcodegen generate`).

Optional test suites:

```bash
IDT_SIMULATOR_TESTS=1 swift test --filter RealSimulator   # boots a simulator end to end
IDT_NETWORK_TESTS=1 IDT_RESTORE_HELPERS="$PWD/build-output/restore-helpers/out/bin" \
  swift test --filter RealFirmware                        # Apple's firmware list, signing, the helpers
xcodebuild -project iOSDeveloperToolkit.xcodeproj -scheme iOSDeveloperToolkit \
  -destination 'platform=macOS' test                      # UI tests (macOS asks to allow automation)
```

Documentation screenshots are produced by the app itself:

```bash
"iOS Developer Toolkit (Swift).app/Contents/MacOS/iOS Developer Toolkit (Swift)" \
  -demo-mode YES -populate-demo YES -window-size 1180x700 -capture-screenshots ~/Desktop/shots
```

Layout: `Sources/ToolkitCore` (process runner, errors, logging, secure files),
`Sources/DeviceKit` (usbmuxd, lockdown and its services, CoreDevice, simctl, discovery),
`Sources/ToolkitFeatures` (Location Lab, IPA inspection, logs, actions, readiness, evidence,
Security Analysis, external tools), `Sources/idt` (CLI), `App/` (SwiftUI app and UI tests), `Tests/`.
See [docs/architecture.md](docs/architecture.md).

## Project status and limitations

Version 1.0 is a native rewrite of the Python/PySide6 app ([iOS Developer Toolkit](https://github.com/hideouts-io/iOS-Developer-Toolkit), 0.3.x), which depends on
`pymobiledevice3`. See [MIGRATION.md](MIGRATION.md) for the feature-by-feature mapping. Workspace
profiles exported by 0.3.x can be imported in **Settings › Profiles**; the preview explains how each
setting carries over.

Firmware installation (Update, Restore, recovery and DFU mode) has been tested against Apple's
servers and with the bundled helpers, but not yet by installing firmware on a device; see
[MIGRATION.md](MIGRATION.md#10-firmware-ipsw-manager-and-installation).

### The Python app

The Python/PySide6 app, **iOS Developer Toolkit**, is maintained separately in
[hideouts-io/iOS-Developer-Toolkit](https://github.com/hideouts-io/iOS-Developer-Toolkit), with its releases. It uses `pymobiledevice3` and
Python; this app needs neither. The two install side by side and keep their data in separate
folders, and this app imports workspace profiles exported by the Python app.

- The native lockdown services (logs, packet capture, backup, diagnostics, app installation over
  USB, developer-image checking and mounting including Apple personalization) are tested end to
  end against a protocol-accurate simulated device and against macOS's real device service. Their
  read-only protocol layer has been checked on one iPhone (iOS 26, Developer Mode off); mounting,
  location, installation, backup, and the app's pages **have not yet been tested on physical
  iPhones or iPads**. Please report results using the
  [physical-device test protocol](docs/PHYSICAL_DEVICE_TEST_PROTOCOL.md).
- Not available in 1.0: the developer-service file listing. Details and alternatives are in [MIGRATION.md](MIGRATION.md#6-known-limitations-and-features-not-reproduced).
- Release builds are ad-hoc signed and not notarized.
- Release builds are universal (Apple silicon and Intel). If the Intel half is run under Rosetta on
  an Apple silicon Mac, macOS warns that the app includes a component that will not open in
  macOS 28; the Apple silicon half, which runs by default, is not affected.

## Contributing, support, and license

- [CONTRIBUTING.md](CONTRIBUTING.md) — setup, design rules, and checks.
- [SUPPORT.md](SUPPORT.md) — where to ask questions.
- [SECURITY.md](SECURITY.md) — private vulnerability reporting.
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [SOURCE_AVAILABILITY.md](SOURCE_AVAILABILITY.md).

iOS Developer Toolkit is released under the [MIT License](LICENSE). The bundled world map uses
public-domain [Natural Earth](https://www.naturalearthdata.com) data. iPhone, iPad, Xcode, and
macOS are trademarks of Apple Inc.; this project is not affiliated with Apple.
