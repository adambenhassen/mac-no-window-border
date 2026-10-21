<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="NoBorder app icon">
</p>

<h1 align="center">NoBorder</h1>

<p align="center">
  <strong>The look of fullscreen, without fullscreen mode.</strong><br>
  Maximized macOS windows go edge to edge: no outline, no rounded corners, no titlebar rim.
</p>

<p align="center">
  <a href="https://github.com/adambenhassen/mac-no-window-border/releases/latest"><img src="https://img.shields.io/github/v/release/adambenhassen/mac-no-window-border?label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey" alt="macOS 14 or later">
  <a href="https://adambenhassen.github.io/mac-no-window-border/"><img src="https://img.shields.io/badge/website-online-6e45e2" alt="Website"></a>
</p>

<p align="center">
  <a href="https://adambenhassen.github.io/mac-no-window-border/">Website</a> ·
  <a href="https://github.com/adambenhassen/mac-no-window-border/releases/latest/download/NoBorder.zip">Download</a> ·
  <a href="#install">Install</a> ·
  <a href="#how-it-works">How it works</a>
</p>

<p align="center">
  <img src="docs/comparison.png" width="820" alt="Two MacBooks with a maximized window: without NoBorder the window has rounded corners and an outline; with NoBorder it fills the screen edge to edge">
</p>

## Features

- **No outline or shadow:** removes the 1px gray line WindowServer draws around windows.
- **Square corners:** a maximized window meets the screen edge with no wallpaper showing through.
- **No titlebar rim:** removes the light highlight along the titlebar's top edge (and the line
  under the titlebar).
- **Window buttons, optional:** a menu toggle hides the close/minimize/zoom buttons on maximized
  windows, and shows them again when it is turned off — including on a window that never left.
- **Maximized windows only:** a window counts as maximized when it fills its screen's usable area
  (below the menu bar, beside the Dock). Every other window keeps the normal macOS look.
- **Reversible:** a window that stops being maximized gets back exactly what NoBorder changed. If
  its app is busy at that moment, NoBorder asks again on a later scan — a window is deferred,
  never dropped. Turning NoBorder off or quitting it does the same.
- **Unlike fullscreen mode,** the menu bar and Dock stay put, the window stays on your current
  Space, and nothing slides away.

## Requirements

- macOS 14 or later (tested on macOS 15).
- System Integrity Protection disabled, so NoBorder can open the task port of the apps whose windows
  it changes while running as your normal user. No boot-args, no reboot beyond disabling SIP.

> [!WARNING]
> Disabling SIP weakens macOS security. Read Apple's
> [Disabling and Enabling System Integrity Protection](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection)
> before you do it.

## Install

**Download:** get [NoBorder.zip](https://github.com/adambenhassen/mac-no-window-border/releases/latest/download/NoBorder.zip),
unzip it, move `NoBorder.app` to Applications and open it. It isn't notarized, so macOS blocks
the first launch: open System Settings › Privacy & Security and click **Open Anyway**.

**Build from source:**

```sh
git clone https://github.com/adambenhassen/mac-no-window-border
cd mac-no-window-border
make install     # build NoBorder.app and copy it to /Applications
open /Applications/NoBorder.app
```

## Usage

The menu bar icon shows the status, and has **Enabled**, **Hide window buttons**,
**Launch at Login** and **Quit**. The buttons option takes effect on the next scan (a quarter
second) and is remembered between runs. The status line says how many windows NoBorder has changed.
Turning it off, quitting, or the app being terminated restores the windows NoBorder changed. A
window whose app is busy at that moment is left as it is and asked about again while NoBorder is
running.

Logs: `~/Library/Logs/macos-no-window-border.log`.

<details>
<summary>Upgrading from v1.1</summary>

**Quit v1.1 from its own menu before you install 2.0.** v1.1 removed the outline by tagging windows
through Dock; 2.0 removes it inside each app and makes no tag calls, so it cannot undo a tag v1.1
left behind. If v1.1 quit cleanly there is nothing to do. If it died, was killed, or the machine
rebooted, those tags stay in WindowServer until you reopen the affected apps' windows once.

</details>

<details>
<summary>Upgrading from the LaunchAgent version</summary>

Remove the old agent first, or two daemons will fight over the same windows:

```sh
launchctl bootout gui/$(id -u)/local.macos-no-window-border
rm ~/Library/LaunchAgents/local.macos-no-window-border.plist
```

Windows changed by the old version (which changed every window) aren't tracked by NoBorder;
restart those apps, or reopen their windows, once.

</details>

## How it works

NoBorder.app is the whole product: no daemon, no child process. The app looks at the window list,
decides which windows to change, and makes the changes **inside the app that owns the window**, in
that app's own main thread — through a small agent it installs there once.

- **Which windows:** every 250 ms the app lists the on-screen windows of layer 0 and compares each
  frame with every screen's `NSScreen.visibleFrame`, within 2 pt. A window has to stay in that state
  for 0.5 s before anything is done, in either direction, so a window you are dragging is never
  fought over.
- **The three changes**, made in one sequence inside the app: `setHasShadow:NO` on the window takes
  the outline and shadow away, `_setCornerRadius:0.01` squares the corners, and
  `drawsDecorationView = NO` on the titlebar container removes the rim. Passing `YES` / `0` / `YES`
  puts each back. All three are ordinary AppKit calls, run where AppKit expects to be run: the app's
  main thread.
- **The resident agent.** The first time NoBorder needs to change a window of an app, it opens that
  app's task port (`task_for_pid`, which is why SIP must be off) and installs a small agent into it
  once: a message port on the app's own run loop. From then on, every change is a short message to
  that agent, which makes the AppKit calls on the app's main thread when the run loop next services
  it — no per-change thread entry, no debugger pause. The install happens only while the app's main
  thread is parked in its run loop; a faulting install is caught by an exception guard, so the app
  survives it untouched.
- **Focus changes.** When you switch apps, the app that regains focus repaints its own decorations
  over NoBorder's change. NoBorder hears the focus change in-process (`NSWorkspace`) and re-sends the
  change at once, so the border comes back off in milliseconds. Because the agent runs out of
  process, there can be a brief flash before the re-apply lands — AppKit draws the border in the
  focus-change frame, and the re-apply is the next one.
- **Busy apps.** The agent install needs the app's main thread parked; if the app is busy, the
  install is deferred and tried again on a later scan, with no cap on the deferral — the window is
  never damaged, only left as it is until the app is quiet. Once the agent is installed, changes are
  just messages and do not wait on the app being idle.
- **Quit / off.** Turning NoBorder off, quitting, or the app being terminated puts every window it
  changed back and removes the agents it installed.
- **Signing:** the app is signed with `com.apple.security.cs.debugger`, which is what lets it use
  `task_for_pid`. That, plus SIP being off, is the whole privilege it needs.

### Costs and limits

- A change is a message to the agent already resident in the app — ~a millisecond, not a debugger
  pause. Installing the agent is a one-time cost per app, taken while that app's main thread is idle.
- Idle, NoBorder is a 250 ms window-list scan plus an occasional, throttled check of the windows it
  has changed; it is not something you feel.
- If an app repaints its border on a focus change, NoBorder re-applies on that same focus event; a
  brief flash before the re-apply lands is possible (the agent cannot draw in the app's own frame).
- Quitting, turning NoBorder off, and the app being terminated all put the changed windows back and
  remove the agents. A `kill -9` of NoBorder leaves them changed, and a later NoBorder does not know
  about them: reopen those windows once.
- Only AppKit windows change, including Chromium and Electron apps. Others keep their border.
- Hot, always-busy apps may keep deferring the agent install; the window is deferred, never damaged.
- Uses private AppKit APIs. If a macOS update removes one, that step is skipped and the app is not
  touched — a window can end up with square corners and a rim, never with a crashed app.

## Development

```sh
make test                           # Swift unit tests + the probe, engine, agent, blob-agent and focus checks
make testtools && tests/e2e.sh      # end-to-end against a test app: the engine driven by the probe
make testtools && NOBORDER_E2E=app tests/e2e.sh         # the built app (touches your windows; quit NoBorder first)
make release                        # build/NoBorder.zip for a GitHub release
```

| Path | What it is |
|---|---|
| `app/Sources/NoBorderLogic` | the scanner, the tracker, the 250 ms scan loop |
| `app/Sources/NoBorderEngine` | the `ChangeEngine` protocol the scan loop talks to |
| `app/Sources/NoBorderNative` | task port, agent install/removal, the generated arm64 agent, fault guard |
| `app/Sources/NoBorder` | the menu bar app |
| `tests/` | unit tests, the test app, the end-to-end, probe, engine, agent and focus scripts |
| `docs/` | website (GitHub Pages) |
