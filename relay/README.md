# Relay (Cloudflare Workers)

Lets the **browser build** of the game (e.g. on itch.io) reach phones. A browser game can't run a
server, so both the game and the phones connect *out* to this relay, which pairs them by room code.

```
game (browser, wss) ──► /ws/host/CODE ─┐
                                       ├─ Room CODE (Durable Object) forwards messages both ways
phone (browser, wss) ─► /ws/phone/CODE ┘
phone opens            /?r=CODE        ── the controller page (copied from ../phone_controller/controller.html)
```

Live at: `https://pvp-phone-relay.pvp-phone-relay.workers.dev` (`DEFAULT_RELAY_URL` in
`phone_controller/phone_controller_server.gd`; if you rename the Worker or subdomain, change it there).

## Deploy / update

Needs Node.js and a (free) Cloudflare account.

```bash
cd relay
npm install
npx wrangler login     # once; approve in the browser
npm run deploy         # copies the phone page into public/ and deploys
```

Redeploy whenever `phone_controller/controller.html` changes, so phones get the new page.

Local testing: `npm run dev` serves the relay on http://127.0.0.1:8787. Point the game at it with an
`override.cfg` in the project root (don't commit it):

```ini
[phone_controllers]
mode="relay"
relay_url="ws://127.0.0.1:8787"
```

## Costs

Cloudflare's free plan covers casual use. Each room is a Durable Object that stays awake while a game
is connected; the free tier's daily Durable Object allowance is roughly a day's worth of one room being
open, spread across however many games are running. See Cloudflare's current Workers pricing page for
exact limits.

## Notes

- Rooms are 4-character codes chosen by the game; if one is taken the game picks another.
- If the game disconnects, phones see "Waiting for the game…" and rejoin automatically (same player slot)
  when it reconnects with the same code.
- Latency is roughly your network's ping to Cloudflare; unstable Wi-Fi shows up as stutter.
