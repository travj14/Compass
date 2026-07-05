//
//  CompassApp.swift
//  Compass
//

import SwiftUI

@main
struct CompassApp: App {
    @State private var app = AppState()
    @State private var location = LocationService()
    @State private var avatars = AvatarStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .environment(location)
                .environment(avatars)
                .task { location.requestPermission() }
        }
    }
}
