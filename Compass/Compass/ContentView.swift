//
//  ContentView.swift
//  Compass
//
//  Root gate: signed out → AuthView; signed in → the Compass + People tabs.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.isSignedIn {
            TabView {
                CompassView()
                    .tabItem { Label("Compass", systemImage: "location.north.line.fill") }
                PeopleView()
                    .tabItem { Label("People", systemImage: "person.2.fill") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            }
        } else {
            AuthView()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .environment(LocationService())
        .environment(AvatarStore())
}
