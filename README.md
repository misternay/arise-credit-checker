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
- Xcode Command Line Tools (`xcode-select --install`)

## Build & run

```bash
git clone <this-repo> arise-credit-checker
cd arise-credit-checker
./build.sh
open ".build/Arise Credit.app"
```

A 🔑 icon appears in the menu bar. Click it → **Add account… (⌘N)** → paste your key.

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
