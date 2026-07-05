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
    var selectedConnectionId: String?
    var errorMessage: String?
    var isBusy = false

    let api = APIClient()
    private let tokenKey = "compass.token"

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
        if let t = UserDefaults.standard.string(forKey: tokenKey), !t.isEmpty {
            api.token = t
            Task {
                await loadMe()
                await refreshConnections()
            }
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
            errorMessage = error.localizedDescription
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        api.token = nil
        UserDefaults.standard.removeObject(forKey: tokenKey)
        currentUser = nil
        connections = []
        selectedConnectionId = nil
    }

    func loadMe() async {
        do {
            let data = try await api.send("/me")
            currentUser = try api.decode(MeResponse.self, from: data).user
        } catch {
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
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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
