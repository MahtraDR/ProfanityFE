# ProfanityFE

A curses-based terminal frontend for [DragonRealms](https://www.play.net/dr/) and [GemStone IV](https://www.play.net/gs4/), connecting through a local game proxy such as [Lich](https://github.com/elanthia-online/lich-5).

## Features

- Multi-window layouts (story, combat, death, thoughts, room, spells, etc.)
- Color highlighting with configurable regex patterns
- Countdown timers for roundtime/casttime/stun
- Progress bars for health, mana, stamina, stance, encumbrance
- Clickable in-game links (directions, objects, players)
- Tabbed text windows with per-tab activity indicators
- Dedicated room window with creature highlighting
- Experience tracking window
- Active spell display with duration sorting
- Gag patterns for filtering unwanted text
- Emacs-style kill ring and command history
- Mouse scroll wheel support
- Macro engine with key bindings

## Quick Start

```bash
git clone https://github.com/elanthia-online/ProfanityFE.git
cd ProfanityFE
bundle install
ruby profanity.rb --port=8000 --char=YourCharacter
```

## Documentation

See the **[User Guide](USER_GUIDE.md)** for full documentation including settings XML reference, layout configuration, key bindings, and troubleshooting.

## Dependencies

- Ruby 3.0+
- curses gem
- rexml gem

Install all dependencies with `bundle install`.

## License

Licensed under the GNU General Public License v2.0. See [profanity.rb](profanity.rb) header for details.
