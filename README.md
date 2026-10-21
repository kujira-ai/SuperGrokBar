# SuperGrok Bar

macOS **menu bar** monitor for SuperGrok / Grok Build usage credits.

![menu bar](https://img.shields.io/badge/macOS-14%2B-blue) ![license](https://img.shields.io/badge/license-MIT-green)

- Menu bar only (no web dashboard)
- Grok/xAI mark + live Grok Bot and Grok Build usage %
- Reads `~/.grok/auth.json` for Grok Build credits and Grok Bot / Cursor.app's local session for Grok Bot weekly usage
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
- Optional: [Codex CLI](https://github.com/openai/codex) logged in with ChatGPT (`codex login` → `~/.codex/auth.json`) for ChatGPT/Codex quota
- For source/Homebrew builds: Xcode / Swift toolchain

## Menu

| Item | Action |
|------|--------|
| Grok Bot / Grok Build / Plan / Account | Live Grok Bot weekly pool plus grok.com Build credits |
| Codex 5h / Codex weekly | ChatGPT/Codex remaining % for the 5-hour and weekly windows (hidden if Codex isn't logged in) |
| Refresh | Re-fetch usage now |
| Open Grok Bot Plan… | Opens the Grok Bot plan screen |
| Open Cursor Spending… | Opens cursor.com spending (Grok Bot bar) |
| Open grok.com Usage… | Opens grok.com usage |
| Link SuperGrok… | Shown when this Cursor account has no Bot pool |
| Launch at Login | Toggle auto-start |
| Quit | Exit |

## CLI: quota for agents

```bash
supergrok-bar quota          # human-readable
supergrok-bar quota --json   # stable JSON
# or call the binary directly (headless, never launches the UI):
SuperGrokBar quota --json
```

Exit code is `0` if at least one provider returned data, `1` if all failed.
Per-provider failures are reported in that provider's `error` field.

JSON schema (`schema_version: 1`):

```jsonc
{
  "schema_version": 1,
  "generated_at": "2026-10-13T19:00:45Z",       // ISO 8601 UTC
  "providers": [                                 // always these 3, in this order
    {
      "id": "grok_build" | "grok_bot" | "codex",
      "label": "Grok Build" | "Grok Bot" | "ChatGPT / Codex",
      "ok": true,                                // false => see "error"
      "error": null,                             // string when ok == false
      "plan": "plus",                            // or null
      "source": "api" | "session_log" | null,    // codex falls back to ~/.codex/sessions logs
      "limit_reached": false,                    // codex only
      "windows": [
        {
          "name": "credits" | "weekly" | "5h",   // grok_build: credits; grok_bot: weekly; codex: 5h + weekly
          "used_percent": 23.0,
          "remaining_percent": 77.0,
          "resets_at": "2026-10-13T23:05:03Z",   // or null
          "window_minutes": 300                  // or null
        }
      ]
    }
  ]
}
```

Codex quota comes from `GET https://chatgpt.com/backend-api/wham/usage` (the endpoint Codex CLI uses
for `/status`), authenticated with the access token and `chatgpt-account-id` from `~/.codex/auth.json`
(respects `$CODEX_HOME`). The file is only read, never refreshed. If the request fails, the newest
`rate_limits` event in `~/.codex/sessions/**/*.jsonl` is used (`"source": "session_log"`).

### Grok Build login auto-refresh

The `~/.grok/auth.json` access token lasts ~6 hours. When it is expired or within 2 minutes of expiry
(and on a 401), SuperGrok Bar and `quota` silently refresh it the same way the `grok` CLI does:
discover `token_endpoint` from `{oidc_issuer}/.well-known/openid-configuration` (`https://auth.x.ai/oauth2/token`),
then `POST` form `grant_type=refresh_token&refresh_token=…&client_id=<oidc_client_id>` (public client, no secret).
The new `key`, rotated `refresh_token`, and `expires_at` are written back into the same entry, other fields are
kept, and the file stays mode `0600`. If refresh is rejected, run `grok login` again.
`supergrok-bar quota --refresh-grok` forces a refresh.

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
./Scripts/package-release.sh 1.2.3
```

## Notes

- Polls about every 60 seconds.
- Menu bar stays tiny: the icon plus the single most-constrained quota (highest used %) across Grok Bot,
  Grok Build, and Codex 5h/weekly, e.g. `42%` (Grok Bot), `64%ᴮ` (Grok Build), `78%ᶜ` (Codex). Unavailable
  sources are skipped. Hover for the full breakdown; the dropdown lists every pool. Network to `grok.com` (Build credits) and `cursor.com` (`/api/dashboard/get-sand-usage-status` for Grok Bot). Grok Bot usage is metered on Cursor, not grok.com. Link SuperGrok on the Grok Bot plan screen if the bar says "link".
- Independent of [onWatch](https://github.com/onllm-dev/onwatch).

## Logo

Menu bar icon uses the public Grok/xAI mark (see `Sources/SuperGrokBar/Resources/ATTRIBUTION.txt`).  
Official brand materials: [xAI Brand Guidelines](https://x.ai/legal/brand-guidelines).

## License

MIT — see [LICENSE](LICENSE).
