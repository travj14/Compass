//
//  LocationService.swift
//  Compass
//
//  Wraps CLLocationManager to provide MY location and authorization status.
//  The app requires location: without it the compass can't compute a bearing
//  and can't show anyone else's position.
//
//  Simulator note: there's no real GPS. Set a location via the Simulator menu
//  Features → Location → (a city or Custom Location) and it flows in here.
//  (There's still no magnetometer, so heading stays a slider for now.)
//

import Foundation
import CoreLocation
import Observation

@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var currentLocation: CLLocationCoordinate2D?

    /// Live device heading in degrees (0 = true North), low-pass filtered so the
    /// compass glides instead of twitching. Comes from the magnetometer on a real
    /// iPhone; stays nil in the Simulator (no compass).
    var heading: Double?

    /// Running smoothed value behind `heading` (see applyHeading).
    private var smoothedHeading: Double?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = manager.authorizationStatus
    }

    /// Ask for permission. iOS requires a two-step escalation: first "When In
    /// Use", then an upgrade prompt to "Always". We start at whichever step the
    /// current status calls for.
    func requestPermission() {
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization() // escalate to background/Always
        default:
            break
        }
        if isAuthorized(authorizationStatus) {
            startUpdates()
        }
    }

    /// Foreground: high-accuracy continuous updates. Background: significant-
    /// location-change monitoring, which is low-power and keeps a partner's
    /// location current even when the app is closed (iOS relaunches it). §6
    private func startUpdates() {
        // Safe only because Info.plist declares the "location" background mode;
        // setting this without that key would crash at runtime.
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        // Live compass — the real magic. No-op in the Simulator (no magnetometer).
        if CLLocationManager.headingAvailable() {
            // Report every change (not just ≥1°) so the low-pass filter has
            // enough samples to produce smooth motion.
            manager.headingFilter = kCLHeadingFilterNone
            manager.startUpdatingHeading()
        }
    }

    var isAuthorized: Bool { isAuthorized(authorizationStatus) }
    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    private func isAuthorized(_ s: CLAuthorizationStatus) -> Bool {
        s == .authorizedWhenInUse || s == .authorizedAlways
    }

    // MARK: - CLLocationManagerDelegate (called on the main thread by CoreLocation)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            switch status {
            case .authorizedWhenInUse:
                // Got "When In Use" — immediately ask to upgrade to "Always".
                manager.requestAlwaysAuthorization()
                self.startUpdates()
            case .authorizedAlways:
                self.startUpdates()
            default:
                self.currentLocation = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let coord = locations.last?.coordinate else { return }
        Task { @MainActor in self.currentLocation = coord }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateHeading newHeading: CLHeading) {
        // Prefer true (geographic) north; fall back to magnetic north.
        // trueHeading is negative when it isn't yet available.
        let raw = newHeading.trueHeading >= 0 ? newHeading.trueHeading
                                              : newHeading.magneticHeading
        // CoreLocation delivers on the main run loop (manager was created on the
        // main actor), so we're already isolated here.
        MainActor.assumeIsolated { self.applyHeading(raw) }
    }

    /// Exponential low-pass filter over the noisy magnetometer, handling the
    /// 0°/360° wrap. `factor` closer to 0 = smoother but laggier; closer to 1 =
    /// snappier but jitterier. 0.2 is a calm-but-responsive middle.
    private func applyHeading(_ raw: Double) {
        guard let current = smoothedHeading else {
            smoothedHeading = raw
            heading = raw
            return
        }
        var delta = (raw - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        var next = current + delta * 0.2
        next = next.truncatingRemainder(dividingBy: 360)
        if next < 0 { next += 360 }
        smoothedHeading = next
        heading = next
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // Transient failures (e.g. no fix yet in the Simulator) are expected;
        // just keep waiting for the next update.
    }
}
