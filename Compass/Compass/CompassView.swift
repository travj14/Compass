//
//  CompassView.swift
//  Compass
//
//  The core "point at my partner" experience. MY location is now REAL (from
//  CoreLocation — a simulated location in the Simulator). MY heading is still a
//  slider (no magnetometer off-device). The PARTNER's location is real, from the
//  server, for whoever is selected.
//
//  Location is required: if it's denied, the compass is empty and says so, and
//  no one else's location can be shown.
//
//  Convention (CLAUDE.md §4):
//    arrow up (0°) = partner straight ahead · 90 = right · 180 = behind · 270 = left
//

import SwiftUI
import CoreLocation

struct CompassView: View {
    @Environment(AppState.self) private var app
    @Environment(LocationService.self) private var location
    @Environment(\.openURL) private var openURL

    @State private var heading: Double = 0
    @State private var displayedAngle: Double = 0    // needle (continuous, unwrapped)
    @State private var displayedHeading: Double = 0  // ring (continuous, unwrapped)

    // MARK: - Selected partner

    private var partner: Connection? { app.selectedConnection }
    private var partnerName: String { partner?.displayLabel ?? "Demo partner" }

    /// Fallback partner (Oakland) so the compass still demonstrates itself before
    /// you have connections.
    private let demoPartner = CLLocationCoordinate2D(latitude: 37.8044, longitude: -122.2712)
    private var partnerCoordinate: CLLocationCoordinate2D {
        partner?.location?.coordinate ?? demoPartner
    }

    // MARK: - Derived geometry (only meaningful once we have my location)

    private var bearing: Double {
        guard let me = location.currentLocation else { return 0 }
        return DirectionMath.bearing(from: me, to: partnerCoordinate)
    }

    /// On a real phone the heading is the live magnetometer; in the Simulator
    /// (no compass) it's the slider.
    private var effectiveHeading: Double {
        #if targetEnvironment(simulator)
        return heading
        #else
        return location.heading ?? 0
        #endif
    }

    private var arrowAngle: Double {
        DirectionMath.arrowAngle(bearing: bearing, heading: effectiveHeading)
    }
    private func distanceText(from me: CLLocationCoordinate2D) -> String {
        DirectionMath.formattedDistance(
            meters: DirectionMath.distanceMeters(from: me, to: partnerCoordinate)
        )
    }

    var body: some View {
        VStack(spacing: 28) {
            if location.isDenied {
                deniedState
            } else if let me = location.currentLocation {
                activeState(me: me)
            } else {
                locatingState
            }
        }
        .padding()
        .onAppear {
            displayedAngle = arrowAngle
            displayedHeading = effectiveHeading
        }
        .onChange(of: arrowAngle) { _, newTarget in rotate(to: newTarget) }
        .onChange(of: effectiveHeading) { _, newHeading in rotateRing(to: newHeading) }
        .onChange(of: locationKey) { _, _ in uploadMyLocation() }
    }

    // MARK: - Location required (denied)

    private var deniedState: some View {
        VStack(spacing: 24) {
            Spacer()
            emptyCompass
            VStack(spacing: 8) {
                Text("Location is off")
                    .font(.title3.weight(.semibold))
                Text("Compass needs your location to point at anyone. Turn it on in Settings to use the app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
            Spacer(); Spacer()
        }
    }

    // MARK: - Waiting for a fix

    private var locatingState: some View {
        VStack(spacing: 24) {
            Spacer()
            emptyCompass
            VStack(spacing: 6) {
                ProgressView()
                Text("Finding your location…")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Simulator: set one via Features → Location.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(); Spacer()
        }
    }

    // MARK: - Active compass

    private func activeState(me: CLLocationCoordinate2D) -> some View {
        VStack(spacing: 28) {
            partnerHeader
            compass.frame(width: 240, height: 240)
            VStack(spacing: 4) {
                Text(distanceText(from: me))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("away").font(.headline).foregroundStyle(.secondary)
            }
            #if targetEnvironment(simulator)
            simulatorControls
            #else
            liveCompassHint
            #endif
        }
    }

    private var liveCompassHint: some View {
        Text("Hold your phone flat and point the top away from you.")
            .font(.caption).foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }

    // Dropdown to choose who the compass points at.
    @ViewBuilder
    private var partnerHeader: some View {
        VStack(spacing: 6) {
            if let p = partner {
                AvatarView(userId: p.user.id, name: p.displayLabel, size: 44)
            }
            Text("Pointing at")
                .font(.subheadline).foregroundStyle(.secondary)

            if app.orderedAcceptedConnections.isEmpty {
                Text(partnerName).font(.title2.weight(.semibold))
                Text("demo — add someone on the People tab")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Menu {
                    ForEach(app.orderedAcceptedConnections) { conn in
                        Button {
                            app.selectedConnectionId = conn.connectionId
                        } label: {
                            if conn.connectionId == app.selectedConnection?.connectionId {
                                Label(conn.displayLabel, systemImage: "checkmark")
                            } else {
                                Text(conn.displayLabel)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(partnerName).font(.title2.weight(.semibold))
                        Image(systemName: "chevron.down").font(.footnote)
                    }
                }
                .tint(.primary)

                if let loc = partner?.location {
                    Text(loc.freshness).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Compass visuals

    private var emptyCompass: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            Image(systemName: "location.slash")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 240, height: 240)
        .opacity(0.6)
    }

    private var compass: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            cardinalRing
            ArrowShape()
                .fill(.tint)
                .frame(width: 70, height: 100)
                .rotationEffect(.degrees(displayedAngle))
        }
    }

    private var cardinalRing: some View {
        let cardinals: [(name: String, bearing: Double)] =
            [("N", 0), ("E", 90), ("S", 180), ("W", 270)]
        let radius: CGFloat = 102
        return ForEach(cardinals, id: \.name) { c in
            let theta = c.bearing - displayedHeading
            Text(c.name)
                .font(.headline.weight(c.name == "N" ? .bold : .regular))
                .foregroundStyle(c.name == "N" ? Color.red : Color.secondary)
                .rotationEffect(.degrees(-theta))
                .offset(y: -radius)
                .rotationEffect(.degrees(theta))
        }
    }

    private var simulatorControls: some View {
        VStack(spacing: 8) {
            Text("Simulated heading: \(Int(heading))°")
                .font(.footnote.monospaced()).foregroundStyle(.secondary)
            Slider(value: $heading, in: 0...359)
            Text("Simulator only — on a real phone this comes from the compass.")
                .font(.caption2).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    // MARK: - Helpers

    /// A value that changes whenever my location moves, to drive uploads.
    private var locationKey: String {
        guard let c = location.currentLocation else { return "none" }
        return "\(c.latitude),\(c.longitude)"
    }

    private func uploadMyLocation() {
        // Only share my location if I've opted in (App Store consent requirement).
        guard app.locationSharingEnabled, let me = location.currentLocation else { return }
        Task { await app.uploadMyLocation(lat: me.latitude, lon: me.longitude) }
    }

    /// Turn `displayedAngle` toward `target` the short way, with a loose spring.
    private func rotate(to target: Double) {
        let delta = (target - displayedAngle).truncatingRemainder(dividingBy: 360)
        let shortest = delta > 180 ? delta - 360 : (delta < -180 ? delta + 360 : delta)
        // Looser, floatier needle: lower dampingFraction = more overshoot/wobble,
        // longer response = slower, freer swing.
        withAnimation(.spring(response: 0.9, dampingFraction: 0.22)) {
            displayedAngle += shortest
        }
    }

    /// Glide the cardinal ring between the magnetometer's discrete heading steps
    /// so it flows instead of ticking (what Apple's Compass does). Continuous +
    /// shortest-path so it never spins the long way at the 0°/360° seam.
    private func rotateRing(to target: Double) {
        let delta = (target - displayedHeading).truncatingRemainder(dividingBy: 360)
        let shortest = delta > 180 ? delta - 360 : (delta < -180 ? delta + 360 : delta)
        withAnimation(.linear(duration: 0.2)) {
            displayedHeading += shortest
        }
    }
}

/// A simple arrowhead that points straight up within its frame.
struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: w * 0.5, y: 0))
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.72))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }
}

#Preview {
    CompassView()
        .environment(AppState())
        .environment(LocationService())
        .environment(AvatarStore())
}
