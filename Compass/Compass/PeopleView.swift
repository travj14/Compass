//
//  PeopleView.swift
//  Compass
//
//  The social hub (CLAUDE.md §5): people who added you, your connections (pick
//  who the compass points at, reorder, rename / set photo / remove), and inviting
//  new people by username.
//

import SwiftUI
import PhotosUI

struct PeopleView: View {
    @Environment(AppState.self) private var app
    @Environment(AvatarStore.self) private var avatars

    @State private var query = ""
    @State private var results: [APIUser] = []
    @State private var searching = false
    @State private var toast: String?

    // ••• editing state (hoisted so there's one of each presentation)
    @State private var editTarget: Connection?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showRemoveConfirm = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showBlockConfirm = false

    var body: some View {
        NavigationStack {
            List {
                addSection

                if !app.incomingRequests.isEmpty {
                    Section("Added me") {
                        ForEach(app.incomingRequests) { conn in
                            addedMeRow(conn)
                        }
                    }
                }

                Section("Connected") {
                    if app.orderedAcceptedConnections.isEmpty {
                        Text("No connections yet. Invite someone above.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(app.orderedAcceptedConnections) { conn in
                            connectedRow(conn)
                        }
                        .onMove(perform: app.moveConnections)
                    }
                }

                if !app.outgoingRequests.isEmpty {
                    Section("Requests you sent") {
                        ForEach(app.outgoingRequests) { conn in
                            HStack {
                                AvatarView(userId: conn.user.id, name: conn.user.displayName, size: 36)
                                personLabel(conn.user)
                                Spacer()
                                Text("Pending").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !app.orderedAcceptedConnections.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let me = app.currentUserLabel { Text(me) }
                        Button("Sign Out", role: .destructive) { app.logout() }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .refreshable { await app.refreshConnections() }
            .overlay(alignment: .bottom) { toastView }
            .task { await app.refreshConnections() }
            // ••• menu presentations
            .alert("Rename", isPresented: $showRename) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let c = editTarget {
                        Task { await app.rename(connectionId: c.connectionId, to: renameText) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Set a custom name for \(editTarget?.user.displayName ?? "this person").")
            }
            .confirmationDialog(
                "Remove \(editTarget?.displayLabel ?? "")?",
                isPresented: $showRemoveConfirm, titleVisibility: .visible
            ) {
                Button("Remove Friend", role: .destructive) {
                    if let c = editTarget {
                        Task { await app.removeFriend(connectionId: c.connectionId) }
                    }
                }
            } message: {
                Text("You'll both stop seeing each other's location.")
            }
            .confirmationDialog(
                "Block \(editTarget?.displayLabel ?? "")?",
                isPresented: $showBlockConfirm, titleVisibility: .visible
            ) {
                Button("Block", role: .destructive) {
                    if let c = editTarget {
                        Task { await app.block(userId: c.user.id) }
                    }
                }
            } message: {
                Text("They'll be removed from your connections and won't be able to find, contact, or see you.")
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in loadPhoto(item) }
        }
    }

    // MARK: - Add by username

    private var addSection: some View {
        Section("Invite by username") {
            HStack {
                TextField("Search username…", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { runSearch() }
                Button("Search", action: runSearch)
                    .disabled(query.trimmingCharacters(in: .whitespaces).count < 2)
            }
            if searching { ProgressView() }
            ForEach(results) { user in
                HStack {
                    AvatarView(userId: user.id, name: user.displayName, size: 36)
                    personLabel(user)
                    Spacer()
                    Button("Invite") { invite(user) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Rows

    // Snapchat-style: Add to accept, ✕ to dismiss so it won't show again.
    private func addedMeRow(_ conn: Connection) -> some View {
        HStack {
            AvatarView(userId: conn.user.id, name: conn.user.displayName, size: 40)
            personLabel(conn.user)
            Spacer()
            Button("Add") {
                Task { await app.respond(connectionId: conn.connectionId, accept: true) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                Task { await app.respond(connectionId: conn.connectionId, accept: false) }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .swipeActions {
            Button("Block", role: .destructive) {
                Task { await app.block(userId: conn.user.id) }
            }
        }
    }

    private func connectedRow(_ conn: Connection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: app.selectedConnectionId == conn.connectionId
                  ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(.tint)
            AvatarView(userId: conn.user.id, name: conn.displayLabel, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(conn.displayLabel)
                Text(conn.location?.freshness ?? "no location yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    editTarget = conn
                    renameText = conn.nickname ?? ""
                    showRename = true
                } label: { Label("Rename", systemImage: "pencil") }
                Button {
                    editTarget = conn
                    showPhotoPicker = true
                } label: { Label("Change Photo", systemImage: "photo") }
                Button(role: .destructive) {
                    editTarget = conn
                    showRemoveConfirm = true
                } label: { Label("Remove", systemImage: "trash") }
                Button(role: .destructive) {
                    editTarget = conn
                    showBlockConfirm = true
                } label: { Label("Block", systemImage: "hand.raised") }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44) // easy tap target
                    .contentShape(Rectangle())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.selectedConnectionId = conn.connectionId }
    }

    private func personLabel(_ user: APIUser) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(user.displayName)
            Text("@\(user.username)").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 8)
                .transition(.opacity)
        }
    }

    // MARK: - Actions

    private func runSearch() {
        searching = true
        Task {
            results = await app.search(query)
            searching = false
        }
    }

    private func invite(_ user: APIUser) {
        Task {
            let ok = await app.invite(username: user.username)
            showToast(ok ? "Invite sent to @\(user.username)"
                         : (app.errorMessage ?? "Couldn't send invite"))
            if ok {
                results.removeAll { $0.id == user.id }
                query = ""
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item, let target = editTarget else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                avatars.setImage(img, for: target.user.id)
                showToast("Photo updated")
            }
            photoItem = nil
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }
}

private extension AppState {
    var currentUserLabel: String? {
        guard let u = currentUser else { return nil }
        return "Signed in as @\(u.username)"
    }
}

#Preview {
    PeopleView()
        .environment(AppState())
        .environment(AvatarStore())
}
