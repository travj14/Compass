//
// Seed script: creates 5 fake users in different US cities and connects them
// (accepted) to `alice`. Idempotent — safe to run more than once.
//
//   node seed.js
//
const BASE = process.env.BASE || "http://localhost:4000";

const OWNER = { username: "alice", password: "secret1" };

const FAKES = [
  { username: "emma_ny",  displayName: "Emma Rivera",  city: "New York, NY",  lat: 40.7128,  lon: -74.0060 },
  { username: "liam_chi", displayName: "Liam Chen",    city: "Chicago, IL",   lat: 41.8781,  lon: -87.6298 },
  { username: "olivia_den", displayName: "Olivia Park", city: "Denver, CO",   lat: 39.7392,  lon: -104.9903 },
  { username: "noah_atx", displayName: "Noah Brooks",  city: "Austin, TX",    lat: 30.2672,  lon: -97.7431 },
  { username: "ava_sea",  displayName: "Ava Nguyen",   city: "Seattle, WA",   lat: 47.6062,  lon: -122.3321 },
];

async function api(path, { method = "GET", token, body } = {}) {
  const res = await fetch(BASE + path, {
    method,
    headers: {
      ...(body ? { "Content-Type": "application/json" } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  return { status: res.status, data };
}

// signup, or log in if the user already exists
async function ensureUser(u) {
  let r = await api("/auth/signup", {
    method: "POST",
    body: { username: u.username, password: "secret1", displayName: u.displayName },
  });
  if (r.status === 409) {
    r = await api("/auth/login", { method: "POST", body: { username: u.username, password: "secret1" } });
  }
  return r.data; // { token, user }
}

async function main() {
  // Create the demo owner if it doesn't exist yet (a fresh server is empty),
  // otherwise log in. Password is "secret1".
  const owner = await ensureUser({ username: OWNER.username, displayName: "Alice Demo" });
  if (!owner.token) {
    console.error("Could not create or log in as the demo owner. Is the server reachable?");
    process.exit(1);
  }

  for (const f of FAKES) {
    const { token, user } = await ensureUser(f);

    // Set their location to their city.
    await api("/location", { method: "POST", token, body: { lat: f.lat, lon: f.lon } });

    // alice invites them (skip if a connection already exists).
    const inv = await api("/connections/invite", { method: "POST", token: owner.token, body: { username: f.username } });
    if (inv.status !== 200 && inv.status !== 409) {
      console.log(`  invite ${f.username}: ${inv.data.error || inv.status}`);
    }

    // They accept alice's incoming request (if still pending).
    const conns = (await api("/connections", { token })).data.connections || [];
    const pending = conns.find((c) => c.direction === "incoming" && c.status === "pending");
    if (pending) {
      await api("/connections/respond", { method: "POST", token, body: { connectionId: pending.connectionId, action: "accept" } });
    }

    console.log(`✓ ${f.displayName.padEnd(14)} @${f.username.padEnd(11)} ${f.city}`);
  }

  console.log("\nDone. Log in as alice / secret1 to see them.");
}

main().catch((e) => { console.error(e); process.exit(1); });
