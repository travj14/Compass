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

function findUserById(id) {
  return db.users.find((u) => u.id === id);
}

// Set of user ids blocked by, or blocking, `userId` (either direction).
function blockedIdsFor(userId) {
  const ids = new Set();
  for (const c of db.connections) {
    if (c.status !== "blocked") continue;
    if (c.requesterId === userId) ids.add(c.addresseeId);
    else if (c.addresseeId === userId) ids.add(c.requesterId);
  }
  return ids;
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

function sendHTML(res, html) {
  res.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Content-Length": Buffer.byteLength(html),
  });
  res.end(html);
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
  const blocked = blockedIdsFor(me.id); // hide anyone blocked (either direction)
  const results = db.users
    .filter((u) => u.id !== me.id && !blocked.has(u.id) && u.username.toLowerCase().includes(q))
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
          : existing.status === "blocked"
            ? "You can't connect with this user."
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
    .filter((c) => (c.requesterId === me.id || c.addresseeId === me.id) && c.status !== "blocked")
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

// Permanently delete the signed-in user and everything tied to them
// (App Store requirement 5.1.1(v): account creation must allow deletion).
async function handleDeleteAccount(req, res, me) {
  const myConnIds = new Set(
    db.connections
      .filter((c) => c.requesterId === me.id || c.addresseeId === me.id)
      .map((c) => c.id)
  );

  // Drop all my relationships (severs location visibility for the other side too).
  db.connections = db.connections.filter((c) => !myConnIds.has(c.id));

  // Scrub references to those relationships from everyone's order/nickname data.
  for (const uid of Object.keys(db.orders)) {
    db.orders[uid] = db.orders[uid].filter((id) => !myConnIds.has(id));
  }
  for (const uid of Object.keys(db.nicknames)) {
    for (const cid of Object.keys(db.nicknames[uid])) {
      if (myConnIds.has(cid)) delete db.nicknames[uid][cid];
    }
  }

  // Remove all of my own data.
  delete db.orders[me.id];
  delete db.nicknames[me.id];
  delete db.locations[me.id];
  db.sessions = db.sessions.filter((s) => s.userId !== me.id);
  db.users = db.users.filter((u) => u.id !== me.id);

  saveDB(db);
  send(res, 200, { ok: true });
}

// Block a user: severs any relationship and prevents future contact/discovery
// in both directions (App Store requirement for user-to-user apps).
async function handleBlock(req, res, me) {
  const body = await readBody(req);
  const target = findUserById(body.userId);
  if (!target) return send(res, 404, { error: "User not found." });
  if (target.id === me.id) return send(res, 400, { error: "You can't block yourself." });

  // Remove any existing relationship (and tidy order/nickname refs).
  const existing = anyConnection(me.id, target.id);
  if (existing) {
    db.connections = db.connections.filter((c) => c.id !== existing.id);
    for (const uid of [me.id, target.id]) {
      if (db.orders[uid]) db.orders[uid] = db.orders[uid].filter((id) => id !== existing.id);
      if (db.nicknames[uid]) delete db.nicknames[uid][existing.id];
    }
  }

  db.connections.push({
    id: newId(),
    requesterId: me.id, // the blocker
    addresseeId: target.id,
    status: "blocked",
    createdAt: Date.now(),
  });
  saveDB(db);
  send(res, 200, { ok: true });
}

async function handleUnblock(req, res, me) {
  const body = await readBody(req);
  const conn = db.connections.find(
    (c) => c.id === body.connectionId && c.status === "blocked" && c.requesterId === me.id
  );
  if (!conn) return send(res, 404, { error: "Block not found." });
  db.connections = db.connections.filter((c) => c.id !== conn.id);
  saveDB(db);
  send(res, 200, { ok: true });
}

function handleBlockedList(req, res, me) {
  const blocked = db.connections
    .filter((c) => c.status === "blocked" && c.requesterId === me.id)
    .map((c) => {
      const u = findUserById(c.addresseeId);
      return u ? { connectionId: c.id, user: publicUser(u) } : null;
    })
    .filter((x) => x !== null);
  send(res, 200, { blocked });
}

// Stop sharing: remove my stored location so no connection can see it.
async function handleStopSharing(req, res, me) {
  delete db.locations[me.id];
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

// ---------- privacy policy (served at /privacy) ----------

const PRIVACY_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Homeward Compass — Privacy Policy</title>
<style>
  body { font: 16px/1.6 -apple-system, system-ui, sans-serif; max-width: 720px;
         margin: 40px auto; padding: 0 20px; color: #1c1c1e; }
  h1 { font-size: 1.8rem; } h2 { font-size: 1.2rem; margin-top: 2rem; }
  .muted { color: #6b6b70; } a { color: #2f6bff; }
  @media (prefers-color-scheme: dark) {
    body { background: #000; color: #e6e6ea; } .muted { color: #9a9aa2; }
  }
</style>
</head>
<body>
<h1>Homeward Compass — Privacy Policy</h1>
<p class="muted">Last updated: July 10, 2026</p>

<p>Homeward Compass ("the app") shows an arrow that points toward people you're
connected with, and shows them where you are. This policy explains what we
collect, why, and your choices. We keep it minimal on purpose.</p>

<h2>What we collect</h2>
<ul>
  <li><strong>Account info</strong> — your chosen username, display name, and a
      password (stored securely as a salted hash, never in plain text).</li>
  <li><strong>Location</strong> — your device's current GPS location, so the
      people you're connected with can be pointed toward you (and you toward
      them). We store only your <em>latest</em> location, never a history or trail.</li>
  <li><strong>Connections</strong> — the list of people you've mutually connected
      with, and any custom names you set for them.</li>
</ul>

<h2>How we use it</h2>
<p>Your information is used solely to provide the app's core feature: sharing your
current location with people you have <strong>mutually agreed</strong> to connect
with, and pointing your compass toward the person you select. Your location is
visible only to users you are actively connected with.</p>

<h2>What we don't do</h2>
<ul>
  <li>We do <strong>not</strong> sell, rent, or share your data with advertisers
      or third parties.</li>
  <li>We do <strong>not</strong> keep a history of where you've been — only your
      most recent location, which is overwritten with each update.</li>
</ul>

<h2>Sharing &amp; your controls</h2>
<p>You decide whether to share your location. After signing in you are asked to
opt in, and you may decline. Sharing only ever happens with people you have
<strong>mutually accepted</strong> as connections — there is no map of nearby
users and no way to see or be seen by strangers.</p>
<p>You can stop at any time by:</p>
<ul>
  <li>Turning off <strong>Share My Location</strong> in Settings, which removes
      your location from our servers;</li>
  <li><strong>Removing</strong> a connection, which stops sharing in both directions; or</li>
  <li><strong>Blocking</strong> a user, which prevents them from finding,
      contacting, or seeing you.</li>
</ul>

<h2>Data retention &amp; deletion</h2>
<p>We keep your data only while your account exists. You can permanently delete
your account at any time from within the app (Settings → Delete Account). Deleting
your account removes your profile, your stored location, and all of your
connections from our servers.</p>

<h2>Security</h2>
<p>Data is transmitted over encrypted HTTPS connections.</p>

<h2>Age</h2>
<p>Homeward Compass is intended for adults and is rated 18+. It is not directed to
children or minors, and we do not knowingly collect information from anyone under 18.</p>

<h2>Changes</h2>
<p>We may update this policy; material changes will be reflected by the "Last
updated" date above.</p>

<h2>Contact</h2>
<p>Questions about privacy? Email <a href="mailto:travisjohnsonbackup0325@gmail.com">travisjohnsonbackup0325@gmail.com</a>.</p>
</body>
</html>`;

const SUPPORT_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Homeward Compass — Support</title>
<style>
  body { font: 16px/1.6 -apple-system, system-ui, sans-serif; max-width: 720px;
         margin: 40px auto; padding: 0 20px; color: #1c1c1e; }
  h1 { font-size: 1.8rem; } h2 { font-size: 1.15rem; margin-top: 1.8rem; }
  .muted { color: #6b6b70; } a { color: #2f6bff; }
  .card { background: #f2f2f7; border-radius: 12px; padding: 16px 20px; }
  @media (prefers-color-scheme: dark) {
    body { background: #000; color: #e6e6ea; } .muted { color: #9a9aa2; }
    .card { background: #1c1c1e; }
  }
</style>
</head>
<body>
<h1>Homeward Compass — Support</h1>
<p class="muted">An arrow that points toward the people you love.</p>

<p class="card">Need help? Email <a href="mailto:travisjohnsonbackup0325@gmail.com">travisjohnsonbackup0325@gmail.com</a>
and we'll get back to you.</p>

<h2>Getting started</h2>
<ul>
  <li><strong>Sign up</strong> and choose a username.</li>
  <li><strong>Add someone</strong> on the People tab by searching their username and
      sending an invite. Once they accept, you're connected.</li>
  <li><strong>Point at them</strong> — hold your phone up on the Compass tab and the
      arrow swings toward whoever you've selected.</li>
</ul>

<h2>Common questions</h2>
<p><strong>The arrow doesn't move.</strong> The live compass needs Location access
and works while the app is open. Make sure Location is enabled in
Settings → Homeward.</p>
<p><strong>Why "Always" location?</strong> It keeps your location current for your
connections even when the app is closed, so their arrow stays accurate.</p>
<p><strong>How do I stop sharing?</strong> Remove a connection (••• → Remove) to stop
sharing with that person, or turn off Location in iOS Settings.</p>
<p><strong>How do I delete my account?</strong> Settings → Delete Account. This
permanently removes your account, location, and connections.</p>

<h2>Privacy</h2>
<p>See our <a href="/privacy">Privacy Policy</a>.</p>
</body>
</html>`;

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
    if (m === "GET" && (p === "/privacy" || p === "/privacy.html"))
      return sendHTML(res, PRIVACY_HTML);
    if (m === "GET" && (p === "/support" || p === "/support.html"))
      return sendHTML(res, SUPPORT_HTML);

    // Everything below requires a valid session token.
    const me = userForToken(req);
    if (!me) return send(res, 401, { error: "Not signed in." });

    if (m === "GET" && p === "/me") return handleMe(req, res, me);
    if (m === "POST" && p === "/me/delete")
      return await handleDeleteAccount(req, res, me);
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
    if (m === "POST" && p === "/connections/block")
      return await handleBlock(req, res, me);
    if (m === "POST" && p === "/connections/unblock")
      return await handleUnblock(req, res, me);
    if (m === "GET" && p === "/connections/blocked")
      return handleBlockedList(req, res, me);
    if (m === "POST" && p === "/location")
      return await handleLocationUpload(req, res, me);
    if (m === "POST" && p === "/location/stop")
      return await handleStopSharing(req, res, me);

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
