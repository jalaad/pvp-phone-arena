// Relay between a Godot game (the "host") and the phones controlling it.
//
//   GET /?r=CODE           -> phone controller page (static asset, public/index.html)
//   WS  /ws/host/CODE      -> the game opens room CODE
//   WS  /ws/phone/CODE     -> a phone joins room CODE
//
// Each room is one Durable Object, so the game and all its phones meet in the same place.
// The relay doesn't understand the game protocol; it just wraps phone messages with an id
// for the host and unwraps the host's replies. See phone_controller_server.gd for the format.
import { DurableObject } from "cloudflare:workers";

const MAX_PHONES = 8;
const MAX_MESSAGE_CHARS = 4096;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/ws\/(host|phone)\/([A-Za-z0-9]{4,8})$/);
    if (match) {
      if (request.headers.get("Upgrade") !== "websocket") {
        return new Response("Expected a WebSocket upgrade", { status: 426 });
      }
      const room = match[2].toUpperCase();
      const stub = env.ROOMS.get(env.ROOMS.idFromName(room));
      return stub.fetch(request);
    }
    if (url.pathname === "/health") return new Response("ok");
    return new Response("Not found", { status: 404 });
  },
};

// Uses plain (non-hibernating) WebSockets: a room stays in memory while anyone is connected,
// which keeps forwarding instant. Rooms only exist while a game is running.
export class Room extends DurableObject {
  host = null;          // the game's socket
  phones = new Map();   // cid -> phone socket
  nextCid = 1;

  async fetch(request) {
    const [, , role, code] = new URL(request.url).pathname.split("/");
    const room = code.toUpperCase();
    const [client, server] = Object.values(new WebSocketPair());
    server.accept();

    if (role === "host") {
      if (this.host) return this.refuse(server, client, 4009, "room_taken");
      this.host = server;
      server.addEventListener("message", (e) => this.fromHost(e.data));
      const hostGone = () => {
        if (this.host !== server) return;
        this.host = null;
        // Game went away: phones keep retrying and rejoin when it reconnects with the same code.
        for (const phone of this.phones.values()) close(phone, 4005, "host_left");
        this.phones.clear();
      };
      server.addEventListener("close", hostGone);
      server.addEventListener("error", hostGone);
      server.send(JSON.stringify({ t: "_room", room }));
    } else {
      if (!this.host) return this.refuse(server, client, 4004, "no_game");
      if (this.phones.size >= MAX_PHONES) return this.refuse(server, client, 4001, "full");
      const cid = this.nextCid++;
      this.phones.set(cid, server);
      server.addEventListener("message", (e) => this.fromPhone(cid, e.data));
      const phoneGone = () => {
        if (this.phones.get(cid) !== server) return;
        this.phones.delete(cid);
        send(this.host, JSON.stringify({ c: cid, closed: true }));
      };
      server.addEventListener("close", phoneGone);
      server.addEventListener("error", phoneGone);
      send(this.host, JSON.stringify({ c: cid, open: true }));
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  // Close right away with a reason, so the browser can show why.
  refuse(server, client, code, reason) {
    close(server, code, reason);
    return new Response(null, { status: 101, webSocket: client });
  }

  fromPhone(cid, data) {
    if (typeof data !== "string" || data.length > MAX_MESSAGE_CHARS) return;
    let msg;
    try { msg = JSON.parse(data); } catch { return; }
    send(this.host, JSON.stringify({ c: cid, m: msg }));
  }

  // {"c":ID,"m":{...}} -> message to phone ID;  {"c":ID,"close":"reason"} -> disconnect it;
  // "ping" -> "pong" keep-alive.
  fromHost(data) {
    if (data === "ping") return send(this.host, "pong");
    if (typeof data !== "string" || data.length > MAX_MESSAGE_CHARS) return;
    let msg;
    try { msg = JSON.parse(data); } catch { return; }
    const phone = this.phones.get(msg.c);
    if (!phone) return;
    if (msg.close !== undefined) {
      this.phones.delete(msg.c);
      close(phone, 4001, String(msg.close).slice(0, 100));
    } else if (msg.m !== undefined) {
      send(phone, JSON.stringify(msg.m));
    }
  }
}

function send(ws, text) {
  try { ws?.send(text); } catch {}
}

function close(ws, code, reason) {
  try { ws.close(code, reason); } catch {}
}
