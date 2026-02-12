[![CurseForge](https://img.shields.io/badge/CurseForge-Silencer-orange)](https://www.curseforge.com/wow/addons/silencer-whispers)
[![Wago](https://img.shields.io/badge/Wago-Silencer-c1272d)](https://addons.wago.io/addons/silencer)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PayPal](https://img.shields.io/badge/Donate-PayPal-00457C?logo=paypal&logoColor=white)](https://www.paypal.com/donate/?hosted_button_id=FG4KES3HNPLVG)

If you find this useful, consider [supporting development](https://www.paypal.com/donate/?hosted_button_id=FG4KES3HNPLVG).

Other addons: [LazyProf](https://www.curseforge.com/wow/addons/lazyprof) - Profession leveling optimizer | [CraftLib](https://www.curseforge.com/wow/addons/craftlib) - Recipe database

---

Whisper gatekeeper for World of Warcraft Classic. Set a keyword, and Silencer intercepts all incoming whispers - matching ones go to a review queue for quick invite, everything else is silenced.

Built for group building: broadcast "whisper me **help** for invite", then let Silencer catch and queue the responses while filtering out the noise.

## Features

- **Keyword filtering** - Set any keyword; whispers containing it are queued for review
- **One-click invite** - Invite players directly from the queue
- **Silenced message log** - Review non-matching whispers you might have missed
- **Minimap button** - Left-click to toggle window, right-click to toggle filter
- **Slash commands** - `/sil on`, `/sil off`, `/sil keyword <word>`, `/sil status`

## Usage

1. `/sil on` - Enable the filter
2. Set your keyword in the window (default: `inv`)
3. Broadcast in chat: *"Whisper me inv for invite"*
4. Matching whispers appear in the queue - click **Invite** or **X** to dismiss
5. Click the **silenced** counter at the bottom to review non-matching whispers
6. `/sil off` - Disable and restore normal whisper flow

## Compatibility

Works on Classic Era, TBC Classic, and Anniversary Edition.
