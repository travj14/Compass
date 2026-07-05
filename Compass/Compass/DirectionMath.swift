//
//  DirectionMath.swift
//  Compass
//
//  Pure direction/distance math (see CLAUDE.md §4). No UI, no sensors here —
//  which makes it easy to reason about and test in the Simulator.
//

import CoreLocation

enum DirectionMath {

    /// Initial great-circle bearing from `from` toward `to`.
    /// Returns degrees in 0..<360, where 0 = true North, 90 = East.
    static func bearing(from: CLLocationCoordinate2D,
                        to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude.toRadians
        let lat2 = to.latitude.toRadians
        let dLon = (to.longitude - from.longitude).toRadians

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x).toDegrees
        return degrees.normalizedDegrees
    }

    /// The on-screen arrow rotation: how far to spin an "up" arrow so it points
    /// at the target relative to the way I'm facing.
    /// 0 = straight ahead, 90 = to my right, 180 = behind me, 270 = to my left.
    static func arrowAngle(bearing: Double, heading: Double) -> Double {
        (bearing - heading).normalizedDegrees
    }

    /// Straight-line distance between two coordinates, in meters.
    static func distanceMeters(from: CLLocationCoordinate2D,
                               to: CLLocationCoordinate2D) -> Double {
        let a = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let b = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return a.distance(from: b)
    }

    /// Human-friendly distance string, e.g. "1.2 mi" or "480 ft".
    static func formattedDistance(meters: Double, useMetric: Bool = false) -> String {
        if useMetric {
            if meters < 1000 {
                return "\(Int(meters.rounded())) m"
            }
            return String(format: "%.1f km", meters / 1000)
        } else {
            let feet = meters * 3.28084
            if feet < 528 { // under ~0.1 mi, show feet
                return "\(Int(feet.rounded())) ft"
            }
            let miles = meters / 1609.344
            return String(format: "%.1f mi", miles)
        }
    }

    /// Rough compass label for a bearing, e.g. "NE". This is the GPS-only
    /// direction the widget will eventually show (no live heading needed).
    static func cardinal(forBearing bearing: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((bearing.normalizedDegrees / 45).rounded()) % 8
        return points[index]
    }
}

private extension Double {
    var toRadians: Double { self * .pi / 180 }
    var toDegrees: Double { self * 180 / .pi }
    /// Wrap any degree value into 0..<360.
    var normalizedDegrees: Double {
        let r = truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}
