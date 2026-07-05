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

    /// Live device heading in degrees (0 = true North). Comes from the
    /// magnetometer on a real iPhone; stays nil in the Simulator (no compass).
    var heading: Double?

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
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading
                                            : newHeading.magneticHeading
        Task { @MainActor in self.heading = h }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // Transient failures (e.g. no fix yet in the Simulator) are expected;
        // just keep waiting for the next update.
    }
}
