import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var serverURL = ServerSettings.serverURL
    @State private var email = AppConfig.defaultEmail
    @State private var password = ""
    @State private var displayName = ""
    @State private var isRegistering = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://192.168.1.8", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("The address of the computer running the server, on the same network as this phone.")
                }

                Section("Account") {
                    if isRegistering {
                        TextField("Display name", text: $displayName)
                            .textContentType(.name)
                    }
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(isRegistering ? .newPassword : .password)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking { ProgressView() } else { Text(isRegistering ? "Create account" : "Sign in").bold() }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)

                    Button(isRegistering ? "I already have an account" : "Create a new account") {
                        isRegistering.toggle()
                        errorMessage = nil
                    }
                    .frame(maxWidth: .infinity)
                }

                if isRegistering {
                    Section {
                        Text("Passwords need 12+ characters with upper and lower case letters, a digit and a symbol.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Location Tracker")
        }
    }

    private var canSubmit: Bool {
        !isWorking && !serverURL.isEmpty && !email.isEmpty && !password.isEmpty &&
            (!isRegistering || !displayName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func submit() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        ServerSettings.serverURL = url
        serverURL = url

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if isRegistering {
                try await session.register(email: trimmedEmail, password: password,
                                           displayName: displayName.trimmingCharacters(in: .whitespaces))
            } else {
                try await session.login(email: trimmedEmail, password: password)
            }
            password = ""
        } catch let error as URLError where error.code == .cancelled || error.code == .serverCertificateUntrusted
            || error.code == .secureConnectionFailed {
            errorMessage = "Could not establish a trusted connection. Check the server address and the pinned certificate fingerprint in AppConfig.swift."
        } catch let error as URLError {
            errorMessage = "Cannot reach the server: \(error.localizedDescription)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
