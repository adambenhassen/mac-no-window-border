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

NoBorder.app is the whole product: no daemon, no debugger, no child process. The app looks at the
window list, decides which windows to change, and makes the changes **inside the app that owns the
window**, in that app's own main thread.

- **Which windows:** every 250 ms the app lists the on-screen windows of layer 0 and compares each
  frame with every screen's `NSScreen.visibleFrame`, within 2 pt. A window has to stay in that state
  for 0.5 s before anything is done, in either direction, so a window you are dragging is never
  fought over.
- **The three changes**, made in one sequence inside the app: `setHasShadow:NO` on the window takes
  the outline and shadow away, `_setCornerRadius:0.01` squares the corners, and
  `drawsDecorationView = NO` on the titlebar container removes the rim. Passing `YES` / `0` / `YES`
  puts each back. All three are ordinary AppKit calls, run where AppKit expects to be run: the app's
  main thread.
- **How the thread is persuaded:** the app opens the target's task port (`task_for_pid`, which is why
  SIP must be off), finds its main thread, and reads its registers. It only goes on when that thread
  is *parked* in its run loop — asleep in the kernel inside the run-loop's Mach call, with
  `__CFRunLoopServiceMachPort` in the frames above it. It writes generated arm64 code and its data
  into the target, along with a private stack, ends the kernel call the thread is parked in so the
  kernel returns it to user space at the code, and the code makes the calls, writes a completion
  flag, restores the app's own registers and jumps back to the **start** of the run-loop wait it was
  in. The app re-issues its own call and is never left in the middle of one. Nothing is read from the
  thread; the answer is read from memory.
- **Nothing runs in a busy app.** If the main thread is not parked, the window is left exactly as it
  is and asked about again on a later scan, with no cap on the deferral. A call that faults is caught
  by the exception handler NoBorder installs for the duration of that run: the thread's saved state is
  restored, the app never sees the fault, and the log says `engine failed`.
- **Signing:** the app is signed with `com.apple.security.cs.debugger`, which is what lets it use
  `task_for_pid`. That, plus SIP being off, is the whole privilege it needs.

### Costs and limits

- A window is changed when its app's main thread is next idle, and the change is a short sequence of
  AppKit calls, not a debugger pause. It is not something you feel.
- The honest numbers: entering the app and handing its thread back costs its main loop about 4 ms
  (measured against a no-engine baseline of the same shape). The AppKit calls themselves keep that
  app's main loop busy for hundreds of milliseconds on a full-screen window — gaps of up to 290 ms
  were measured on a test app. v1.1 did the same work and paid for it with a ~3.5 s debugger stop,
  which is the number this release removes.
- NoBorder runs nothing inside an app that is busy, so a window of a busy app changes when that app
  next parks. It is asked about again for as long as it stays in the state that needs the change.
- There is no launch grace: a newly launched app's maximized window can change within a second. The
  park check is the guard, not a waiting period.
- If an app puts its own outline back, NoBorder cannot see that: the shadow state lives in the app,
  and there is no WindowServer tag to read. Reopening the window, moving it, or toggling NoBorder
  applies it again.
- Quitting, turning NoBorder off, and the app being terminated all ask every app to put its windows
  back. A `kill -9` leaves them changed, and a later NoBorder does not know about them: reopen those
  windows once.
- Only AppKit windows change corners, including Chromium and Electron apps. Others keep them.
- Uses private AppKit and SkyLight APIs. If a macOS update removes one, that step is skipped and the
  app is not touched — a window can end up with square corners and a rim, never with a crashed app.

## Development

```sh
make test                           # Swift unit tests, the probe checks, the engine checks
make testtools && tests/e2e.sh      # end-to-end: the engine driven by the probe
make testtools && NOBORDER_E2E=app tests/e2e.sh         # the built app (touches your windows; quit NoBorder first)
make bench                          # how long the engine stops a test app's main loop
make release                        # build/NoBorder.zip for a GitHub release
```

| Path | What it is |
|---|---|
| `app/Sources/NoBorderLogic` | the scanner, the tracker, the 250 ms scan loop |
| `app/Sources/NoBorderEngine` | task port, park check, generated arm64 call script, fault guard |
| `app/Sources/NoBorder` | the menu bar app |
| `tests/` | unit tests, the test app, the end-to-end, probe, engine and benchmark scripts |
| `docs/` | website (GitHub Pages) |
