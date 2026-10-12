# Pace

Claude Code, Codex and Cursor usage in your Mac menu bar and as a desktop widget. Shows when each limit resets, whether you're on track to make it there, and any full resets you have saved up.

<img src="docs/screenshot.png" width="317" alt="Pace in the menu bar">

The tick on each bar is where your usage would be at an even pace. If your current rate would hit the limit before the reset, the row turns orange and says when you'll run out.

Pace reads the sign-ins Claude Code, Codex and Cursor already keep on your Mac and asks the same endpoints those tools use for their own usage pages. It refreshes every minute, never changes their credentials, and only talks to Anthropic, OpenAI and Cursor. Right-click the menu bar item to turn providers on or off.

## Install

Needs macOS 14 or later, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and an Apple Development certificate. A free Apple ID signed in to Xcode is enough.

```sh
git clone https://github.com/155xp/pace.git
cd pace
scripts/install.sh
```

Then add the widget from the desktop with Edit Widgets.

## License

MIT. Provider icons are from [Lobe Icons](https://github.com/lobehub/lobe-icons); the marks belong to Anthropic, OpenAI and Anysphere.
