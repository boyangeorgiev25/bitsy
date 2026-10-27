<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Bitsy coding on its tiny laptop">
</p>

<h1 align="center">Bitsy</h1>

<p align="center">A tiny pixel pet that lives on your Mac and keeps an eye on Claude Code for you.</p>

<p align="center">
  <img src="docs/images/moods.png" alt="Bitsy's moods: idle, walk, coding, Claude done, music, bedtime, up late, losing balance">
</p>

- Walks on your Dock and jumps between your windows. Drag a window and it falls off.
- Codes along while Claude Code works and cheers with **Done!** when it finishes.
- Drop it on the notch and it becomes a **Dynamic Island** with your music and Claude status.
- Double-click it to send a screenshot of your window to Claude.
- Headphones when music plays, a nightcap at bedtime, and fan control when your Mac gets hot.

<p align="center">
  <img src="docs/images/island-claude.png" width="560" alt="Bitsy's Dynamic Island showing Claude working, usage, and Send window to Claude">
</p>

## Install

Needs macOS 13+ and Xcode.

```bash
git clone https://github.com/boyangeorgiev25/bitsy.git
cd bitsy/bitsy-mac && ./build.sh
cp -R build/Bitsy.app /Applications/ && open /Applications/Bitsy.app
```

Bitsy lives in your menu bar. For Claude usage numbers, permissions, fan control and more, see the [guide](docs/GUIDE.md).

---

<sub>Not affiliated with Anthropic. Claude is a trademark of Anthropic. [MIT License](LICENSE).</sub>
