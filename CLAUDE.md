# Compass — "Point to My Partner" App

## 1. What we're building

An iPhone app that replaces the compass needle with an arrow that always
points toward another person's real-world location.

- Open the app, hold up your phone like a compass, and the arrow swings to
  point at your partner (or anyone you're connected with).
- If you're facing **away** from them → arrow points **down/back**.
- If they're to your **right** → arrow points **right**.
- Also shows **distance** (e.g. "1.2 mi away") and how fresh the location is.

Think: "Find My" reimagined as a warm, personal pointing compass.

### Users & scope
- Real **user accounts**, each with a chosen **username**.
- You invite people by **looking up their username**.
- You can be connected to **multiple people**; "your partner" is just one of
  them. The main compass lets you pick who to point at (default: your partner).

---

## 2. THE most important technical reality (read this first)

The live pointing arrow needs **two live inputs at once**:
1. The other person's **GPS location** (from our server).
2. **My phone's compass heading** — which way I'm physically facing
   (magnetometer via CoreLocation).

Arrow angle = *bearing to them* − *my heading*.

**The magnetometer only works while the app is open in the foreground.** iOS
does NOT give background code or widgets access to the compass, and widgets only
refresh on a slow, OS-throttled timeline (~every 15 min, budgeted per day).

### Consequences (decided, not open for debate — this is an iOS platform limit)
- The **live rotating arrow is an app-open experience.** You hold up your phone;
  it points. This is the product, and it fully works.
- A **home/lock-screen widget CANNOT** show a live body-relative arrow — no
  compass access + slow refresh. Proof: **Apple's own Find My** only shows its
  live "point-me-to-it" arrow *inside the app*; its widget is just a map +
  distance. That's the ceiling for everyone.
- The **widget is a glanceable teaser only**: distance + rough cardinal
  direction (GPS-only) + "tap to open the live compass." Updates ~every 15 min.

| Feature | In-app (foreground) | Widget |
|---|---|---|
| Live rotating arrow (compass) | ✅ the real magic | ❌ impossible |
| Distance to partner | ✅ | ✅ (~15 min refresh) |
| Rough cardinal direction (GPS only) | ✅ | ✅ (~15 min refresh) |
| Tap to open live compass | — | ✅ |

**Does the partner's location stay current when they're NOT in the app? YES** —
via "Always" + background location (see §6). Not second-by-second while idle,
but current within a few minutes / few hundred meters, and precise the moment
either person opens the app. Same mechanism as Find My / Life360.

---

## 3. Tech stack

- **Language:** Swift · **UI:** SwiftUI
- **Location & heading:** CoreLocation (`CLLocationManager`)
- **Backend:** **Our own server** (user already owns one) exposing a small HTTPS
  API. (We chose this over CloudKit so we control accounts, usernames, and the
  connections list — and it avoids CloudKit's constraints.)
- **Auth / identity:** **Sign in with Apple** (Face ID, no passwords for us to
  store or leak) + a user-chosen **username** on top.
- **Networking:** `URLSession` (plain HTTPS — no special Apple entitlement).
- **Widget:** WidgetKit + App Intents. Widget fetches distance/direction from
  the server (or a shared App Group container) itself.
- **Account:** Paid **Apple Developer Program ($99/yr)** — DECIDED. Needed for
  stable on-device installs (free signing expires every 7 days), widgets, App
  Groups, background modes, and eventual TestFlight/App Store.

---

## 4. Direction math

```
Given: myLat, myLon (my GPS), theirLat, theirLon (from server),
       myHeading (degrees, 0 = North, from CoreLocation trueHeading)

Bearing from me to them (great-circle initial bearing):
  Δlon = theirLon - myLon
  y = sin(Δlon) * cos(theirLat)
  x = cos(myLat)*sin(theirLat) - sin(myLat)*cos(theirLat)*cos(Δlon)
  bearing = atan2(y, x)        // radians → degrees, normalize 0..360

Arrow rotation on screen:
  arrowAngle = bearing - myHeading   // normalize 0..360
  // 0 = straight ahead, 90 = right, 180 = behind, 270 = left

Distance: CLLocation.distance(from:) → meters → format mi/km
```

Convert lat/lon **degrees → radians** before trig. Use `trueHeading` (fall back
to `magneticHeading`). Smooth/animate the arrow so it doesn't jitter.

---

## 5. Accounts, usernames & sharing (the social model)

### Rules
- On first launch: **Sign in with Apple**, then **pick a unique username**.
- Invite someone by **searching their username**.
- **Consent model (DECIDED): mutual accept + mutual sharing.**
  - A invites B → B must **approve** → then **both** can see each other.
  - Either person can **pause / stop sharing** at any time.
- A user can view **all people they're connected with** (the connections list)
  and pick who the compass points at.

### Server data model (sketch)
```
users:        id, apple_user_id, username (unique), display_name, created_at
locations:    user_id, lat, lon, accuracy, updated_at        (latest only)
connections:  requester_id, addressee_id, status(pending|accepted|blocked),
              created_at            // one row per relationship
```

### Server API (sketch — small HTTPS service on our server)
```
POST /auth/apple            verify Apple identity token → issue our session token
POST /me/username           set/choose username (uniqueness check)
GET  /users/search?u=name   look up a username to invite
POST /connections/invite    request to connect with a username
POST /connections/respond   accept / decline an invite
GET  /connections           list my connections + their status
POST /location              upload my {lat,lon,accuracy,ts}  (auth required)
GET  /connections/:id/location   fetch a connected user's latest location
```
- **HTTPS/TLS required** (iOS App Transport Security blocks plain HTTP) — free
  via Let's Encrypt.
- Auth every request with the session token; only return a location if an
  **accepted** connection exists between the two users.
- Store only the **latest** location per user (no history trail).

---

## 6. Location, permissions & privacy

- Request **When In Use** first; then **Always** (needed so a partner's location
  stays fresh when the app isn't open). Explain *why* in the prompt.
- **Background updates:** use **significant-location-change** monitoring — low
  power, keeps working even if the app is closed (iOS relaunches it). Turn on
  high-accuracy continuous updates only while the compass screen is foreground.
- iOS will **periodically re-ask** the user to keep allowing background location
  — they must keep tapping **Allow**, or freshness stops.
- **Info.plist strings (required or the app crashes):**
  - `NSLocationWhenInUseUsageDescription`
  - `NSLocationAlwaysAndWhenInUseUsageDescription`
- **Capabilities to enable in Xcode:** Sign in with Apple, Background Modes →
  Location updates, App Groups (for the widget).
- **Privacy:** mutual consent before any location is visible; one-tap
  stop-sharing / unpair / block; store minimal data; never sell/share location.

---

## 7. App architecture

```
CompassApp (SwiftUI @main)
├── Auth            Sign in with Apple → session token → choose username
├── APIClient       URLSession wrapper for the server API (§5)
├── LocationService CLLocationManager: my location + heading; uploads location
│                   (significant-change in background, high-accuracy foreground)
├── ConnectionsStore  fetch/search users, send/accept invites, list connections
├── CompassView     big rotating arrow (bearing − myHeading), distance,
│                   selected person, freshness ("updated 30s ago")
├── PeopleView      list of connections; pick who to point at; invite by username
└── SettingsView    username, units mi/km, pause sharing, unpair/block, privacy

CompassWidget (WidgetKit extension target)
├── Fetches selected person's distance + cardinal direction from server / App Group
├── Shows distance + rough direction + name; ~15 min refresh
└── Tap → opens the app's live compass
```

---

## 8. Build order (milestones)

**M0 — Setup:** Install Xcode; enroll in Apple Developer Program ($99);
new SwiftUI project `Compass`; run empty app on a **real iPhone** (Simulator
has no compass).

**M1 — Live compass with a FAKE partner (no server yet):** CoreLocation
permission + heading; hardcode a fake coordinate; draw the arrow and make it
point as I turn. ← *Proves the core magic before any networking.*

**M2 — Backend + accounts:** Stand up the server API (§5); Sign in with Apple;
choose username; upload/fetch location; replace the fake coordinate with a real
connected user.

**M3 — Social flow:** username search, invite, mutual accept, connections list,
pick-who-to-point-at, pause/stop sharing.

**M4 — Polish:** distance formatting, freshness, arrow smoothing, empty/error
states (location denied, no GPS, stale/paused partner), avatars.

**M5 — Widget:** WidgetKit extension + App Group; distance + cardinal direction;
tap opens the app.

**M6 — Real-device testing & release:** test with partner's actual phone;
TestFlight; decide on App Store submission.

---

## 9. Open questions / to revisit
- [ ] Background update frequency vs. battery (significant-change is the default).
- [ ] What the widget shows when a partner has paused sharing or data is stale.
- [ ] Live Activity on the lock screen as a v2? (More frequent than a widget but
      still no compass — would show distance/bearing, not a body-relative arrow.)
- [ ] App name & icon.
- [ ] Rate-limit username search to prevent enumeration/abuse.

---

## 10. Working style notes for Claude
- User is **brand new to iOS/Swift** — explain new concepts briefly on first
  use; give exact click-by-click steps for Xcode GUI tasks (capabilities,
  signing, Info.plist); don't assume Xcode knowledge.
- Build in **milestone order**; prove the compass with a fake partner (M1)
  before any networking.
- Prefer SwiftUI + minimal/zero third-party dependencies.
- Backend runs on the **user's own server**; ask about its stack (Node/Python/
  Go, domain + HTTPS) before writing server code.
- Be honest about iOS platform limits (esp. widgets) rather than over-promising.
