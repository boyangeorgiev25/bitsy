# Bitsy guide

Everything beyond the basics: permissions, Claude Code setup, fan control, privacy and uninstalling.

## Building

**About signing:** `build.sh` signs with your Apple Development certificate when you have one, so macOS remembers Bitsy's permissions across rebuilds. Without one it falls back to an ad-hoc signature, and you'll have to grant permissions again after every rebuild.

## Permissions

Everything works without them; each one unlocks a feature. macOS asks the first time you use it.

| Permission | Used for |
|---|---|
| Screen Recording | *Send window to Claude* (double-click) |
| Accessibility | Pasting the screenshot for you, and the Dock's exact width |
| Automation (Spotify / Music) | Play, pause, next, previous |
| Admin password (once) | Installing the optional fan helper |

After turning on Screen Recording, choose **Restart Bitsy** from its menu. macOS only applies that permission after a restart.

## Claude Code setup

**Real usage numbers.** Add Bitsy's status line bridge to `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "/Applications/Bitsy.app/Contents/MacOS/bitsy-statusline",
  "padding": 0
}
```

Claude Code then passes your session and weekly limits to Bitsy after each message, and your status line reads like `Opus 5.5 · session 17% · week 21%`. Anthropic documents this data for Pro and Max plans; it also worked on a Team plan in testing. If you already have a status line, this replaces it.

**Let your agents see your screen.**

```bash
claude mcp add --scope user bitsy -- /Applications/Bitsy.app/Contents/MacOS/bitsy-mcp
```

## Fan control and its helper

Changing fan speeds needs root. Choosing **Fans → Install Fan Helper…** asks for your admin password once and installs a small helper:

- Copied to `/Library/PrivilegedHelperTools/io.bitsy.fand` (root-owned), started by `/Library/LaunchDaemons/io.bitsy.fand.plist`.
- Only accepts commands from the user who installed it. It can report status, set a speed between each fan's own minimum and maximum, or hand control back to macOS.
- Manual speeds expire after 30 seconds unless Bitsy renews them. If Bitsy quits or crashes, the fans go back to automatic.
- **Fans → Uninstall Fan Helper…** removes it.

## Privacy

Bitsy runs entirely on your Mac. It reads Claude Code's local transcripts (`~/.claude/projects`) to know when Claude is working, and the status line file above for usage. The only network request is a check of Anthropic's public status page every 5 minutes. Screenshots are only taken when you double-click Bitsy or press *Send window to Claude*, or when an agent you connected calls the MCP `screenshot` tool.

## Uninstall

1. Choose **Fans → Uninstall Fan Helper…** if you installed it, then **Quit Bitsy**.
2. Delete `/Applications/Bitsy.app`.
3. Remove the `statusLine` entry from `~/.claude/settings.json`, and run `claude mcp remove bitsy -s user`.
4. Optionally delete `~/Library/Application Support/Bitsy`.

## Project layout

```
bitsy-mac/
  Sources/Bitsy/           the app: pixel rig, animations, physics, island, popup
  Sources/BitsyKit/        shared: system stats, AppleSMC fan access, helper protocol
  Sources/bitsy-mcp/       MCP server (screen context + screenshots)
  Sources/bitsy-fand/      root fan helper
  Sources/bitsy-statusline/ Claude Code status line bridge
  icon/                    generates the app icon from the sprite
  build.sh                 builds and signs build/Bitsy.app
docs/design.html           the original character and animation sheet
```

Bitsy is drawn in code from a 32×32 pixel rig (body, four legs, two arm nubs, swappable eyes and props), so every pose is a few lines in `Anims.swift`.
