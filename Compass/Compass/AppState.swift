//
//  AppState.swift
//  Compass
//
//  The single source of truth the SwiftUI views observe: who's signed in, the
//  connections list, and who the compass is pointing at. Talks to the server
//  through APIClient.
//

import Foundation
import SwiftUI

@Observable
@MainActor
final class AppState {
    var currentUser: APIUser?
    var connections: [Connection] = []
    var blockedUsers: [BlockedEntry] = []
    var selectedConnectionId: String?
    var errorMessage: String?
    var isBusy = false

    /// Whether the user has opted in to sharing their location with connections.
    /// Off until they explicitly consent (see the first-run consent prompt).
    var locationSharingEnabled = false
    /// Whether we've shown the one-time location-sharing consent yet.
    var hasAnsweredSharingConsent = false

    let api = APIClient()
    private let tokenKey = "compass.token"
    private let sharingKey = "compass.locationSharing"
    private let consentKey = "compass.sharingConsentAnswered"

    /// User's preferred ordering of connections (by connectionId). Stored on the
    /// server so it syncs across devices; mirrored here for the current session.
    /// New connections not yet in this list sort to the end.
    var connectionOrder: [String] = []

    var isSignedIn: Bool { currentUser != nil }

    var acceptedConnections: [Connection] { connections.filter(\.isAccepted) }
    var incomingRequests: [Connection] { connections.filter(\.isIncomingRequest) }
    var outgoingRequests: [Connection] { connections.filter(\.isOutgoingRequest) }

    /// Accepted connections in the user's chosen order (People-tab drag order).
    var orderedAcceptedConnections: [Connection] {
        func rank(_ id: String) -> Int { connectionOrder.firstIndex(of: id) ?? Int.max }
        return acceptedConnections.sorted { a, b in
            let ra = rank(a.connectionId), rb = rank(b.connectionId)
            return ra != rb ? ra < rb : a.user.displayName < b.user.displayName
        }
    }

    /// The connection the compass currently points at (falls back to the first
    /// in the ordered list so the compass has someone to aim at by default).
    var selectedConnection: Connection? {
        orderedAcceptedConnections.first { $0.connectionId == selectedConnectionId }
            ?? orderedAcceptedConnections.first
    }

    init() {
        locationSharingEnabled = UserDefaults.standard.bool(forKey: sharingKey)
        hasAnsweredSharingConsent = UserDefaults.standard.bool(forKey: consentKey)
        if let t = UserDefaults.standard.string(forKey: tokenKey), !t.isEmpty {
            api.token = t
            Task {
                await loadMe()
                await refreshConnections()
                await refreshBlocked()
            }
        }
    }

    /// The signed-in user hasn't yet chosen whether to share their location.
    var needsSharingConsent: Bool { isSignedIn && !hasAnsweredSharingConsent }

    /// Record the user's location-sharing choice. Turning it off also removes
    /// their stored location from the server so no one can see it.
    func setLocationSharing(_ on: Bool) {
        locationSharingEnabled = on
        hasAnsweredSharingConsent = true
        UserDefaults.standard.set(on, forKey: sharingKey)
        UserDefaults.standard.set(true, forKey: consentKey)
        if !on {
            Task { try? await api.send("/location/stop", method: "POST") }
        }
    }

    // MARK: - Blocking

    func refreshBlocked() async {
        do {
            let data = try await api.send("/connections/blocked")
            blockedUsers = try api.decode(BlockedResponse.self, from: data).blocked
        } catch {
            report(error)
        }
    }

    func block(userId: String) async {
        do {
            _ = try await api.send("/connections/block", method: "POST", json: ["userId": userId])
            await refreshConnections()
            await refreshBlocked()
        } catch {
            report(error)
        }
    }

    func unblock(connectionId: String) async {
        do {
            _ = try await api.send("/connections/unblock", method: "POST", json: ["connectionId": connectionId])
            await refreshBlocked()
        } catch {
            report(error)
        }
    }

    /// Reorder the People-tab list and push the new order to the server so it
    /// syncs across devices. Updates locally first (optimistic) for instant UI.
    func moveConnections(fromOffsets: IndexSet, toOffset: Int) {
        var ids = orderedAcceptedConnections.map(\.connectionId)
        ids.move(fromOffsets: fromOffsets, toOffset: toOffset)
        connectionOrder = ids
        Task { await saveConnectionOrder() }
    }

    private func saveConnectionOrder() async {
        do {
            _ = try await api.send("/connections/order",
                                   method: "POST",
                                   json: ["order": connectionOrder])
        } catch {
            report(error)
        }
    }

    // MARK: - Auth

    func signup(username: String, password: String, displayName: String) async {
        await authRequest("/auth/signup",
                          body: ["username": username,
                                 "password": password,
                                 "displayName": displayName])
    }

    func login(username: String, password: String) async {
        await authRequest("/auth/login",
                          body: ["username": username, "password": password])
    }

    private func authRequest(_ path: String, body: [String: Any]) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try await api.send(path, method: "POST", json: body)
            let res = try api.decode(AuthResponse.self, from: data)
            api.token = res.token
            UserDefaults.standard.set(res.token, forKey: tokenKey)
            currentUser = res.user
            errorMessage = nil
            await refreshConnections()
            await refreshBlocked()
        } catch {
            report(error)
        }
    }

    func logout() {
        api.token = nil
        UserDefaults.standard.removeObject(forKey: tokenKey)
        currentUser = nil
        connections = []
        blockedUsers = []
        selectedConnectionId = nil
        // Re-ask the location-sharing consent on the next sign-in.
        locationSharingEnabled = false
        hasAnsweredSharingConsent = false
        UserDefaults.standard.removeObject(forKey: sharingKey)
        UserDefaults.standard.removeObject(forKey: consentKey)
        errorMessage = nil // clear any stale error so it doesn't show on the login screen
    }

    /// Surface an error to the UI, but ignore cancellations — those happen when a
    /// screen is torn down mid-request (e.g. signing out), not a real failure.
    private func report(_ error: Error) {
        if case APIError.cancelled = error { return }
        errorMessage = error.localizedDescription
    }

    /// Permanently delete the account and all its data, then sign out locally.
    func deleteAccount() async -> Bool {
        do {
            _ = try await api.send("/me/delete", method: "POST")
            logout()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func loadMe() async {
        do {
            let data = try await api.send("/me")
            currentUser = try api.decode(MeResponse.self, from: data).user
        } catch {
            if case APIError.cancelled = error { return } // don't sign out on a cancelled request
            logout() // token no longer valid
        }
    }

    // MARK: - Connections

    func refreshConnections() async {
        do {
            let data = try await api.send("/connections")
            let res = try api.decode(ConnectionsResponse.self, from: data)
            connections = res.connections
            connectionOrder = res.order ?? []   // server is the source of truth
            if selectedConnectionId == nil {
                selectedConnectionId = orderedAcceptedConnections.first?.connectionId
            }
        } catch {
            report(error)
        }
    }

    func search(_ query: String) async -> [APIUser] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2,
              let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return [] }
        do {
            let data = try await api.send("/users/search?u=\(encoded)")
            return try api.decode(SearchResponse.self, from: data).users
        } catch {
            report(error)
            return []
        }
    }

    /// Returns true on success so the caller can show a confirmation.
    func invite(username: String) async -> Bool {
        do {
            _ = try await api.send("/connections/invite",
                                   method: "POST",
                                   json: ["username": username])
            await refreshConnections()
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Set (or clear, with an empty string) a custom name for a connection.
    func rename(connectionId: String, to name: String) async {
        do {
            _ = try await api.send("/connections/nickname",
                                   method: "POST",
                                   json: ["connectionId": connectionId, "nickname": name])
            await refreshConnections()
        } catch {
            report(error)
        }
    }

    /// Remove a friend. Ends location visibility for both people.
    func removeFriend(connectionId: String) async {
        do {
            _ = try await api.send("/connections/remove",
                                   method: "POST",
                                   json: ["connectionId": connectionId])
            if selectedConnectionId == connectionId { selectedConnectionId = nil }
            await refreshConnections()
        } catch {
            report(error)
        }
    }

    func respond(connectionId: String, accept: Bool) async {
        do {
            _ = try await api.send("/connections/respond",
                                   method: "POST",
                                   json: ["connectionId": connectionId,
                                          "action": accept ? "accept" : "decline"])
            await refreshConnections()
        } catch {
            report(error)
        }
    }

    // MARK: - Location

    /// Upload my current location so connected users can point at me. In the
    /// Simulator this is a fake coordinate; on a real device it's live GPS.
    func uploadMyLocation(lat: Double, lon: Double) async {
        do {
            _ = try await api.send("/location",
                                   method: "POST",
                                   json: ["lat": lat, "lon": lon])
        } catch {
            // Non-critical; don't surface an error for a background upload.
        }
    }
}
