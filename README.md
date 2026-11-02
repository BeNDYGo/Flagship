<p align="center">
  <img src="Icon.png" width="96" height="96" alt="Flagship Icon" />
</p>

# Flagship

**English** | [Русский](README-RU.md) | [简体中文](README-ZH.md) | [日本語](README-JA.md)

**Flagship** is a lightweight, informative system monitor for the macOS menu bar. The application combines real-time network activity monitoring with vital system metrics: CPU load, RAM usage, and CPU temperature.


![Flagship Menu Bar Indicator](Screenshot1.png)

|  |  |
| --- | --- |
| ![Metrics Dashboard](Screenshot2.png) | ![Flagship Settings](Screenshot3.png) |


## Key Features

- **Compact menu bar indicator**: Two-line display showing current upload and download speeds, country flag / external IP, CPU load, used RAM, and temperature.
- **Pop-up metrics dashboard**: 5-minute historical sparkline graphs for each metric (CPU, RAM, temperature, and combined network graph).
- **Country flag and external IP lookup**: Automatic geolocation detection with country flag display, reacting instantly to network and VPN changes.
- **Dynamic load coloring**: Configurable color-coded metrics based on load level (green, yellow, red) supporting both light and dark macOS appearance modes.
- **Flexible customization**: Hide any unwanted metrics (keep only network or only system stats), pin monitoring to a specific network interface, or configure Geo-IP lookup providers.
- **Minimal resource footprint**: Native Swift/AppKit application directly querying SMC sensors and Mach kernel statistics without external dependencies.

---

## Installation

### Requirements
- macOS 13.0 (Ventura) or later.
- Universal binary for Apple Silicon (M1/M2/M3/M4) and Intel (x86_64).

### Downloading Pre-built App
1. Download `Flagship.zip` from the [Releases](https://github.com/BeNDYGo/Flagship/releases) page.
2. Unpack the archive and move `Flagship.app` into your `/Applications` folder.
3. Launch the app. The indicator will appear in your menu bar.
4. Click the indicator to view the dashboard. Use **Settings...** in the menu to customize appearance and enable **Launch at Login**.

> **Note on First Launch (macOS Gatekeeper):**  
> Because this application uses an ad-hoc local signature without an Apple Developer certificate, macOS may warn you on first launch.
>
> There are three easy ways to open it:
> 1) Right-click (or Control-click) `Flagship.app` in Finder and select **Open**.
>
> 2) If that does not work: open **System Settings** → **Privacy & Security** → scroll down to the **Security** section and click **Open Anyway**.
>
> 3) Or run the following command in Terminal:  
> ```sh
> xattr -cr /Applications/Flagship.app
> ```

---

## Building from Source

To build the application yourself, you will need Xcode Command Line Tools.

1. Clone the repository:
   ```sh
   git clone https://github.com/BeNDYGo/Flagship.git
   cd Flagship
   ```
2. Run the build script:
   ```sh
   ./build.sh
   ```

The script compiles a universal binary for `arm64` and `x86_64`, packages the bundle, and ad-hoc signs it. The compiled application will be generated at `build/Flagship.app`.

---

## Technical Details and Architecture

1. **Menu bar typography and layout**: Uses a fixed 9.5 pt regular font (`monospacedDigitSystemFont`) to avoid indicator jitter when digits change. Automatic narrowing is disabled — reserved width remains consistent even when numbers drop to single digits or zeros. Remaining metrics are automatically centered when others are hidden.
2. **Color thresholds (Color System Metrics)**: When enabled, colors are assigned based on thresholds: CPU is normal up to 50%, orange from 50%, red from 80%; RAM is normal up to 70%, warning from 70%, critical from 90%; CPU temperature is normal up to 70°C, warning from 70°C, critical from 90°C. Palette is dynamically adjusted for contrast across light and dark themes. Network speeds always maintain the system monochrome menu bar color.
3. **Background resource sampling**: All polling runs once per second on a dedicated serial background queue `flagship.system` (`qos: .utility`), never blocking the main UI thread.
4. **RAM measurement formula**: Used memory is calculated as `active + wired + compressed` from `host_statistics64` (1 GB = 1024³ bytes). This reflects actual physical memory occupied rather than a synthetic memory pressure percentage.
5. **CPU temperature sampling**: Read directly through IOKit from the `AppleSMC` driver. The value represents the arithmetic mean of all available core temperature sensors in the current sample (for both Apple Silicon and Intel). A dash is displayed if sensors are unavailable (e.g. inside a VM).
6. **Network accounting and VPN handling**: In Auto mode, the monitor tallies only physical adapters (`en*`, `pdp_ip*`). Virtual tunnel interfaces (`utun*`) are excluded from the total to prevent double-counting traffic already routed through the physical adapter. When an interface is locked manually to a specific `utun*`, only that tunnel's traffic is counted.
7. **Speed measurement accuracy**: Speeds are calculated using the byte delta divided by actual elapsed astronomical time (`uptimeNanoseconds`), rather than assuming a precise 1.000-second timer interval. When a new interface appears, a baseline snapshot is taken first to prevent artificial speed spikes. If a locked interface disconnects, speed immediately drops to zero.
8. **Network change detection**: Combines `SCDynamicStore` notifications (global IPv4/IPv6 routing shifts, service state, link changes), `NWPathMonitor`, 1-second address polling, and system wake events (`didWakeNotification`).
9. **Geo-IP failover and rate limits**: On network change, an immediate lookup is fired, followed by verification retries after 1 and 3 seconds to catch delayed VPN routing. Five providers are supported (`ip-api.com`, `ipapi.co`, `api.country.is`, `ipinfo.io`, `ipwho.is`), handling HTTP 429 and `Retry-After` headers gracefully. A white flag 🏳️ is displayed while checking or when services are unreachable.
10. **Data persistence and history**: The 5-minute historical graph data is stored strictly in volatile RAM and is reset upon app restart. Settings are saved under the isolated bundle domain `local.flagship.app` without conflicting with other tools.

---

## Origin and License

- Based on [NetBar](https://github.com/mh-sudo) (MIT License).
- License: MIT.
