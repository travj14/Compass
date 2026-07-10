//
//  SettingsView.swift
//  Compass
//
//  Account settings, including permanent account deletion (required by the App
//  Store for any app that supports account creation — Guideline 5.1.1(v)).
//

import SwiftUI

/// User's chosen appearance. Persisted via @AppStorage and applied app-wide.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage("appearance") private var appearance: Appearance = .system

    @State private var showDeleteConfirm = false
    @State private var deleting = false

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if let u = app.currentUser {
                        LabeledContent("Username", value: "@\(u.username)")
                        LabeledContent("Name", value: u.displayName)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { a in
                            Text(a.label).tag(a)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("Share My Location", isOn: Binding(
                        get: { app.locationSharingEnabled },
                        set: { app.setLocationSharing($0) }
                    ))
                } footer: {
                    Text("When on, your accepted connections can see your location and point toward you. Turn off to stop sharing and remove your location from our servers.")
                }

                if !app.blockedUsers.isEmpty {
                    Section("Blocked") {
                        ForEach(app.blockedUsers) { b in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.user.displayName)
                                    Text("@\(b.user.username)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Unblock") {
                                    Task { await app.unblock(connectionId: b.connectionId) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                Section {
                    Button("Sign Out") { app.logout() }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Text("Delete Account")
                            if deleting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(deleting)
                } footer: {
                    Text("Permanently deletes your account, your stored location, and all of your connections. This can't be undone.")
                }

                Section {
                    Link("Privacy Policy", destination: app.privacyURL)
                }
            }
            .navigationTitle("Settings")
            .task { await app.refreshBlocked() }
            .alert("Delete Account?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    deleting = true
                    Task {
                        _ = await app.deleteAccount()
                        deleting = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes your account and all associated data. This cannot be undone.")
            }
        }
    }
}

private extension AppState {
    /// Privacy policy hosted by the same server the app talks to.
    var privacyURL: URL {
        api.baseURL.appendingPathComponent("privacy")
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
