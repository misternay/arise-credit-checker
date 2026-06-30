# Arise Credit Checker

A minimal, **native macOS menu bar app** — written in Swift / AppKit, with zero
runtime dependencies and no Python. Click the menu-bar total and a native
dropdown shows the remaining credit on every Arise (LiteLLM) API key you add.

It polls each account's gateway:

```
GET <base_url>/key/info
Authorization: Bearer <your-key>
```

…and computes **remaining = `max_budget − spend`** (USD). Keys with no budget
cap show total `spend` instead.

---

## Install

### Option A — Homebrew (recommended)

```bash
brew install --cask misternay/tap/arise-credit-checker
```

Then clear the quarantine flag and open from Spotlight / Launchpad:

```bash
xattr -dr com.apple.quarantine "/Applications/Arise Credit.app"
```

> **Why the `xattr` step?** This app is **unsigned** (no paid Apple Developer
> ID). Homebrew downloads it with the `com.apple.quarantine` flag attached, and
> on macOS 12+ an unsigned + quarantined app is reported as **"damaged and can't
> be opened"** — macOS will offer to move it to Trash, even though the download
> is perfectly intact. The `xattr` line clears that flag and the app opens
> normally.
>
> *(Older Homebrew versions supported `brew install --cask --no-quarantine`,
> but Homebrew 4.4+ removed that flag, so the `xattr` line is the reliable
> method.)*

### Option B — Download

Grab the latest `.dmg` from the
[Releases page](https://github.com/misternay/arise-credit-checker/releases):

1. Open the `.dmg` and drag **Arise Credit.app** to **Applications**.
2. **First launch only** — this app is **unsigned** (no paid Apple Developer ID),
   so on macOS 12+ macOS will report it as **"damaged and can't be opened"** and
   offer to move it to Trash. The download is fine — that message is macOS's way
   of blocking an unsigned, quarantined app. Clear the quarantine flag and it
   opens normally:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Arise Credit.app"
   ```
   (On macOS 11 Big Sur and earlier the old right-click → **Open** → confirm
   workflow still works; on 12+ the `xattr` line is the reliable path.)

### Option C — Build from source

```bash
git clone https://github.com/misternay/arise-credit-checker
cd arise-credit-checker
./build.sh
open ".build/Arise Credit.app"
```

Requires Xcode Command Line Tools (`xcode-select --install`).

---

## Features

- **Native menu bar dropdown** — one click, everything inline. No separate window.
- **Multiple accounts** — each key gets its own row with status + balance, and
  a detail submenu (remaining / spent / budget / % used / alias / models).
- **Status dots** — 🟢 healthy · 🟡 near limit (≥70%) · 🔴 critical (≥90%) · 🔵 uncapped · ⚠️ error.
- **Native Add/Edit windows** — real `NSTextField` + `NSSecureTextField`, not text prompts.
- **Keyboard shortcuts** — ⌘N add account · ⌘R refresh · ⌘Q quit.
- **Auto-refresh** every 5 minutes.
- **Robust parser** — handles every LiteLLM response envelope (`key_info.token`,
  `info.token`, root) and pulls `max_budget` from the top level or
  `litellm_budget_table`. Dumps the raw response to disk for debugging.
- **Tiny** — ~230 KB arm64 binary, no Python, no Electron, no webview.

---

## Requirements

- macOS 12.0+
- (Building from source only) Xcode Command Line Tools (`xcode-select --install`)

Once installed by any method above, a 🔑 icon appears in the menu bar. Click it →
**Add account… (⌘N)** → paste your key.

---

## Releasing a new version

Maintainers cut a release with:

```bash
# 1. bump version
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.1.0" Info.plist

# 2. build universal .zip + .dmg + sha256sums into dist/
./build-release.sh 1.1.0

# 3. publish (uploads assets, creates tag)
gh release create v1.1.0 dist/*.zip dist/*.dmg dist/sha256sums.txt \
    --title v1.1.0 --notes "..."

# 4. update the Homebrew cask at misternay/homebrew-tap:
#    bump version + replace sha256 with the new zip's checksum
```

---

## How it looks

```
🔑                            ← menu bar (🔑 until you add a key)
 ┌──────────────────────────────────────────┐
 │ $129.66 remaining · 1 uncapped · 12:07   │  ← header line
 ├──────────────────────────────────────────┤
 │ Accounts                           ▸      │
 │                                           │
 │  Add account…             ⌘N             │
 │  Refresh now              ⌘R             │
 │  ─────────────────                        │
 │  Quit Arise Credit        ⌘Q             │
 └──────────────────────────────────────────┘
```

`Accounts ▸` opens a submenu with one row per key:

```
 🟢  Work-Prod        $87.66   ▸
 🟡  Personal         $42.00   ▸
 🔵  Uncapped   $5.20 spent   ▸
```

Each row leads to detail (remaining / spent / budget / % used / alias / models)
plus **Edit…** and **Remove**.

---

## Where data is stored

`~/Library/Application Support/Arise Credit/settings.json` — a plain JSON file
listing your accounts (same schema the earlier Python prototype used).

A debug dump of the last API response is written to
`~/Library/Application Support/Arise Credit/last_response.json` on every fetch.
If a key ever shows ⚠️ "could not parse", inspect that file to see exactly
what your gateway returned.

## Run at login

The build produces a real `.app` bundle, so:
**System Settings → General → Login Items → add “Arise Credit.app”.**

---

## Project layout

```
.
├── Sources/AriseCreditChecker/main.swift   # the whole app: models, polling, UI
├── Info.plist                              # bundle metadata; LSUIElement=true (no Dock icon)
├── build.sh                                # compiles to .build/Arise Credit.app
└── README.md
```

The entire application is a single Swift file — no packages, no SPM manifest,
no dependencies beyond the macOS SDK.

## Customising

| What                | Where in `main.swift`                  |
|---------------------|----------------------------------------|
| Default gateway URL | `defaultBaseURL`                       |
| Poll interval       | `pollInterval` (seconds; default 300)  |
| Status glyphs       | `glyph(for:)`                          |

## License

MIT.
