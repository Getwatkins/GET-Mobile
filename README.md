# GET Mobile - iOS companion app (work in progress)

This is a starting point for a native iOS/iPadOS app that talks to a
Macchina A0 running the `esp32-isotp-ble-bridge` (BridgeLEG) firmware over
Bluetooth LE - the same hardware/firmware SimosTools, VW_Flash's `BLEISOTP`
interface, and the wider Simos18 tuning community already use.

**What works right now:** live DID reads over BLE (the "Read Once"/"Start
Live" gauge functionality). **What's not built yet:** flashing - that's a
much bigger follow-on project (security access/seed-key, checksums,
compression).

**Important honesty note:** this hasn't been compiled or tested against
real hardware yet. The BLE protocol (UUIDs, packet framing/fragmentation)
was traced byte-for-byte from the firmware's own C source, so that part
should be solid. The one place I'm genuinely unsure about is the BLE
password/auth handshake - the firmware's own password-check code looks like
it may have a bug, so if your bridge has `PASSWORD_CHECK` compiled in and
connections get rejected, that's the first place to look. Expect to fix a
small build error or two on the first CI run as well.

**No Mac required anywhere in this pipeline.** GitHub's free cloud macOS
runners do the actual Xcode compiling; a Windows tool (Sideloadly) puts the
result on your phone. Here's the full path from zero to "app on my iPhone":

---

## Choosing a connection method

The app opens to a picker with three options, all converging on the same
6-gauge screen once connected:

- **ESP32 Bridge** - the Macchina A0 / BLE-ISOTP bridge (everything
  described below). This is the one that's been traced against real
  firmware source and is the most solid of the three.
- **ELM327 WiFi** - a plain TCP socket to the dongle's WiFi server (default
  `192.168.0.10:35000`, editable in the app if yours differs). No Bluetooth
  or MFi restrictions apply here at all - straightforward and reliable.
- **ELM327 Bluetooth** - **only works with BLE dongles, not Classic
  Bluetooth ones.** Most cheap ELM327 Bluetooth adapters use Classic
  Bluetooth (SPP), which iOS blocks from third-party apps entirely without
  Apple's MFi certification - no code fix is possible for that case. This
  only has a chance of working if your dongle is specifically sold as
  "BLE"/"Bluetooth 4.0"/"iOS compatible." Even then, there's no single
  standard for how BLE ELM327 clones expose themselves over Bluetooth - this
  tries the two most common schemes (Nordic UART Service and "HM-10 style").
  If neither matches your dongle, it won't connect, which would mean we need
  your dongle's exact model/chipset to add a third scheme.

Both ELM327 transports speak the same ELM327 AT-command language
(`ATSP6`/`ATSH7E0`/`ATCRA7E8` to set up UDS-over-CAN, then hex request lines
like `22202A`) rather than the ESP32 bridge's custom binary protocol - this
hasn't been tested against real ELM327 hardware yet, so the response parser
was written defensively (it hunts for the actual `62`/`7F` UDS response
bytes rather than assuming an exact prefix format) precisely because clone
firmware varies. If parsing fails on real hardware, the raw response text is
the first thing to look at.

---

## 1. Get this project into a GitHub repository

If you don't already have this project in a repo:

1. Go to [github.com/new](https://github.com/new), create a **public**
   repository (public repos get free unlimited macOS build minutes - private
   repos only get a small monthly allowance, so public is the practical
   choice for this). Name it whatever you like, e.g. `get-mobile`.
2. Easiest upload method with no git/command-line needed: on the new repo's
   page, click **"uploading an existing file"**, then drag in the *contents*
   of this package (the `GETMobile/` folder, `project.yml`, and the
   `.github/` folder) - GitHub's web uploader preserves folder structure.
   Commit directly to `main`.
   - Alternative: install [GitHub Desktop](https://desktop.github.com/) (a
     Windows GUI, no command line) if you'd rather work with a proper local
     git folder you can keep updating.

Your repo's root should end up looking like:
```
project.yml
.github/workflows/build-ios.yml
GETMobile/GETMobile/   <- all the Swift source + Assets.xcassets
GETMobile/README.md
```

## 2. Let GitHub Actions build it

Once `project.yml` and `.github/workflows/build-ios.yml` are in the repo,
GitHub starts building automatically on every push to `main`. To trigger
one manually instead:

1. Go to your repo on github.com → **Actions** tab
2. Click **"Build iOS App"** in the left sidebar
3. Click **"Run workflow"** → **Run workflow**
4. Wait a few minutes (watch it live if you want - click into the run)

If it fails, click into the run and read the red step's log - most first-run
failures are small, fixable things (a typo, a missing file), not deep
problems.

## 3. Download the built app

1. Once the run finishes (green checkmark), click into that run
2. Scroll down to **Artifacts**
3. Download **GETMobile-ipa** (it's a zip containing `GETMobile.ipa`)
4. Unzip it on your Windows PC - you now have `GETMobile.ipa`

## 4. Install Sideloadly and put the app on your device

1. Download **Sideloadly** for Windows: [sideloadly.io](https://sideloadly.io)
2. Install it. If prompted, install Apple's device drivers too (Sideloadly's
   installer offers this, or you can install the standalone Apple Devices /
   iTunes drivers from Apple's site first).
3. Connect your iPhone/iPad to your PC with a cable, unlock it, tap
   **Trust This Computer** if prompted.
4. Open Sideloadly. Drag `GETMobile.ipa` into the window (or use the folder
   icon to browse to it).
5. Enter your Apple ID in the box provided (a free/normal Apple ID works
   fine - no paid developer account needed).
6. Click **Start**. Sideloadly signs the app with your Apple ID and installs
   it - this takes a minute or two.
7. **On the device:** go to **Settings → General → VPN & Device
   Management**, find your Apple ID under "Developer App", tap it, then tap
   **Trust**.
8. Open **GET Mobile** from your Home Screen.

**One limitation of the free-Apple-ID path:** apps installed this way stop
working after **7 days** and need reinstalling. When that happens, just
re-run Sideloadly with the same .ipa (no need to rebuild unless you've
changed the code). If this becomes annoying during active testing, the
$99/year Apple Developer Program removes the 7-day limit entirely (via
TestFlight) - not necessary to get started, just a convenience for later.

---

## Previewing without a bridge (Demo Mode)

You don't need real hardware to see the app working. On the connect screen,
tap **"Preview Gauges (Demo Mode — no bridge needed)"** - this fills all 6
gauges with smoothly moving synthetic values so you can check the layout,
try the DID pickers, and flip between Needle/Digital style. A "DEMO MODE"
banner reminds you the numbers aren't real. Tap **"Exit Demo Mode"** to go
back to the connect screen once your bridge arrives.

## Previewing in a browser (no phone needed either)

The Actions run now also produces a second artifact,
**GETMobile-simulator-preview** - a Simulator build of the app. You can
upload this .zip to [appetize.io](https://appetize.io) (free tier) and it
streams the running app straight into your browser tab.

**Important limitation:** no simulator anywhere (Appetize or otherwise) can
access real Bluetooth hardware - this is an iOS platform limitation, not
specific to Appetize. This preview is for checking the UI/layout only. Use
**Demo Mode** (above) inside that same preview to see the gauges actually
move, since a real bridge obviously isn't reachable from a browser simulator
either. Testing the actual BLE connection still requires Sideloadly on a
real device once your bridge arrives.

---

## Using the app

1. Power on your Macchina A0 bridge and plug it into the car's OBD port.
2. Open GET Mobile - it starts scanning automatically.
3. Tap the bridge in the list to connect (default advertised name is
   `BLE_TO_ISOTP20` unless you've renamed it).
4. Once connected you'll see the 6-gauge grid - tap each gauge's dropdown
   to pick a parameter (PUT, MAP, AFR, Boost/Vacuum, etc. - same list as
   the Windows app's quick-pick).
5. **Read Once** takes one reading of all enabled gauges; **Start Live**
   polls continuously (~6-7 times/second) until you hit **Stop Live**.
6. Toggle **Needle/Digital** to switch how all 6 gauges are drawn.

---

## Project file reference

```
BLE/UdsTransport.swift          Shared protocol - lets all 3 transports work interchangeably
BLE/BridgeProtocol.swift        UUIDs, header flags, Simos18 CAN IDs (traced from firmware source)
BLE/BridgeFrameCodec.swift      Packet encode/fragment + reassembly
BLE/BridgeManager.swift         ESP32 bridge: CoreBluetooth scan/connect/send/receive
ELM327/Elm327Protocol.swift     Shared AT-command setup + hex request/response parsing
ELM327/Elm327WifiManager.swift  ELM327 over TCP socket (WiFi dongles)
ELM327/Elm327BluetoothManager.swift  ELM327 over BLE (Nordic UART / HM-10 style dongles)
UDS/UdsClient.swift             ReadDataByIdentifier (service 0x22), same as the Windows app
Model/EquationEvaluator.swift   Port of the Windows app's equation parser
Model/CommonDidCatalog.swift    Full DID list from parameters_22.csv + AFR/Boost-Vacuum
Model/DidValueDecoder.swift     Raw bytes -> scaled value, ported from FormatKnownValue
Model/GaugeSession.swift        Gauge slot state + live-poll loop + demo mode
Views/GaugeView.swift           The dial/digital gauge drawing
Views/GaugeSlotCardView.swift   One gauge + its DID picker
Views/TransportPickerView.swift Choose ESP32 Bridge / ELM327 WiFi / ELM327 Bluetooth / Demo
Views/ConnectView.swift         ESP32 bridge scan/connect screen
Views/Elm327WifiConnectView.swift      ELM327 WiFi host/port entry screen
Views/Elm327BluetoothConnectView.swift ELM327 BLE scan/connect screen
Views/GaugesView.swift          Main 6-gauge screen
Views/ContentView.swift         Root view (picker <-> gauges, tracks which transport is active)
GETMobileApp.swift              App entry point
Resources/Theme.swift           GET brand colors
Assets.xcassets/                App icon, logo banner, accent color
project.yml                     XcodeGen spec - generates the .xcodeproj during CI
.github/workflows/build-ios.yml The CI build itself
```

## If you ever do get access to a Mac

You can skip all of the above and use Xcode directly: open a terminal in
this folder and run `xcodegen generate` (install XcodeGen via
`brew install xcodegen` first), which produces `GETMobile.xcodeproj` you can
open and run normally, including straight onto a USB-connected device with
free Apple ID signing (Signing & Capabilities tab → pick your Apple ID as
the Team). Same 7-day expiry applies either way on a free account.

## What's next (not built yet)

- **Flashing.** Large separate effort (security access/seed-key routines,
  block writes, checksums) - genuinely doable since BLEISOTP flashing is
  proven technology in this ecosystem, but its own project.
- **Multiple bridges nearby:** the connect screen already lists every bridge
  it sees, so this mostly just needs real-world testing.
- **Persisting your gauge picks** between launches (currently resets to
  PUT/Engine Speed/MAP + 3 blanks every time, matching the Windows app's
  defaults).
- **Password/auth verification** against real hardware, per the caveat above.
