//
// Compass backend — zero-dependency dev server.
//
// Implements the API sketch from CLAUDE.md §5, with one substitution for now:
// a simple username/password "dev login" stands in for Sign in with Apple until
// the paid Apple Developer account is active. Everything else (usernames,
// connections, locations) is exactly the real model.
//
// Storage: a single JSON file (data.json) next to this script. Fine for
// Simulator development; swap for a real DB when deploying to your domain.
//
// Run:   node server.js       (listens on http://localhost:4000)
//
// No npm install needed — only Node built-ins.
//

const http = require("http");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const PORT = process.env.PORT || 4000;
const DB_PATH = path.join(__dirname, "data.json");

// ---------- tiny JSON "database" ----------

function loadDB() {
  let db;
  try {
    db = JSON.parse(fs.readFileSync(DB_PATH, "utf8"));
  } catch {
    db = { users: [], sessions: [], connections: [], locations: {} };
  }
  // Ensure newer fields exist when loading an older data.json.
  if (!db.orders) db.orders = {};       // userId -> [connectionId, …] preferred order
  if (!db.nicknames) db.nicknames = {}; // userId -> { connectionId: "custom name" }
  return db;
}

function saveDB(db) {
  fs.writeFileSync(DB_PATH, JSON.stringify(db, null, 2));
}

let db = loadDB();

// ---------- helpers ----------

function newId() {
  return crypto.randomBytes(8).toString("hex");
}

function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 64).toString("hex");
}

function publicUser(u) {
  return { id: u.id, username: u.username, displayName: u.displayName };
}

function findUserByName(username) {
  const lower = String(username).toLowerCase();
  return db.users.find((u) => u.username.toLowerCase() === lower);
}

function userForToken(req) {
  const auth = req.headers["authorization"] || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : null;
  if (!token) return null;
  const session = db.sessions.find((s) => s.token === token);
  if (!session) return null;
  return db.users.find((u) => u.id === session.userId) || null;
}

// Accepted connection between two user ids, if any.
function acceptedConnection(a, b) {
  return db.connections.find(
    (c) =>
      c.status === "accepted" &&
      ((c.requesterId === a && c.addresseeId === b) ||
        (c.requesterId === b && c.addresseeId === a))
  );
}

function anyConnection(a, b) {
  return db.connections.find(
    (c) =>
      (c.requesterId === a && c.addresseeId === b) ||
      (c.requesterId === b && c.addresseeId === a)
  );
}

// ---------- request plumbing ----------

function send(res, status, body) {
  const json = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(json),
  });
  res.end(json);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (chunk) => {
      data += chunk;
      if (data.length > 1e6) reject(new Error("body too large"));
    });
    req.on("end", () => {
      if (!data) return resolve({});
      try {
        resolve(JSON.parse(data));
      } catch {
        reject(new Error("invalid JSON"));
      }
    });
    req.on("error", reject);
  });
}

// ---------- route handlers ----------

async function handleSignup(req, res) {
  const body = await readBody(req);
  const username = (body.username || "").trim();
  const password = body.password || "";
  const displayName = (body.displayName || username).trim();

  if (!/^[a-zA-Z0-9_]{3,20}$/.test(username)) {
    return send(res, 400, {
      error: "Username must be 3–20 letters, numbers, or underscores.",
    });
  }
  if (password.length < 6) {
    return send(res, 400, { error: "Password must be at least 6 characters." });
  }
  if (findUserByName(username)) {
    return send(res, 409, { error: "That username is taken." });
  }

  const salt = crypto.randomBytes(16).toString("hex");
  const user = {
    id: newId(),
    username,
    displayName,
    passwordHash: hashPassword(password, salt),
    salt,
    createdAt: Date.now(),
  };
  db.users.push(user);

  const token = crypto.randomBytes(32).toString("hex");
  db.sessions.push({ token, userId: user.id });
  saveDB(db);

  send(res, 200, { token, user: publicUser(user) });
}

async function handleLogin(req, res) {
  const body = await readBody(req);
  const user = findUserByName(body.username || "");
  if (!user || hashPassword(body.password || "", user.salt) !== user.passwordHash) {
    return send(res, 401, { error: "Wrong username or password." });
  }
  const token = crypto.randomBytes(32).toString("hex");
  db.sessions.push({ token, userId: user.id });
  saveDB(db);
  send(res, 200, { token, user: publicUser(user) });
}

function handleMe(req, res, me) {
  send(res, 200, { user: publicUser(me) });
}

function handleSearch(req, res, me, url) {
  const q = (url.searchParams.get("u") || "").trim().toLowerCase();
  if (q.length < 2) return send(res, 200, { users: [] });
  const results = db.users
    .filter((u) => u.id !== me.id && u.username.toLowerCase().includes(q))
    .slice(0, 10)
    .map(publicUser);
  send(res, 200, { users: results });
}

async function handleInvite(req, res, me) {
  const body = await readBody(req);
  const target = findUserByName(body.username || "");
  if (!target) return send(res, 404, { error: "No user with that username." });
  if (target.id === me.id)
    return send(res, 400, { error: "You can't connect with yourself." });

  const existing = anyConnection(me.id, target.id);
  if (existing) {
    return send(res, 409, {
      error:
        existing.status === "accepted"
          ? "You're already connected."
          : "There's already a pending request.",
    });
  }

  const conn = {
    id: newId(),
    requesterId: me.id,
    addresseeId: target.id,
    status: "pending",
    createdAt: Date.now(),
  };
  db.connections.push(conn);
  saveDB(db);
  send(res, 200, { ok: true, connectionId: conn.id });
}

async function handleRespond(req, res, me) {
  const body = await readBody(req);
  const conn = db.connections.find((c) => c.id === body.connectionId);
  if (!conn) return send(res, 404, { error: "Request not found." });
  if (conn.addresseeId !== me.id)
    return send(res, 403, { error: "That request isn't yours to answer." });
  if (conn.status !== "pending")
    return send(res, 409, { error: "Request already handled." });

  if (body.action === "accept") {
    conn.status = "accepted";
  } else if (body.action === "decline") {
    db.connections = db.connections.filter((c) => c.id !== conn.id);
  } else {
    return send(res, 400, { error: "action must be 'accept' or 'decline'." });
  }
  saveDB(db);
  send(res, 200, { ok: true });
}

function handleConnections(req, res, me) {
  const order = db.orders[me.id] || [];
  const nicknames = db.nicknames[me.id] || {};
  const rank = (id) => {
    const i = order.indexOf(id);
    return i === -1 ? Number.MAX_SAFE_INTEGER : i;
  };

  const list = db.connections
    .filter((c) => c.requesterId === me.id || c.addresseeId === me.id)
    .map((c) => {
      const otherId = c.requesterId === me.id ? c.addresseeId : c.requesterId;
      const other = db.users.find((u) => u.id === otherId);
      const incoming = c.addresseeId === me.id && c.status === "pending";
      const loc =
        c.status === "accepted" ? db.locations[otherId] || null : null;
      return {
        connectionId: c.id,
        user: other ? publicUser(other) : null,
        status: c.status, // pending | accepted
        direction: incoming ? "incoming" : "outgoing",
        location: loc, // { lat, lon, accuracy, updatedAt } or null
        nickname: nicknames[c.id] || null,
      };
    })
    .filter((c) => c.user !== null)
    // Return already sorted by the user's saved order (unknown ones last),
    // so any device shows the same arrangement immediately.
    .sort((a, b) => rank(a.connectionId) - rank(b.connectionId));

  send(res, 200, { connections: list, order });
}

async function handleSetOrder(req, res, me) {
  const body = await readBody(req);
  if (!Array.isArray(body.order) || body.order.some((x) => typeof x !== "string")) {
    return send(res, 400, { error: "order must be an array of connection ids." });
  }
  db.orders[me.id] = body.order;
  saveDB(db);
  send(res, 200, { ok: true });
}

// Only the connection's own two members may act on it.
function ownConnection(me, connectionId) {
  const conn = db.connections.find((c) => c.id === connectionId);
  if (!conn) return null;
  if (conn.requesterId !== me.id && conn.addresseeId !== me.id) return null;
  return conn;
}

async function handleSetNickname(req, res, me) {
  const body = await readBody(req);
  const conn = ownConnection(me, body.connectionId);
  if (!conn) return send(res, 404, { error: "Connection not found." });
  if (!db.nicknames[me.id]) db.nicknames[me.id] = {};
  const name = (body.nickname || "").trim();
  if (name) db.nicknames[me.id][conn.id] = name;
  else delete db.nicknames[me.id][conn.id]; // empty clears the custom name
  saveDB(db);
  send(res, 200, { ok: true });
}

async function handleRemoveConnection(req, res, me) {
  const body = await readBody(req);
  const conn = ownConnection(me, body.connectionId);
  if (!conn) return send(res, 404, { error: "Connection not found." });
  // Delete the relationship entirely — neither side can see the other's
  // location anymore (mutual, per CLAUDE.md §6). Also tidy up order/nicknames.
  db.connections = db.connections.filter((c) => c.id !== conn.id);
  for (const uid of [conn.requesterId, conn.addresseeId]) {
    if (db.orders[uid]) db.orders[uid] = db.orders[uid].filter((id) => id !== conn.id);
    if (db.nicknames[uid]) delete db.nicknames[uid][conn.id];
  }
  saveDB(db);
  send(res, 200, { ok: true });
}

async function handleLocationUpload(req, res, me) {
  const body = await readBody(req);
  const lat = Number(body.lat);
  const lon = Number(body.lon);
  if (!isFinite(lat) || !isFinite(lon)) {
    return send(res, 400, { error: "lat and lon are required numbers." });
  }
  db.locations[me.id] = {
    lat,
    lon,
    accuracy: Number(body.accuracy) || null,
    updatedAt: Date.now(),
  };
  saveDB(db);
  send(res, 200, { ok: true });
}

function handleConnectionLocation(req, res, me, otherId) {
  if (!acceptedConnection(me.id, otherId)) {
    return send(res, 403, { error: "Not connected with that user." });
  }
  const loc = db.locations[otherId];
  if (!loc) return send(res, 404, { error: "No location yet." });
  send(res, 200, { location: loc });
}

// ---------- router ----------

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = url.pathname;
  const m = req.method;

  try {
    // Public routes
    if (m === "POST" && p === "/auth/signup") return await handleSignup(req, res);
    if (m === "POST" && p === "/auth/login") return await handleLogin(req, res);
    if (m === "GET" && p === "/health") return send(res, 200, { ok: true });

    // Everything below requires a valid session token.
    const me = userForToken(req);
    if (!me) return send(res, 401, { error: "Not signed in." });

    if (m === "GET" && p === "/me") return handleMe(req, res, me);
    if (m === "GET" && p === "/users/search")
      return handleSearch(req, res, me, url);
    if (m === "POST" && p === "/connections/invite")
      return await handleInvite(req, res, me);
    if (m === "POST" && p === "/connections/respond")
      return await handleRespond(req, res, me);
    if (m === "GET" && p === "/connections")
      return handleConnections(req, res, me);
    if (m === "POST" && p === "/connections/order")
      return await handleSetOrder(req, res, me);
    if (m === "POST" && p === "/connections/nickname")
      return await handleSetNickname(req, res, me);
    if (m === "POST" && p === "/connections/remove")
      return await handleRemoveConnection(req, res, me);
    if (m === "POST" && p === "/location")
      return await handleLocationUpload(req, res, me);

    const locMatch = p.match(/^\/connections\/([^/]+)\/location$/);
    if (m === "GET" && locMatch)
      return handleConnectionLocation(req, res, me, locMatch[1]);

    send(res, 404, { error: "Not found." });
  } catch (err) {
    send(res, 400, { error: err.message || "Bad request." });
  }
});

// Bind to localhost by default so the app server is private behind the web
// server (Caddy) that terminates HTTPS in front of it. Set HOST=0.0.0.0 only if
// you deliberately want it reachable directly.
const HOST = process.env.HOST || "127.0.0.1";
server.listen(PORT, HOST, () => {
  console.log(`Compass server listening on http://${HOST}:${PORT}`);
});
