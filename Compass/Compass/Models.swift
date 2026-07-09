//
//  Models.swift
//  Compass
//
//  Codable types mirroring the server's JSON (CLAUDE.md §5) and small helpers.
//

import Foundation
import CoreLocation

struct APIUser: Codable, Identifiable, Hashable {
    let id: String
    let username: String
    let displayName: String
}

/// A partner's latest location as stored/served by the backend.
struct PartnerLocation: Codable, Hashable {
    let lat: Double
    let lon: Double
    let accuracy: Double?
    let updatedAt: Double // milliseconds since epoch

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// "updated 30s ago", "updated 5m ago", etc.
    var freshness: String {
        let seconds = Date().timeIntervalSince1970 - updatedAt / 1000
        if seconds < 60 { return "updated \(Int(max(0, seconds)))s ago" }
        if seconds < 3600 { return "updated \(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "updated \(Int(seconds / 3600))h ago" }
        return "updated \(Int(seconds / 86400))d ago"
    }
}

/// One relationship, as returned by GET /connections.
struct Connection: Codable, Identifiable, Hashable {
    let connectionId: String
    let user: APIUser
    let status: String    // "pending" | "accepted"
    let direction: String // "incoming" | "outgoing"
    let location: PartnerLocation?
    let nickname: String?  // custom name you set for this person (optional)

    var id: String { connectionId }
    var isAccepted: Bool { status == "accepted" }
    var isIncomingRequest: Bool { status == "pending" && direction == "incoming" }
    var isOutgoingRequest: Bool { status == "pending" && direction == "outgoing" }

    /// What to show: your custom name if set, otherwise their display name.
    var displayLabel: String {
        if let n = nickname, !n.isEmpty { return n }
        return user.displayName
    }
}

// MARK: - Response envelopes

struct AuthResponse: Decodable { let token: String; let user: APIUser }
struct MeResponse: Decodable { let user: APIUser }
struct SearchResponse: Decodable { let users: [APIUser] }
struct ConnectionsResponse: Decodable { let connections: [Connection]; let order: [String]? }

struct BlockedEntry: Codable, Identifiable, Hashable {
    let connectionId: String
    let user: APIUser
    var id: String { connectionId }
}
struct BlockedResponse: Decodable { let blocked: [BlockedEntry] }
struct LocationResponse: Decodable { let location: PartnerLocation }
