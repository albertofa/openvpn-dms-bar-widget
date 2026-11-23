// Run with: node --test tests/
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, "..", "Ovpn3.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const Ovpn3 = new Function(`${src}; return { parseConfigs, parseSessions, classifyStatus, buildRows, overallState, isActive, extractUrl };`)();

const CONFIGS_JSON = `{
  "/net/openvpn/v3/configuration/90de6549x7058x4bbbxb00dx492e6c91ed58" : {
    "acl" : { "locked_down" : false, "owner" : "user", "public_access" : false },
    "dco" : false, "imported" : "2026-11-23 09:31:17", "lastused" : "2026-11-23 09:33:27",
    "name" : "work-vpn", "use_count" : 2, "valid" : true
  },
  "/net/openvpn/v3/configuration/a11b5441x9527x4b79x9330xfd8c4c993b7a" : {
    "name" : "home", "valid" : true
  }
}`;

const SESSIONS_CONNECTED = `-----------------------------------------------------------------------------
        Path: /net/openvpn/v3/sessions/58cced73s81f0s4052s9d4fsfa166bf9f7f4
     Created: 2026-11-23 09:33:27                       PID: 292323
       Owner: user                                   Device: tun0
 Config name: work-vpn
Connected to: udpv4:203.0.113.10:1194
      Status: Connection, Client connected
-----------------------------------------------------------------------------
`;

const SESSIONS_AUTH = `-----------------------------------------------------------------------------
        Path: /net/openvpn/v3/sessions/d44ddf1es1244s4238s825bs2f7d3013bebc
     Created: 2026-11-23 09:31:17                       PID: 290838
       Owner: user                                   Device:
 Config name: work-vpn
      Status: Web authentication required to connect
-----------------------------------------------------------------------------
`;

test("parseConfigs reads names sorted", () => {
    const c = Ovpn3.parseConfigs(CONFIGS_JSON);
    assert.deepEqual(c.map(x => x.name), ["home", "work-vpn"]);
    assert.equal(c[1].lastUsed, "2026-11-23 09:33:27");
});

test("parseConfigs tolerates garbage", () => {
    assert.deepEqual(Ovpn3.parseConfigs("not json"), []);
    assert.deepEqual(Ovpn3.parseConfigs(""), []);
});

test("parseSessions connected", () => {
    const s = Ovpn3.parseSessions(SESSIONS_CONNECTED);
    assert.equal(s.length, 1);
    assert.equal(s[0].configName, "work-vpn");
    assert.equal(s[0].device, "tun0");
    assert.equal(s[0].remote, "udpv4:203.0.113.10:1194");
    assert.equal(s[0].state, "connected");
});

test("parseSessions web auth with empty device", () => {
    const s = Ovpn3.parseSessions(SESSIONS_AUTH);
    assert.equal(s[0].device, "");
    assert.equal(s[0].state, "auth");
});

test("parseSessions no sessions", () => {
    assert.deepEqual(Ovpn3.parseSessions("No sessions available\n"), []);
});

test("classifyStatus", () => {
    assert.equal(Ovpn3.classifyStatus("Connection, Client connected"), "connected");
    assert.equal(Ovpn3.classifyStatus("Connection, Client disconnected"), "disconnected");
    assert.equal(Ovpn3.classifyStatus("Connection, Client connecting"), "connecting");
    assert.equal(Ovpn3.classifyStatus("Connection, Client connection failed"), "failed");
    assert.equal(Ovpn3.classifyStatus("Connection, Client connection paused"), "paused");
    assert.equal(Ovpn3.classifyStatus("Web authentication required to connect"), "auth");
});

test("buildRows merges sessions and prefers connected", () => {
    const configs = Ovpn3.parseConfigs(CONFIGS_JSON);
    const sessions = Ovpn3.parseSessions(SESSIONS_AUTH + SESSIONS_CONNECTED);
    const rows = Ovpn3.buildRows(configs, sessions);
    const work = rows.find(r => r.name === "work-vpn");
    assert.equal(work.state, "connected");
    assert.equal(work.sessionPaths.length, 2);
    assert.equal(rows.find(r => r.name === "home").state, "none");
    assert.equal(Ovpn3.overallState(rows), "connected");
});

test("buildRows adds sessions without imported profile", () => {
    const rows = Ovpn3.buildRows([], Ovpn3.parseSessions(SESSIONS_CONNECTED));
    assert.equal(rows.length, 1);
    assert.equal(rows[0].imported, false);
});

test("extractUrl", () => {
    assert.equal(Ovpn3.extractUrl("     https://vpn.example.com/auth?x=1 "), "https://vpn.example.com/auth?x=1");
    assert.equal(Ovpn3.extractUrl("nothing here"), "");
});
