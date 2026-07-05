//
//  AuthView.swift
//  Compass
//
//  Dev login/signup (username + password). This is the temporary stand-in for
//  Sign in with Apple — when the paid Apple account is active, only this screen
//  changes; the rest of the app keeps working as-is.
//

import SwiftUI

struct AuthView: View {
    @Environment(AppState.self) private var app

    private enum Mode { case login, signup }
    @State private var mode: Mode = .login
    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                Text("Compass")
                    .font(.largeTitle.bold())
                Text("Point to the people you love.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: $mode) {
                Text("Log In").tag(Mode.login)
                Text("Sign Up").tag(Mode.signup)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            VStack(spacing: 12) {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)

                if mode == .signup {
                    TextField("Display name", text: $displayName)
                        .textInputAutocapitalization(.words)
                }

                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal)

            if let error = app.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button(action: submit) {
                if app.isBusy {
                    ProgressView()
                } else {
                    Text(mode == .login ? "Log In" : "Create Account")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .disabled(!formValid || app.isBusy)

            Spacer()
            Spacer()
        }
        .onChange(of: mode) { _, _ in app.errorMessage = nil }
    }

    private var formValid: Bool {
        !username.isEmpty && password.count >= 6
            && (mode == .login || !displayName.isEmpty)
    }

    private func submit() {
        Task {
            switch mode {
            case .login:
                await app.login(username: username, password: password)
            case .signup:
                await app.signup(username: username,
                                 password: password,
                                 displayName: displayName)
            }
        }
    }
}

#Preview {
    AuthView().environment(AppState())
}
