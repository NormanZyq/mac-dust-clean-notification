# DustWatch

A menu-bar utility that quietly records CPU/GPU temperature, fan RPM, and
load on your Mac, then alerts you when long-term trends suggest your
machine's cooling has degraded (typically: dust in the vents).

- **Background** — one sample per minute, runs as an accessory app (no Dock icon)
- **Long-term** — months of data rolled up automatically, queryable instantly
- **Visual** — SwiftUI Charts line charts in the dashboard window
- **Alerting** — system notifications + menu-bar red icon when a recent
  temperature window sits significantly above the historical baseline at
  the same CPU frequency

> Personal utility, not App Store material. The app does **not** enable
> App Sandbox because macOS's SMC interface is unavailable to sandboxed
> processes.

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon (M1 / M2 / M3 / M4) for full SMC sensor support
- Intel Macs are built by the release workflow, with legacy SMC decoding
  retained on a best-effort basis
- Xcode command-line tools (`xcode-select --install`) — for the Swift toolchain
  and the `codesign` tool

You do **not** need:

- Xcode itself
- An Apple Developer account
- Any third-party package (everything is system frameworks: SwiftUI, AppKit,
  Charts, IOKit, UserNotifications, libsqlite3)

## Build & install

```sh
cd dustwatch-mac
./build.sh
cp -R build/DustWatch.app /Applications/
```

`build.sh` does three things:

1. `swift build -c release` compiles the binary
2. Assembles `DustWatch.app` (Info.plist + entitlements + binary)
3. Ad-hoc code-signs the bundle

To rebuild from scratch:

```sh
./build.sh clean && ./build.sh
```

## First launch

macOS Gatekeeper will refuse to open the app the first time because
it's signed with an ad-hoc identity. To approve it:

1. Open `DustWatch.app` from Finder
2. macOS shows "cannot be opened because the developer cannot be verified"
3. Open **System Settings → Privacy & Security**, scroll down, click
   **Open Anyway** next to the DustWatch entry
4. Click **Open** in the confirmation dialog

After that, the app launches normally.

When the popover appears, click **Open Dashboard** to see the charts.

## Data storage

```
~/Library/Application Support/DustWatch/data.db
```

A standard SQLite file. You can open it with `sqlite3` to inspect:

```sh
sqlite3 ~/Library/Application\ Support/DustWatch/data.db \
  "SELECT datetime(ts, 'unixepoch'), cpu_temp, fan_max FROM samples ORDER BY ts DESC LIMIT 10;"
```

Schema:

| Table | Purpose | Retention |
|---|---|---|
| `samples` | Raw 1-minute readings | 30 days |
| `samples_hourly` | Rolled up to per-hour aggregates | 1 year |
| `samples_daily` | Rolled up to per-day aggregates | forever |
| `alerts` | Notification log (for throttle) | forever |
| `config` | User settings (single row) | forever |

Aggregation runs after every sample write. Old data is automatically moved
to the more compact tables; you can leave the app running for years
without filling your disk.

## Settings

Open the dashboard window → **Settings** tab. Everything is saved to
the database immediately.

| Setting | Default | What it does |
|---|---|---|
| Interval | 60 sec | Time between samples |
| Temperature threshold | 3.0 °C | How much hotter the recent window must be (vs. baseline) to trigger an alert |
| Fan RPM threshold | 500 RPM | Alternative evidence: how much faster fans must spin |
| Baseline window | 60 days | The "old normal" period |
| Recent window | 7 days | The "what's happening now" period |
| Notifications | on | System banners and the menu-bar red icon |

## How the alert works

Every 6 hours the app:

1. Splits samples into baseline (60 days ago to 7 days ago) and recent
   (last 7 days).
2. Groups by CPU P-State (a qualitative "how hard is the CPU running"
   index, not absolute GHz).
3. For each P-State bucket, runs a Mann-Whitney U test on the temperature
   distributions.
4. If the test is significant (p < 0.05) **and** the median temperature
   rise is at least your threshold, the bucket is a candidate.
5. The same test is also run on fan RPM (rising RPM at the same load is
   alternative evidence of degraded cooling).
6. The worst bucket triggers a single notification, throttled to once
   per 7 days.

The notification opens the **Compare** tab in the dashboard, which shows
a bar chart of the baseline vs. recent medians at the affected P-State.

## Dashboard UI

When the user opens the main window (menu-bar icon → "Open Dashboard",
or the global hot key **⇧⌘T**), they see a 6-tab window:

- **Overview** (default landing tab)
  - 4 stat cards: today's CPU peak, GPU peak, fan peak, minutes above 70°C
  - Each card shows delta vs yesterday (▲ / ▼ / •)
  - 24-hour sparkline chart (CPU + GPU average per hour)
  - 7-day daily-peak bar chart with red threshold reference line
  - "Thermal degradation detected" banner appears if the analyzer
    found a significant delta
- **Live** — 24h raw samples in detail with threshold reference
- **History** — pick a range (24h / 7d / 30d / 90d / All) and an
  aggregation (Raw / Hourly / Daily), then export the current view
  as CSV via the toolbar button
- **Heatmap** — GitHub-style calendar (13/26/52 weeks) where each
  square is one day, colored by peak CPU temperature. Hover for
  details, click for a day-detail popover.
- **Compare** — bar chart of baseline vs recent median CPU temperature
  at the most-degraded P-State
- **Settings** — sample interval, thresholds, comparison windows, notifications

The right-click menu on the menu-bar icon also has:
- Open Dashboard… (⇧⌘T)
- Export Last 24 Hours as CSV…
- Reveal Data File in Finder
- Quit

## Releases

`v0.1.1` is a beta release. Pushing a `v*` tag to GitHub runs
the release workflow and uploads two DMG artifacts. Each DMG contains
`DustWatch.app` and an `Applications` shortcut for drag-and-drop install:

- `DustWatch-v0.1.1-x86_64.dmg`
- `DustWatch-v0.1.1-arm64.dmg`

## Caveats

- **GPU frequency on Apple Silicon** is not exposed by SMC. The app
  records GPU temperature and an approximate GPU load, but no per-sample
  GPU frequency. The P-State bucketing for the alert uses CPU P-State
  only.
- **First month**: no alerts will fire for the first ~30 days because
  the baseline period needs data. The **Live** tab still works.
- **Ad-hoc signing**: if you move the app to another machine, you'll
  need to re-run Gatekeeper approval there.
- **SMC read status on macOS 26 (Tahoe)**: Apple removed the user-space
  `AppleSMC.framework` that older tools depended on. The app falls back
  to direct `IOConnectCallStructMethod` calls against the IOAppleSMC
  kext, using a struct layout reverse-engineered from Macs Fan Control.
  On macOS 26 the kext returns kIOReturnSuccess but the data buffer
  echoes a fixed byte (0x84) for every key, so the **SMCReader
  self-test detects this and disables SMC reads for the session**.
  CPU and GPU load (from `host_processor_info` and a busy-loop proxy)
  still work, and the SQLite store, charts, and alert logic all
  function correctly. To get SMC sensors working, the exact field
  offsets in the 80-byte struct need further reverse engineering
  against this specific macOS version's kext — that's left as a
  follow-up.

## Project layout

```
dustwatch-mac/
├── Package.swift              SPM manifest
├── build.sh                   Build + bundle + ad-hoc sign
├── Sources/
│   ├── App/                   Entry point & AppDelegate
│   ├── SMC/                   IOKit → AppleSMC interface
│   ├── Storage/               SQLite layer + auto-aggregation
│   ├── Sampler/               1-min timer loop
│   ├── Analysis/              Mann-Whitney U thermal-degradation detector
│   ├── Notifications/         UNUserNotificationCenter wrapper
│   ├── UI/                    Menu bar, popover, main window, charts
│   │   ├── MenuBarController.swift
│   │   ├── PopoverView.swift
│   │   ├── MainWindowView.swift
│   │   ├── OverviewView.swift        ← at-a-glance dashboard
│   │   ├── ChartsView.swift          ← live + history + compare
│   │   ├── HeatmapView.swift         ← calendar heatmap
│   │   ├── ConfigView.swift
│   │   ├── CSVExporter.swift
│   │   └── HotKeyManager.swift
│   └── Resources/             Info.plist + entitlements (build-time only)
└── README.md
```

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgements

The SMC reading layer follows the same approach as
[beltex/SMCKit](https://github.com/beltex/SMCKit) and the
[smc-fan-control](https://github.com/hholtmann/smcFanControl) family of
utilities — community-documented bindings to Apple's private
`AppleSMC.kext` interface.
