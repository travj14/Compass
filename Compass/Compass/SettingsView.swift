//
//  SettingsView.swift
//  Compass
//
//  Account settings, including permanent account deletion (required by the App
//  Store for any app that supports account creation — Guideline 5.1.1(v)).
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app

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
