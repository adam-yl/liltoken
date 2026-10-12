# Lil Token

A small macOS menu-bar app for checking your Claude and Codex allowance.
Double-tap Option to show a glass popup in the upper-right corner. It fades
after five seconds; hover to keep it open.

## Features

- Claude session and weekly usage, when available from Claude Code.
- Codex allowance on your signed-in ChatGPT account.
- On-demand Refresh, cached readings with their age, and reset times.
- A menu-bar shortcut and optional native launch at login.
- Light-gray glass, purple accents, and a Reduce Transparency fallback.

The ChatGPT section shows **Codex limits**, not every ChatGPT model's chat
quota. Provider rows display usage only; clicking them does not switch apps.
This is an independent personal utility, not an official OpenAI or Anthropic app.

## Requirements

- macOS 13 or later. Native glass is used on macOS 26; older systems use popover material.
- Swift/Xcode Command Line Tools with the macOS 26 SDK to compile the glass API.
- Python 3.9 or later for validation scripts; build scripts use `/usr/bin/python3`.
- A signed-in Codex desktop installation for Codex usage.
- Claude Code's native installer and subscription sign-in for Claude usage.

Claude's on-demand usage control is experimental and version-sensitive. Lil Token
checks the installed executable's signature and the usage-only code path before
launching it. An unsupported update fails closed and preserves the last reading.

## Build and run

Clone this repository into a normal local directory without symlinks in its path:

```sh
git clone https://github.com/adam-yl/liltoken.git
cd liltoken
bash scripts/build.sh
bash scripts/launch.sh
```

The build creates `.build/Lil Token.app`. Keep it inside this checkout: the build
embeds the checkout location so the app can keep its own state there. If you move
the checkout, rebuild. No external packages are required.

The first launch has no live account connections. After reviewing the privacy
details below, enable the connections you want:

```sh
mkdir -p .runtime
chmod 700 .runtime
printf approved > .runtime/live-enabled
# Optional: also enable on-demand Claude checks.
printf approved > .runtime/claude-live-enabled
chmod 600 .runtime/*-enabled
```

Quit Lil Token from its menu and launch it again. Sign in through the providers'
own apps or CLI; never put passwords, API keys, or tokens in this repository.
If Claude is unavailable, use `claude auth login` in Terminal and press Refresh.

For double-Option, add `.build/Lil Token.app` in **System Settings → Privacy &
Security → Accessibility**, enable it, then click its menu-bar icon once.
Locally ad-hoc-signed rebuilds can require removing and re-adding the app there.
The menu-bar icon works as another way to open the popup. Right-click it to
enable **Launch at login** or quit.

To change the fade delay without rebuilding, put a number from 0.5 to 60 in
`.runtime/popup-delay-seconds`. The default is five seconds.

## Optional Claude statusline

The passive connection accepts Claude Code's documented statusline JSON and
keeps only rate-limit fields. Generate the configuration for your checkout:

```sh
python3 scripts/statusline-config.py
```

Manually merge the printed `statusLine` entry into your Claude Code settings,
preserving any other settings. The script only prints JSON; it does not edit
your settings. If you already have a statusline, review how to combine them
before replacing it. Restart your Claude Code session afterward.

Passive readings reflect the last reported allowance. When enabled, the
on-demand connection takes priority and a failed refresh does not make old
data appear fresh.

## Privacy and data flow

- Lil Token sends no prompts and does not start AI conversations.
- It does not read conversation files, copy credentials, capture screenshots,
  inspect window contents, or record keystrokes. The Option detector retains
  only transient timing/key-state information needed to reject typing chords.
- Codex checks start its bundled `app-server`, read account rate limits, and
  shut down the helper.
- Claude checks use its own CLI sign-in and experimental `get_usage` control
  with `skip_behaviors: true`. Tools, normal hooks, MCP connections, session
  persistence, telemetry, error reporting, and updates are disabled for that
  helper. Existing provider privacy restrictions remain respected.
- Provider helpers may use or refresh their own credentials and write their
  normal state outside this checkout. Enabling live connections permits those
  provider operations; it does not make those vendor tools sandboxed.
- The app stores normalized percentages, reset times, freshness timestamps,
  connection flags, and limited configuration health inside `.runtime`.
  Lil Token does not save raw protocol responses. Provider-helper logs and caches
  may be created under `.build` and stay ignored. Usage checks run on
  opening/Refresh, with throttling, rather than continuous polling.
- `.runtime`, `.build`, credentials, and generated binaries are excluded from
  Git. The public repository contains source and synthetic tests only.

## Development

```sh
bash scripts/test.sh
bash scripts/render-preview.sh
/usr/bin/python3 Tests/statusline-smoke.py  # after building
```

The normal suite uses synthetic fixtures and mock provider processes. It does
not query real AI accounts or install global keyboard monitors. Generated
files stay inside `.build`; some tests remove their own temporary fixtures.
`Tests/ClaudeLiveCheck.swift` is a separate manual integration tool, not part of
the test suite. Run it only if you deliberately want a real account check.

Before committing, stage the intended files and inspect the staged source:

```sh
git diff --cached
python3 scripts/check-public-files.py
```

The checker inspects staged bytes for unexpected files, binaries, personal home
paths, private email addresses, and common credential formats. It is an extra
check, not a guarantee that every possible secret can be detected. Never add
real account fixtures or force-add runtime/build files. Use a GitHub noreply
email for commits if you want to keep your personal email private.

## References

- [Claude Code statusline](https://code.claude.com/docs/en/statusline)
- [Codex app-server](https://learn.chatgpt.com/docs/app-server)
- [GitHub commit email privacy](https://docs.github.com/en/account-and-profile/how-tos/email-preferences/setting-your-commit-email-address)

## License

MIT. See [LICENSE](LICENSE).
