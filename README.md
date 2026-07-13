# SuperGrok Bar

macOS **menu bar** monitor for SuperGrok / Grok Build usage credits.

![menu bar](https://img.shields.io/badge/macOS-14%2B-blue) ![license](https://img.shields.io/badge/license-MIT-green)

- Menu bar only (no web dashboard)
- Grok/xAI mark + live usage %
- Reads `~/.grok/auth.json` and probes grok.com billing
- Launch at Login via LaunchAgent

## Install

### Homebrew (recommended)

```bash
brew tap kujira-ai/tap
brew trust kujira-ai/tap   # required by modern Homebrew for third-party taps
brew install supergrok-bar
supergrok-bar
```

### One-liner (build from source)

```bash
git clone https://github.com/kujira-ai/SuperGrokBar.git
cd SuperGrokBar
./Scripts/install.sh
```

### Prebuilt app

Download `SuperGrokBar-*-macos.zip` from [Releases](https://github.com/kujira-ai/SuperGrokBar/releases), unzip, and open `SuperGrokBar.app` (or run the included installer).

## Requirements

- macOS 14+
- [Grok CLI](https://x.ai) logged in: `grok login` → `~/.grok/auth.json`
- For source/Homebrew builds: Xcode / Swift toolchain

## Menu

| Item | Action |
|------|--------|
| Usage / Plan / Resets / Account | Live SuperGrok credits |
| Refresh | Re-fetch usage now |
| Open Grok Usage… | Opens grok.com usage |
| Launch at Login | Toggle auto-start |
| Quit | Exit |

## Uninstall

```bash
supergrok-bar uninstall
# or
./Scripts/uninstall.sh
# if installed via Homebrew:
brew uninstall supergrok-bar
```

## Dev

```bash
swift build
swift run SuperGrokBar
./Scripts/install.sh
./Scripts/package-release.sh 1.0.0
```

## Notes

- Polls about every 60 seconds.
- Network only to `grok.com` for your own billing snapshot.
- Independent of [onWatch](https://github.com/onllm-dev/onwatch).

## Logo

Menu bar icon uses the public Grok/xAI mark (see `Sources/SuperGrokBar/Resources/ATTRIBUTION.txt`).  
Official brand materials: [xAI Brand Guidelines](https://x.ai/legal/brand-guidelines).

## License

MIT — see [LICENSE](LICENSE).
