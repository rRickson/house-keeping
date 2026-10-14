# Sweep — macOS Cleaner + Dev Cache Menu Bar: Product Spec

Oct 13, 2026 · @Rickson

## Overview

Sweep is a personal, native macOS app that does everything Kivo does (Clean, Uninstall, Optimize, Analyze, Status) and adds a menu bar extra that reclaims developer caches in one click. It is built for one user: no license, no payments, no telemetry, no update server.

**Goals**

- One click from the menu bar frees every safe developer cache (npm, Yarn, pnpm, pip, uv, Xcode, Homebrew and more) without opening a window.
- Every action shows what will go and how many bytes before anything is deleted.
- Nothing outside a known cache or build-artifact location can ever be deleted.
- Feature parity with Kivo's five tools, plus a project-artifact purge (node\_modules, target, .venv and friends).

**Non-goals**

- Mac App Store distribution. The sandbox blocks access to other apps' caches.
- Malware scanning, RAM "boosters", or anything that runs constantly in the background.
- Multiple users, licensing, or localisation.

**Assumptions**

- Swift 6 and SwiftUI, macOS 14 Sonoma or later, Apple Silicon first (Intel works but is not tested). Built with the macOS 26 SDK so Liquid Glass is used where available.
- Sweep has its own Swift engine. Mole (the MIT-licensed CLI behind Kivo) is the reference for cache rules and safety lists, credited in the About box. The alternative is to shell out to `mo` and only build the UI; that is faster to build but gives less control over sizing, progress and the menu bar flow.
- The app is built and run from Xcode. A paid Developer ID is only needed to share it with others.

## Architecture

One Swift package (SweepKit) holds all scanning and deleting logic; the menu bar, the main window and a CLI are thin front ends on top of it. Admin-only work goes through a small privileged helper that accepts a fixed list of commands, never arbitrary paths.

&#91;embedded content: Sweep architecture · 3 front ends, 1 engine, 1 helper\]

Every front end calls the same pipeline, so every delete passes the Guard before the Executor runs a tool command or touches the disk.

| Module | Responsibility | Key APIs |
| --- | --- | --- |
| SweepKit / Catalog | Declarative rules: one entry per cache, artifact or task (id, group, locate strategy, clean strategy, risk tier, running-process guard) | Codable structs, bundled JSON |
| SweepKit / Resolver | Finds the real location: ask the tool first (`npm config get cache`), then env vars, then the default path | `Process`, `ProcessInfo.environment` |
| SweepKit / Sizer | Allocated size per item, hardlinks counted once, cancellable, reports progress | `getattrlistbulk`, `URLResourceValues.totalFileAllocatedSize`, inode set |
| SweepKit / Guard | Allowlist + deny list check, symlink resolution, running-app check, re-check right before delete | `realpath`, `NSWorkspace.runningApplications`, `libproc` |
| SweepKit / Executor | Runs the tool's own clean command when one exists, otherwise deletes; Trash or permanent | `Process`, `FileManager.trashItem`, `removefile` |
| SweepKit / Ledger | Append-only log of every operation and the bytes freed | JSON Lines in `~/Library/Logs/Sweep/` |
| Metrics | Live CPU, memory, GPU, disk, network, battery, thermals, processes | `host_statistics64`, IOKit, `getifaddrs`, `proc_pid_rusage` |
| App: MenuBarExtra | Quick-clean popover, badge, global hotkey | SwiftUI `MenuBarExtra(.window)` |
| App: Main window | Sidebar with all tools | SwiftUI `NavigationSplitView`, Swift Charts |
| Helper (root) | Flush DNS, system caches, Spotlight, Launch Services, root-owned app removal | `SMAppService.daemon`, XPC, caller code-signature check |
| CLI (`sweep`) | Same engine from the terminal and scripts | Swift ArgumentParser |

**Core data model**

- `CatalogItem`: id, name, group (JavaScript, Python, Apple, JVM, Rust/Go, Containers, Editors, System), locate strategy, clean strategy, risk tier, guards (process names that must not be running).
- `ScanResult`: item, resolved paths, bytes, file count, last modified, status (ready, blocked by running app, missing, permission denied).
- `Operation`: id, date, items, mode (Trash or permanent), bytes freed, failures with reason.

Scans run in a Swift actor per item with a concurrency cap of 4, so the menu bar shows partial sizes as they arrive.

## Menu bar quick-clean

The menu bar popover is the main way Sweep is used: open it, read one number, press one button. Everything in the Safe tier is pre-selected; Caution items are listed but off; Ask items never appear here.

&#91;embedded content: Menu bar popover mockup · example sizes\]

The button total is the sum of the ticked Safe rows; Caution rows are visible but off, and guarded rows explain why they are skipped.

**Menu bar icon**

- A broom glyph. A small dot appears when reclaimable dev caches pass a threshold (default 5 GB).
- Optional display modes: icon only, icon + reclaimable GB, or icon + free disk space.
- Right-click menu: Clean safe caches now, Rescan, Open Sweep, Pause auto-clean, Quit.
- Global hotkey (default ⌃⌥⌘K) runs the quick clean and shows a small confirmation HUD with the total.

**Popover layout (360 pt wide, top to bottom)**

1. Header: disk bar for the startup volume (used / free), time of the last scan, a refresh button.
2. Primary button: "Clean safe caches · 18.4 GB". The number is the sum of the ticked rows and updates live as sizes arrive.
3. Grouped list (JavaScript, Python, Apple, JVM, Rust/Go, Containers, Editors). Each row: tool icon, name, size, risk dot (green Safe, amber Caution), checkbox. Rows under 1 MB are hidden behind "Show empty".
4. Row click expands it: resolved path, last modified, the exact command or delete action, and a per-row Clean button.
5. Projects line: "Build artifacts: 31 GB in 47 projects →" opens the Projects tool in the main window.
6. Footer: Open Sweep, Settings, Quit.

**Behaviour**

- Opening the popover rescans if the last scan is older than 10 minutes; otherwise it shows cached sizes immediately.
- A row whose guard app is running (Xcode for DerivedData, Docker Desktop not running for Docker) shows the reason in place of the checkbox and is skipped.
- Clicking the primary button with only Safe items cleans at once; if any Caution item is ticked, a sheet lists those items first.
- While cleaning, each row shows a spinner and then the bytes freed. When done, a macOS notification says "Freed 18.4 GB from 9 caches" and the operation is written to History.
- Esc closes the popover; ⌘R rescans; Return triggers the primary button.

| State | What the popover shows |
| --- | --- |
| Scanning | Rows fill in as each size arrives; primary button shows a running total and is enabled once any row is ready |
| Ready | Totals, primary button enabled |
| Cleaning | Button becomes a progress bar with Cancel; rows show spinners |
| Done | "Freed X GB" banner for 5 seconds, then back to Ready with new sizes |
| Error | Failed rows in red with the reason (permission, in use, command failed); the rest still clean |

## Developer cache catalog

Sweep ships with 44 catalog entries; each one asks the tool for its real cache location first, so custom paths and env vars are respected, and falls back to the default path only if the tool is not installed. Where a tool has its own clean command, Sweep runs it instead of deleting files, because the tool knows its own locks and indexes.

Risk tiers decide what the one-click button touches:

- **Safe**: rebuilt automatically; the only cost is re-download or rebuild time. Ticked by default in the menu bar.
- **Caution**: rebuilt, but slowly, or breaks offline work until rebuilt. Listed in the menu bar, unticked.
- **Ask**: may hold things you chose or made (models, archives, environments, volumes). Main window only, item by item, never in one click.

| Group | Tool | How Sweep finds it | How Sweep cleans it | Risk |
| --- | --- | --- | --- | --- |
| JavaScript | npm | `npm config get cache` → `~/.npm/_cacache` | `npm cache clean --force` | Safe |
| JavaScript | Yarn 1 | `yarn cache dir` → `~/Library/Caches/Yarn` | `yarn cache clean` | Safe |
| JavaScript | Yarn Berry (2+) | `yarn config get cacheFolder` → `~/.yarn/berry/cache` | Delete folder | Safe |
| JavaScript | pnpm | `pnpm store path` | `pnpm store prune` | Safe |
| JavaScript | Bun | `~/.bun/install/cache` | `bun pm cache rm` | Safe |
| JavaScript | Deno | `deno info` (DENO\_DIR) | Delete folder | Safe |
| JavaScript | node-gyp headers | `~/Library/Caches/node-gyp` | Delete folder | Safe |
| JavaScript | Electron downloads | `~/Library/Caches/electron`, `~/Library/Caches/electron-builder` | Delete folders | Safe |
| JavaScript | Playwright browsers | `~/Library/Caches/ms-playwright` | Delete; restored by `npx playwright install` | Caution |
| JavaScript | Puppeteer browsers | `~/.cache/puppeteer` | Delete folder | Caution |
| JavaScript | Cypress binaries | `npx cypress cache path` | `npx cypress cache clear` | Caution |
| Python | pip | `pip cache dir` | `pip cache purge` | Safe |
| Python | uv | `uv cache dir` | `uv cache prune` (setting: `uv cache clean`) | Safe |
| Python | Poetry cache | `poetry config cache-dir` → `~/Library/Caches/pypoetry` | `poetry cache clear --all <repo>` per repo; skips `virtualenvs/` | Safe |
| Python | Poetry virtualenvs | `<cache-dir>/virtualenvs` | Delete selected envs | Ask |
| Python | Pipenv | `~/Library/Caches/pipenv` | Delete folder | Safe |
| Python | Conda packages | `conda info --json` → `pkgs_dirs` | `conda clean --all -y` | Safe |
| Python | pyenv downloads | `$(pyenv root)/cache` | Delete folder | Safe |
| Python | pre-commit | `~/.cache/pre-commit` | `pre-commit clean` | Safe |
| Python | Hugging Face models | `HF_HOME` → `~/.cache/huggingface` | List models, delete selected | Ask |
| Apple | Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData` | Delete; guard: Xcode not running | Safe |
| Apple | Xcode Archives | `~/Library/Developer/Xcode/Archives` | Delete selected (they hold dSYMs) | Ask |
| Apple | Device support files | `~/Library/Developer/Xcode/*DeviceSupport` | Keep newest version per platform, delete the rest | Caution |
| Apple | Unavailable simulators | `xcrun simctl list devices unavailable` | `xcrun simctl delete unavailable` | Safe |
| Apple | Simulator caches | `~/Library/Developer/CoreSimulator/Caches` | Delete folder | Safe |
| Apple | Simulator runtimes | `xcrun simctl runtime list` | `xcrun simctl runtime delete <id>` | Ask |
| Apple | SwiftPM | `~/Library/Caches/org.swift.swiftpm` | Delete folder | Safe |
| Apple | CocoaPods | `~/Library/Caches/CocoaPods` | `pod cache clean --all` | Safe |
| Apple | Carthage | `~/Library/Caches/org.carthage.CarthageKit` | Delete folder | Safe |
| JVM | Gradle | `GRADLE_USER_HOME` → `~/.gradle/caches`, `~/.gradle/wrapper/dists` | `gradle --stop`, then delete | Caution |
| JVM | Maven | `~/.m2/repository` | Delete folder | Caution |
| JVM | Android emulator images | `~/Library/Android/sdk/system-images`, `~/.android/avd` | Delete selected | Ask |
| Editors | JetBrains caches | `~/Library/Caches/JetBrains/*` | Delete folders of IDE versions no longer installed | Safe |
| Editors | VS Code / Cursor caches | `~/Library/Application Support/{Code,Cursor}/{Cache,CachedData,CachedExtensionVSIXs,logs}` | Delete; guard: editor not running | Safe |
| Rust/Go | Cargo registry | `CARGO_HOME` → `~/.cargo/registry/cache`, `~/.cargo/git/db` | Delete folders | Safe |
| Rust/Go | Go build cache | `go env GOCACHE` | `go clean -cache` | Safe |
| Rust/Go | Go module cache | `go env GOMODCACHE` | `go clean -modcache` | Caution |
| Other | Homebrew | `brew --cache` | `brew cleanup --prune=all` | Safe |
| Other | Composer | `composer config cache-dir` | `composer clear-cache` | Safe |
| Other | RubyGems / Bundler | `gem env`, `~/.bundle/cache` | `gem cleanup` | Caution |
| Containers | Docker build cache | `docker system df` | `docker builder prune -f`; guard: daemon running | Safe |
| Containers | Docker stopped containers, dangling images | `docker system df` | `docker system prune -f` | Caution |
| Containers | Docker volumes | `docker volume ls` | Delete selected | Ask |
| Other | Ollama models | `ollama list` → `~/.ollama/models` | `ollama rm <model>` | Ask |

New tools are added by dropping a JSON entry into `~/Library/Application Support/Sweep/catalog.d/`, so the catalog grows without a rebuild. Paths and commands should be checked against each tool's current docs during implementation.

## Project artifact purge

The Projects tool finds rebuildable folders inside your code directories and deletes them per project, oldest first. A folder is only a candidate when its marker file sits next to it and git does not track it.

| Artifact | Counts only when | Notes |
| --- | --- | --- |
| `node_modules/` | `package.json` in the same folder | Scanner never descends into it |
| `.next/`, `.nuxt/`, `.svelte-kit/`, `.turbo/`, `.parcel-cache/`, `.vite/` | `package.json` present | Framework build caches |
| `.venv/`, `venv/`, `env/` | Contains `pyvenv.cfg` | Recreate with `uv sync` or `pip install -r` |
| `__pycache__/`, `.pytest_cache/`, `.mypy_cache/`, `.ruff_cache/`, `.tox/`, `.nox/` | Any Python project marker | Always safe |
| `target/` | `Cargo.toml` or `pom.xml` present | Rust or Maven output |
| `.build/` | `Package.swift` present | SwiftPM output |
| `build/`, `.gradle/` | `build.gradle(.kts)` or `settings.gradle(.kts)` present | Gradle output |
| `build/`, `dist/` | Listed in the project's `.gitignore` | Generic output; never deleted on name alone |
| `.dart_tool/`, `_build/`, `deps/`, `.terraform/` | `pubspec.yaml`, `mix.exs`, `*.tf` present | Dart, Elixir, Terraform |
| Xcode DerivedData folder for this project | `WorkspacePath` in the folder's `info.plist` matches the project | Lets you clear DerivedData per project |

**Rules**

- Scan roots are set in Settings (defaults: `~/Developer`, `~/Projects`, `~/code`, `~/GitHub`, `~/dev`, only those that exist).
- Projects touched in the last 7 days are marked Recent and unticked. "Purge stale" selects everything untouched for 30+ days.
- Before deleting, Sweep runs `git check-ignore` on each folder. Anything tracked by git is never deleted.
- Symlinked folders are skipped, and Sweep never follows a link to delete its target.
- Purged folders go to the Trash by default, so a mistake is one drag away from undone.
- The list shows project name, path, size per artifact, last modified, and a "Reveal in Finder" action.

## Main window tools

The main window is a sidebar app with nine sections: Overview, Dev Caches, Projects, Clean, Uninstall, Optimize, Analyze, Status and History. Dev Caches is the full version of the menu bar list, including Ask-tier items.

**Overview**

- Disk bar, reclaimable totals per tool, a "Clean all Safe" button, and the last five operations.

**Clean (system junk)**

- User caches in `~/Library/Caches/*`, grouped by app; caches of running apps are skipped.
- Logs (`~/Library/Logs`), crash reports (`~/Library/Logs/DiagnosticReports`), browser caches (Safari, Chrome, Arc, Brave, Firefox, Edge), Mail downloads, `.DS_Store` files.
- Old installers (`.dmg`, `.pkg`, `.zip` installers) in Downloads older than 30 days.
- System caches in `/Library/Caches` through the helper (Caution).
- iOS device backups in `~/Library/Application Support/MobileSync/Backup` (Ask, needs Full Disk Access).
- Trash, listed last.
- Review list sorted by risk, then size; every row has a checkbox and reveals in Finder.

**Uninstall**

- Lists apps in `/Applications` and `~/Applications` with size, bundle ID, version and last opened date (Spotlight `kMDItemLastUsedDate`).
- Finds leftovers by bundle ID and app name in `~/Library/` Application Support, Caches, Preferences, Logs, Containers, Group Containers, HTTPStorages, WebKit, Saved Application State, LaunchAgents, plus `/Library/LaunchAgents`, `/Library/LaunchDaemons` and `/Library/PrivilegedHelperTools`.
- Uses `pkgutil` receipts for apps installed from `.pkg`, and `brew uninstall --zap` for Homebrew casks.
- Quits the app first, removes its Dock entry, moves everything to the Trash.
- Hides system apps; security and antivirus apps link to the vendor's uninstaller instead.
- Orphans view: leftover folders whose bundle ID matches no installed app.

**Optimize**

- One-tap list of maintenance tasks, each with a short description and an admin badge where needed: flush DNS, rebuild Launch Services, reset Quick Look, rebuild font caches, reindex Spotlight, vacuum app SQLite stores, prune old notification history, remove broken launch agents.
- Safety gates: skip Spotlight reindex on battery, skip font cache rebuild while browsers are open, skip network resets while a VPN is active.
- Mole's 22 optimize tasks are the reference list.

**Analyze**

- Squarified treemap of any volume or folder, coloured by file type, with breadcrumb drill-down.
- Sizes use allocated bytes with hardlinks counted once; unreadable folders show a retry badge instead of disappearing.
- Side panel: largest files, largest folders, files untouched for a year.
- Right-click: Move to Trash, Reveal in Finder, Add to exclusions. `/`, `/Users`, `/Applications` and `/System` can never be trashed.
- Shows APFS local snapshots and purgeable space so "missing" space is explained.
- Results cached for 24 hours.

**Status**

- Grid of live metrics with 60-second sparklines (Swift Charts): CPU per core, memory pressure and swap, GPU usage, disk I/O, network in/out, battery charge, health and cycle count, thermal state, uptime.
- Process table refreshed every second, sortable by CPU and memory, with pinning and a Quit Process action.
- Optional mini CPU/memory graph in the menu bar icon.

**History**

- Every operation with date, items, bytes freed and failures, plus a bar chart of space freed per week.

## Visual design

Sweep must look and feel like a first-party Apple app: clean layouts, Liquid Glass on the controls, SF Symbols everywhere, and motion that shows what just happened (space draining away) rather than decorating. Liquid Glass needs macOS 26 Tahoe; on macOS 14 and 15 the same views fall back to system materials.

**Principles**

- Clean: one primary action per screen, at most two font weights per view, spacing instead of borders and dividers wherever possible.
- Glass for controls, not content: popover chrome, sidebar, toolbar, floating action bar and HUD are glass; lists, tables and the treemap sit on plain backgrounds so text stays sharp. Never glass on glass.
- Calm: no red alarm screens, no scary percentages, no fake "threats found".
- Both light and dark mode are first-class; the glass picks up the wallpaper behind it.

**Glass (macOS 26+)**

| Element | Treatment |
| --- | --- |
| Menu bar popover panel | `.glassEffect(.regular, in: .rect(cornerRadius: 20))` |
| Primary "Clean" button | `.buttonStyle(.glassProminent)`, tinted with the accent colour |
| Group filter chips (All, JavaScript, Python, Apple…) | Inside `GlassEffectContainer(spacing: 12)` so neighbours blend; the selection pill slides between chips with `glassEffectID` and a `@Namespace` |
| Main window sidebar and toolbar | Glass automatically when built with the macOS 26 SDK; no custom work |
| Floating action bar ("Clean 12 items · 8.2 GB") | Glass capsule at the bottom of each tool, `.glassEffect(.regular.interactive())` |
| Hotkey clean HUD | Centred glass capsule with the running total, fades out after 2 seconds |
| Fallback on macOS 14–15 | `.ultraThinMaterial` / `.regularMaterial` and `.borderedProminent`, behind one `glassOrMaterial()` view modifier using `if #available(macOS 26, *)` |
| Reduce Transparency on | Solid window background colours, same layout |

**Motion and effects**

- Scanning: sizes count up with `.contentTransition(.numericText())`; rows fade in with a 30 ms stagger.
- Cleaning: each row's size drains to zero, then the row collapses; the disk bar slides to its new value; the header total counts down.
- Done: a short sweep of particles across the popover (SwiftUI `Canvas` + `TimelineView`, about 600 ms) and a bouncing checkmark (`.symbolEffect(.bounce)`).
- Menu bar icon: animated with `.symbolEffect(.variableColor)` while scanning or cleaning, and a single wiggle when the reclaimable threshold is crossed.
- Analyze: treemap tiles zoom into place when drilling down (`matchedGeometryEffect`); hovered tiles lift slightly with a highlight edge.
- Status: sparklines use smooth curves (`.interpolationMethod(.catmullRom)`) with a gradient fill fading to transparent.
- Trackpad haptic (`NSHapticFeedbackManager`) when a clean finishes.
- Timing: everything under 400 ms except the completion sweep. With Reduce Motion on, all of this becomes simple crossfades.

**Icons**

- SF Symbols with hierarchical rendering for all UI. Sidebar: Overview `gauge.with.dots.needle.67percent`, Dev Caches `hammer`, Projects `folder.badge.gearshape`, Clean `sparkles`, Uninstall `trash`, Optimize `bolt`, Analyze `square.split.2x2`, Status `waveform.path.ecg`, History `clock.arrow.circlepath`.
- Tool rows (npm, pip, Xcode…) show small monochrome brand glyphs, tinted to match the theme, with an SF Symbol fallback when a glyph is missing.
- Menu bar: a custom monochrome template icon (a broom), 18 pt, so it adapts to light and dark menu bars.
- App icon: a layered glass icon made in Icon Composer so it renders correctly in the macOS 26 Dock.

**Colour and type**

- One accent colour (mint/teal), user-changeable. Risk colours: Safe green, Caution orange, Ask purple, all system colours so they adapt to dark mode.
- SF Pro for text; big numbers in SF Pro Rounded with `.monospacedDigit()` so totals don't jitter while counting.
- 8 pt spacing grid; corner radii 20 (panels), 12 (cards), capsule (buttons and chips).

## Safety model

Sweep deletes only what a catalog rule explicitly names; everything else is denied by default. The checks below run in SweepKit, so the menu bar, main window and CLI all get them.

1. **Allowlist first.** A path is deletable only if it falls under a catalog rule's resolved location or matches a project-artifact rule. No rule, no delete.
2. **Hard deny list, checked after the allowlist.** `/`, `/System`, `/usr`, `/bin`, `/sbin`, `/Applications` (except via Uninstall), the home folder itself, `~/Documents`, `~/Desktop`, `~/Pictures`, `~/Movies`, `~/Music`, iCloud Drive (`~/Library/Mobile Documents`), `~/.ssh`, `~/.gnupg`, `~/Library/Keychains`, and any `.git` folder. A rule that resolves into one of these is refused and logged.
3. **Symlinks resolved.** Every path goes through `realpath` and both checks run again on the result. Deletion uses no-follow calls, so a link is removed, never its target.
4. **Re-check before acting.** Path, owner and size are re-read right before deletion; if anything changed since the scan, the item is skipped.
5. **Running-process guards.** Items list the apps or processes that must not be running (Xcode, VS Code, Gradle daemon, browsers). Guarded items are skipped with a reason, not force-quit.
6. **Tool commands preferred.** When a tool has its own clean command, Sweep runs it with a 120-second timeout instead of deleting its files.
7. **Preview always.** Every action shows the file list and byte count first. The CLI has `--dry-run` on every destructive command.
8. **Trash vs permanent.** Caches are deleted permanently by default so the space is really freed; Uninstall and Projects go to the Trash by default. Both are switchable in Settings.
9. **Ledger.** Every deletion is written to `~/Library/Logs/Sweep/operations.jsonl` (path, bytes, mode, result).
10. **Narrow helper.** The root helper accepts an enum of named tasks (for example `flushDNS`, `cleanSystemCaches`), checks the caller's code signature, and refuses any raw path or shell string.

**Tests that must pass before any release build**

- A fixture home folder in a temp directory with fake caches, projects, symlink traps (a cache folder linking to `~/Documents`) and git-tracked `build/` folders.
- A property test: for random catalog rules and random trees, no file outside the allowlist is ever removed.
- Guard tests: with a fake Xcode process running, DerivedData is skipped.

## Settings, automation, permissions, CLI

Settings are few and live in one window (⌘,); automation only ever touches the Safe tier.

**Settings**

| Setting | Default |
| --- | --- |
| Tiers included in one-click | Safe |
| Per-tool on/off | All on |
| Notify when reclaimable dev caches exceed | 5 GB |
| Notify when free disk drops below | 10% |
| Auto-clean schedule | Off (options: daily, weekly, when free disk < threshold) |
| Delete mode for caches / uninstall / projects | Permanent / Trash / Trash |
| Project scan roots | Existing folders among `~/Developer`, `~/Projects`, `~/code`, `~/GitHub`, `~/dev` |
| Recent-project protection | 7 days |
| Exclusions | None (any path or catalog id) |
| Menu bar display | Icon + reclaimable GB |
| Global hotkey | ⌃⌥⌘K |
| Launch at login | On |

**Automation**

- Scheduled clean runs inside the app with a timer while it is open; a LaunchAgent (registered with `SMAppService.agent`) can start it headless for weekly runs.
- App Intents expose "Clean dev caches", "Get reclaimable space" and "Purge stale projects" to Shortcuts and Spotlight.

**Permissions**

- Full Disk Access: optional. Needed for Safari, Mail, iOS backups and some app containers. Sweep detects it by trying to read `~/Library/Safari` and shows a one-click link to the System Settings pane.
- Admin: the helper is registered with `SMAppService.daemon` and approved once in System Settings → General → Login Items. Fallback without the helper: `osascript` with administrator privileges, which asks for the password every run.
- Notifications: requested on first clean.

**CLI (`sweep`)**

- `sweep scan --json` prints every catalog item with size and status.
- `sweep clean --tier safe [--dry-run]` and `sweep clean npm pip xcode-deriveddata` for named items.
- `sweep purge ~/Projects --older-than 30d [--dry-run]`.
- `sweep status --json` for piping into other tools.
- Installed by a Settings button that symlinks the bundled binary into `/usr/local/bin`.

## Build plan

The menu bar dev-cache cleaner is usable after about a week; everything in this spec is roughly 25 to 30 working days for one developer with an AI coding assistant. Estimates are rough and assume Swift and SwiftUI familiarity.

1. **Engine core** (3 to 4 days): SweepKit catalog model, resolver, sizer, guard, executor, ledger, fixture tests.
2. **Menu bar MVP** (2 to 3 days): `MenuBarExtra` popover, JavaScript + Python + Xcode + Homebrew entries, one-click Safe clean, notifications. Usable daily from here.
3. **Full dev catalog + Projects** (3 days): remaining catalog entries, project-artifact scanner with `git check-ignore`, Trash flow.
4. **CLI** (1 day): ArgumentParser front end on SweepKit.
5. **Clean + Uninstall** (4 to 5 days): system junk categories, leftover finder, `pkgutil` and Homebrew cask handling, orphans view.
6. **Helper + Optimize** (3 days): `SMAppService.daemon` helper over XPC, task list with safety gates. The fiddliest part.
7. **Analyze** (3 to 4 days): fast directory walker, squarified treemap, drill-down, snapshots and purgeable space.
8. **Status** (3 days): metrics collectors, sparklines, process table.
9. **Settings, automation, polish** (2 to 3 days): settings window, schedules, App Intents, hotkey, History chart, plus 3 to 4 extra days for the glass, motion and icon work in Visual design.

**Testing**

- Unit and property tests on fixture trees run on every build.
- Integration runs in a throwaway macOS VM (UTM or Tart) with real Xcode, Node and Python installed, before running anything on the real Mac.
- First week on the real Mac: dry-run only, compare the reported list with what you expect.

**Distribution**

- Personal use: build and run from Xcode signed with your Apple ID's personal team.
- Open question: whether `SMAppService.daemon` registers with a personal team signature. If not, use the `osascript` fallback until a Developer ID is worth paying for.
- Sharing with others later: Developer ID signing, notarization, Sparkle for updates.
