.pragma library

// Pure parsing helpers for openvpn3-linux CLI output.
// Kept free of QML dependencies so they can be unit tested with Node
// (see tests/ovpn3.test.mjs).

// Lower number = higher priority when a profile has several sessions.
var STATE_PRIORITY = {
    connected: 0,
    auth: 1,
    connecting: 2,
    paused: 3,
    failed: 4,
    disconnected: 5,
    none: 6
};

// Parse `openvpn3 configs-list --json`.
function parseConfigs(jsonText) {
    var data;
    try {
        data = JSON.parse(jsonText || "{}");
    } catch (e) {
        return [];
    }
    var out = [];
    for (var path in data) {
        var c = data[path];
        if (!c || typeof c.name !== "string" || c.name === "")
            continue;
        out.push({
            path: path,
            name: c.name,
            lastUsed: c.lastused || "",
            valid: c.valid !== false
        });
    }
    out.sort(function (a, b) {
        return a.name.localeCompare(b.name);
    });
    return out;
}

// Map the free-form "Status:" text of `openvpn3 sessions-list` to a state.
function classifyStatus(status) {
    var s = (status || "").toLowerCase();
    if (s === "")
        return "connecting";
    if (s.indexOf("disconnected") !== -1)
        return "disconnected";
    if (s.indexOf("fail") !== -1 || s.indexOf("error") !== -1)
        return "failed";
    if (s.indexOf("paused") !== -1)
        return "paused";
    if (s.indexOf("auth") !== -1 || s.indexOf("credentials") !== -1 || s.indexOf("user input") !== -1)
        return "auth";
    if (s.indexOf("client connected") !== -1)
        return "connected";
    return "connecting";
}

// Parse the human-readable output of `openvpn3 sessions-list`
// (it has no --json flag as of openvpn3-linux v27).
function parseSessions(text) {
    var sessions = [];
    var cur = null;
    var lines = (text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        var m = line.match(/^Path:\s*(\S+)/);
        if (m) {
            cur = {
                path: m[1],
                configName: "",
                status: "",
                device: "",
                remote: "",
                state: "connecting"
            };
            sessions.push(cur);
            continue;
        }
        if (!cur)
            continue;
        if ((m = line.match(/^Config name:\s*(.*)$/)))
            cur.configName = m[1].replace(/\s+\(.*\)\s*$/, "").trim();
        else if ((m = line.match(/^Status:\s*(.*)$/)))
            cur.status = m[1].trim();
        else if ((m = line.match(/^Connected to:\s*(.*)$/)))
            cur.remote = m[1].trim();
        var d = line.match(/Device:\s*(\S*)\s*$/);
        if (d)
            cur.device = d[1];
    }
    for (var j = 0; j < sessions.length; j++)
        sessions[j].state = classifyStatus(sessions[j].status);
    return sessions;
}

function bestSession(list) {
    var best = null;
    for (var i = 0; i < list.length; i++) {
        if (!best || STATE_PRIORITY[list[i].state] < STATE_PRIORITY[best.state])
            best = list[i];
    }
    return best;
}

// One row per imported profile, plus rows for sessions whose profile is not
// in the list (e.g. started from a file with `session-start --config file`).
function buildRows(configs, sessions) {
    var rows = [];
    var seen = {};
    var byName = {};
    var i;
    for (i = 0; i < (sessions || []).length; i++) {
        var s = sessions[i];
        (byName[s.configName] = byName[s.configName] || []).push(s);
    }
    for (i = 0; i < (configs || []).length; i++) {
        var c = configs[i];
        seen[c.name] = true;
        var list = byName[c.name] || [];
        var best = bestSession(list);
        rows.push({
            name: c.name,
            configPath: c.path,
            imported: true,
            state: best ? best.state : "none",
            status: best ? best.status : "",
            device: best ? best.device : "",
            remote: best ? best.remote : "",
            sessionPaths: list.map(function (x) {
                return x.path;
            })
        });
    }
    for (var name in byName) {
        if (seen[name])
            continue;
        var l = byName[name];
        var b = bestSession(l);
        rows.push({
            name: name || "(unnamed session)",
            configPath: "",
            imported: false,
            state: b.state,
            status: b.status,
            device: b.device,
            remote: b.remote,
            sessionPaths: l.map(function (x) {
                return x.path;
            })
        });
    }
    return rows;
}

// Most relevant state across all rows, used for the bar icon.
function overallState(rows) {
    var best = "none";
    for (var i = 0; i < (rows || []).length; i++) {
        if (STATE_PRIORITY[rows[i].state] < STATE_PRIORITY[best])
            best = rows[i].state;
    }
    return best;
}

function isActive(state) {
    return state === "connected" || state === "auth" || state === "connecting" || state === "paused";
}

function extractUrl(line) {
    var m = (line || "").match(/https?:\/\/\S+/);
    return m ? m[0] : "";
}
