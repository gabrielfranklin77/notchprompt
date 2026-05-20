# Screen-Share Privacy — Test Matrix

This is the **honest** state of Privacy Mode in Notchprompt Pro. The teleprompter
overlay sets `NSWindow.sharingType = .none` plus a few defensive flags, but Apple
changed the rules of the game in macOS 15: **ScreenCaptureKit ignores
`sharingType = .none`**. There is no public Apple API that lets a window opt
out of ScreenCaptureKit while remaining App-Store-compliant.

This means:

| Capture mechanism | Hidden by Privacy Mode? |
|---|---|
| Legacy `CGWindowListCreateImage` (used by macOS ≤ 14 screenshot tools and most older versions of Zoom/Teams/Meet) | ✅ Yes |
| macOS ≤ 14 Zoom / Teams / Google Meet / Webex full-screen share | ✅ Yes (best effort) |
| Native screenshot (`Cmd+Shift+5`) and `Preview` capture on macOS ≤ 14 | ✅ Yes |
| Any **macOS 15+** app using ScreenCaptureKit | ❌ **No** — Apple-level limitation |
| OBS Studio (macOS Screen Capture source) on macOS 15+ | ❌ No |
| QuickTime Screen Recording on macOS 15+ | ❌ No |
| CleanShot X, Loom, Riverside.fm on macOS 15+ | ❌ No |
| Mission Control / Exposé snapshots | ✅ Yes (extra `.transient` flag) |

We document this prominently because **overpromising privacy is a security
problem**. Test the apps you actually use before relying on Privacy Mode for
sensitive content.

---

## How to run the matrix

1. Build the app: `xcodebuild -project notchprompt.xcodeproj -scheme notchprompt -configuration Debug build`.
2. Launch the built app from Xcode (⌘R) or from `Library/Developer/Xcode/DerivedData/notchprompt-*/Build/Products/Debug/notchprompt.app`.
3. Toggle Privacy Mode with `⌥⌘H` (status item shows the indicator).
4. For each row below, follow the **How to test** column and mark ✅ or ❌.

| App | Capture type | How to test | macOS version tested | Result |
|---|---|---|---|---|
| Zoom | Full Screen share | Start meeting → Share Screen → Desktop → check preview window thumbnail | | ☐ |
| Zoom | Window share | Start meeting → Share Screen → individual window (NOT the overlay) → confirm overlay not visible | | ☐ |
| Google Meet (Chrome) | Tab share | Meet call → Present → Tab → confirm overlay doesn't bleed in | | ☐ |
| Google Meet (Chrome) | Window share | Meet → Present → Window | | ☐ |
| Google Meet (Chrome) | Entire screen | Meet → Present → Entire screen | | ☐ |
| Microsoft Teams | Screen share | Teams call → Share → Screen | | ☐ |
| QuickTime Player | Screen Recording | `File → New Screen Recording` → Record → stop → review video | | ☐ |
| `Cmd+Shift+5` | Capture Entire Screen | Take screenshot → open in Preview | | ☐ |
| `Cmd+Shift+5` | Record Entire Screen | Record short clip → review | | ☐ |
| OBS Studio | macOS Screen Capture (SCK) | Add source → macOS Screen Capture → check preview | | ☐ |
| OBS Studio | Window Capture | Add source → Window Capture → list windows; overlay should be absent | | ☐ |
| CleanShot X | Capture screen | Capture → All Screens → review thumbnail | | ☐ |
| Loom | Screen + cam | Start a recording → preview frame | | ☐ |
| Mission Control | Exposé All Windows | F3 / four-finger swipe up → confirm overlay not in the tile grid | | ☐ |
| Cmd+Tab app switcher | — | Cmd+Tab → confirm "notchprompt" doesn't show in the switcher | | ☐ |

---

## Known false positives

- **OBS Studio "Window Capture"**: even with `sharingType = .none`, the
  list of capturable windows may *list* the panel name briefly, but
  selecting it should return an empty/black surface. If you see content,
  file a bug with the OBS version.

- **Built-in screenshot saved to clipboard**: `Cmd+Ctrl+Shift+3` uses a
  legacy path and respects `sharingType` consistently on macOS ≤ 14.

---

## What we'd love help with

If you find an app/version combination where Privacy Mode silently fails
(content visible in a screen-share that we expected to hide), open a
GitHub issue with:

- macOS version (`sw_vers`)
- App + version of the capture tool
- Reproducible steps
- Screenshot of the leaked frame

We'll update this matrix as we learn.
