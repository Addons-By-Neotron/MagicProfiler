# Magic Profiler

A LibDataBroker data source that displays addon CPU and memory usage in World of Warcraft.

## Requirements

- An LDB display addon such as [ButtonBin](https://www.curseforge.com/wow/addons/button-bin), [ChocolateBar](https://www.curseforge.com/wow/addons/chocolate-bar), or [Titan Panel](https://www.curseforge.com/wow/addons/titan-panel)
- Retail WoW (uses `C_AddOnProfiler` for CPU data)

## Features

**LDB display** — Shows total addon CPU % in your LDB bar. Displays "Profiler N/A" if the WoW addon profiler is disabled.

**Hover tooltip** — Shows the top 20 addons by CPU usage with memory alongside. Falls back to memory-only if the profiler is unavailable.

**Top window** — Click the LDB button to open a sortable, scrollable table of all loaded addons with columns:

| Column | Description |
|---|---|
| Addon | Addon name |
| CPU (current) | Recent average CPU % |
| CPU (session) | Session average CPU % |
| Memory | Current memory usage |
| Mem Delta | Change since last memory refresh |

The window is movable and resizable (height only).

**Load snapshot** — Captures CPU and memory usage at 1s and 5s after login for diagnosing load-time cost. Use the **On-Load** button to toggle between live and snapshot view. The snapshot view shows:

| Column | Description |
|---|---|
| Addon | Addon name |
| CPU (1s) | CPU % at 1 second after load |
| CPU (5s) | CPU % at 5 seconds after load |
| Memory | Memory at 5 seconds after load |

**Create Snapshot** — Reloads the UI and automatically opens the snapshot view afterward, letting you capture a clean load profile.

## Controls

- **Left-click** LDB button: Open/close the Top window
- **Hover** LDB button: Show tooltip (auto-hides when mouse leaves)
- **1s / 3s / 5s / 10s** buttons: Set the live update interval
- **Refresh Mem** button: Manually refresh memory data (not updated automatically)
- **On-Load** button: Toggle snapshot view (enabled after 5s post-login)
- **Create Snapshot** button: Reload UI and open snapshot view on next login
- **Column headers**: Click to sort; click again to reverse sort
- **Drag title bar**: Move the window
- **Resize grip** (bottom-right): Resize window height

## Color coding

CPU values are color-coded in both the tooltip and the Top window:

- Green — below 1%
- Yellow — 1–5%
- Red — 5%+
