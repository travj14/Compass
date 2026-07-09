//
//  LocationConsentView.swift
//  Compass
//
//  Explicit, in-app consent for sharing your location with connections — shown
//  once after sign-in. Users can decline; the compass still works (it just won't
//  share your location back). Satisfies the App Store requirement to request
//  permission before displaying a user's location to others.
//

import SwiftUI

struct LocationConsentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "location.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("Share your location?")
                .font(.title.bold())

            Text("Homeward can share your current location with the people you've connected with, so they can point their compass toward you. Only your accepted connections can ever see it, and you can turn this off anytime in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    app.setLocationSharing(true)
                } label: {
                    Text("Share My Location")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    app.setLocationSharing(false)
                } label: {
                    Text("Not Now")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

#Preview {
    LocationConsentView().environment(AppState())
}
