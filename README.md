# PvP Phone Arena

A 2-player top-down arena duel for **Godot 4.7** where each player's **phone is the controller**.
Players scan a QR code on the game screen and their phone turns into a joystick with
ATTACK / SHOOT / BLOCK / DASH buttons. No app install.

Two ways phones connect (chosen automatically; see `DEFAULT_MODE` / `DEFAULT_RELAY_URL` at the top of `phone_controller/phone_controller_server.gd`):

| Build | How phones reach the game | Needs |
|---|---|---|
| Desktop (Windows/Mac/Linux) | The game hosts the phone page itself | Phones on the **same Wi-Fi**; no internet |
| Browser (e.g. itch.io) | Through the [relay](relay/README.md) on Cloudflare | Internet; phones on **any** network |

Built from two projects:
- [godot-phone-controller](https://github.com/jalaad/godot-phone-controller): phone page, WebSocket server, QR code
- [pvp-arena](https://github.com/jalaad/pvp-arena): the arena game, fighters and rules

## Play

1. Open this folder in Godot 4.7 and press Play. Allow the Windows Firewall prompt for **Private networks**.
   (In the browser build there's no firewall prompt; the QR code appears once the relay connects.)
2. Each player scans the QR code with a phone (same Wi-Fi for desktop builds) and taps **Join**.
   The first phone becomes Player 1 (blue), the second Player 2 (pink); each phone recolours to match.
3. The match starts automatically once both phones join.

| Phone | Action |
|---|---|
| Drag on the left half | Move (360°) |
| ATTACK | Melee: 12 damage + knockback |
| SHOOT | Projectile: 7 damage, stopped by pillars |
| BLOCK (hold) | Hits from the front do 20% damage; you move slowly |
| DASH | Quick burst; you can't be hurt mid-dash |
| NEXT ROUND | Start the next round after a knockout |

Phones vibrate when you're hit, win or get knocked out (Android; iPhones can't vibrate from a browser).

**Keyboard works too**, for either player at any time, even alongside a phone:
P1 = WASD + K attack, L shoot, J block, I dash. P2 = Arrows + Numpad 5 attack, 6 shoot, 4 block, 8 dash.
Press **Enter** in the lobby to start without phones, **Tab** to bring the QR code back up.

## How it fits together

```
project.godot                 input map + PhoneControllers autoload
phone_controller/
  controller.html             the phone page (buttons: attack/shoot/block/dash/start)
  phone_controller_server.gd  serves the page (HTTP 8080) + receives input (WebSocket 8081)
  qr_code.gd                  QR code generator
scenes/  main.tscn · fighter.tscn · bullet.tscn
scripts/
  main.gd                     lobby, phone -> fighter assignment, rounds, HUD, vibration/messages
  fighter.gd                  reads keyboard AND its phone (phone_id); movement + the 4 actions
  bullet.gd
```

- Each phone button name on the page (`data-btn="attack"` etc.) matches the fighter action name, so adding a
  button is one line in `controller.html` plus handling it in `fighter.gd`.
- Balance numbers are constants at the top of `scripts/fighter.gd`.
- If a phone drops (screen lock, Wi-Fi blip) it keeps its fighter for 30 seconds and reconnects by itself.

## Troubleshooting

- **Phone can't open the page:** allow Godot through Windows Firewall (Private), and make sure the phone
  isn't on a guest network. If the QR shows the wrong IP (VPN/virtual adapters), set `host_override` on the
  `PhoneControllers` autoload.
- **Exporting:** add `phone_controller/*.html` to *Export → Resources → Filters to export non-resource files*.
