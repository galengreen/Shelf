import AuthenticationServices
import SwiftUI

struct LoginView: View {
    private enum Method: String, CaseIterable { case password = "Password", apiKey = "API Key" }
    private enum Field { case server, username, password, apiKey }
    private enum ServerCheck: Equatable { case idle, checking, ok(String), failed(String) }

    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @AppStorage("lastServer") private var server = ""
    @AppStorage("lastUsername") private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var method: Method = .password
    @State private var check: ServerCheck = .idle
    @State private var resolved: URL?
    @State private var status: ServerStatus?
    @State private var isSigningIn = false
    @State private var isSigningInWithSSO = false
    @State private var error: String?
    @FocusState private var focus: Field?

    var body: some View {
        ZStack {
            MeshGradient(
                width: 2, height: 2, points: [[0, 0], [1, 0], [0, 1], [1, 1]],
                colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.25), Color(.systemBackground), Color(.systemBackground)]
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 10) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 54, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(22)
                            .glassEffect(.regular, in: .rect(cornerRadius: 28))
                            .accessibilityHidden(true)
                        Text("Shelf")
                            .font(.bookTitle(.largeTitle))
                        Text("Connect to your Audiobookshelf server")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 48)

                    if let reason = model.signOutReason {
                        Label(reason, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 14) {
                        field("server.rack") {
                            TextField("Server address", text: $server, prompt: Text("https://abs.example.com"))
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .server)
                                .submitLabel(.next)
                                .onSubmit {
                                    focus = method == .password ? .username : .apiKey
                                    Task { await checkServer() }
                                }
                        }

                        serverStatus

                        if let status, status.offersOpenID {
                            Button {
                                Task { await signInWithOpenID() }
                            } label: {
                                Group {
                                    if isSigningInWithSSO {
                                        ProgressView()
                                    } else {
                                        Label(status.authFormData?.authOpenIDButtonText.nonEmpty ?? "Sign In with SSO", systemImage: "person.badge.key")
                                            .font(.headline)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            .disabled(isSigningIn)

                            if status.offersPassword {
                                Text("or")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let message = status?.authFormData?.authLoginCustomMessage?.strippingHTML.nonEmpty {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Picker("Sign in with", selection: $method) {
                            ForEach(Method.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.segmented)

                        if method == .password {
                            field("person") {
                                TextField("Username", text: $username)
                                    .textContentType(.username)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .focused($focus, equals: .username)
                                    .submitLabel(.next)
                                    .onSubmit { focus = .password }
                            }
                            field("lock") {
                                SecureField("Password", text: $password)
                                    .textContentType(.password)
                                    .focused($focus, equals: .password)
                                    .submitLabel(.go)
                                    .onSubmit { Task { await signIn() } }
                            }
                        } else {
                            field("key") {
                                SecureField("API key", text: $apiKey)
                                    .focused($focus, equals: .apiKey)
                                    .submitLabel(.go)
                                    .onSubmit { Task { await signIn() } }
                            }
                            Text("Create one on your server under Settings → API Keys.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button {
                            Task { await signIn() }
                        } label: {
                            Group {
                                if isSigningIn && !isSigningInWithSSO { ProgressView() } else { Text("Sign In").font(.headline) }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SignInButtonStyle(secondary: status?.offersOpenID == true))
                        .controlSize(.large)
                        .disabled(!canSubmit || isSigningIn)
                        .padding(.top, 4)
                    }
                    .padding(20)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                    .padding(.horizontal)
                    .animation(.smooth, value: method)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .task {
            // A remembered server: check it straight away so sign-in options (like SSO) appear.
            if !server.isEmpty, check == .idle { await checkServer() }
        }
        .onChange(of: server) {
            resolved = nil
            status = nil
            check = .idle
        }
        .onChange(of: focus) { old, _ in
            if old == .server { Task { await checkServer() } }
        }
    }

    private func field(_ icon: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(.background.opacity(0.6), in: .rect(cornerRadius: 14))
    }

    @ViewBuilder private var serverStatus: some View {
        switch check {
        case .idle: EmptyView()
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking server…") }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .ok(let version):
            Label("Audiobookshelf \(version)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canSubmit: Bool {
        !server.isEmpty && (method == .password ? !username.isEmpty : !apiKey.isEmpty)
    }

    private func checkServer() async {
        resolved = nil
        status = nil
        guard !server.isEmpty else { check = .idle; return }
        check = .checking
        do {
            let (url, found) = try await APIClient.resolve(server)
            resolved = url
            guard found.app == "audiobookshelf" || found.serverVersion != nil else {
                check = .failed("That doesn't look like an Audiobookshelf server")
                return
            }
            status = found
            check = .ok(found.serverVersion ?? "")
        } catch {
            check = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't reach the server")
        }
    }

    private func signInWithOpenID() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        isSigningInWithSSO = true
        error = nil
        defer { isSigningIn = false; isSigningInWithSSO = false }
        do {
            let url: URL
            if let resolved { url = resolved } else { url = try await APIClient.resolve(server).url }
            let pending = try await OpenIDLogin.begin(server: url)
            let callback = try await webAuthenticationSession.authenticate(
                using: pending.providerURL,
                callback: .customScheme(OpenIDLogin.callbackScheme),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
            )
            let credentials = try await pending.finish(callback: callback)
            server = url.absoluteString
            await model.signIn(credentials)
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            // Closed the sheet: nothing to report.
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func signIn() async {
        guard canSubmit, !isSigningIn else { return }
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }
        do {
            let url: URL
            if let resolved { url = resolved } else { url = try await APIClient.resolve(server).url }
            let credentials = method == .password
                ? try await APIClient.login(server: url, username: username.trimmingCharacters(in: .whitespaces), password: password)
                : try await APIClient.login(server: url, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            server = url.absoluteString
            password = ""
            await model.signIn(credentials)
        } catch APIError.unauthorized {
            error = method == .password ? "Incorrect username or password." : "That API key wasn't accepted."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// The password button steps back to a secondary style when single sign-on is the main option.
private struct SignInButtonStyle: PrimitiveButtonStyle {
    let secondary: Bool

    func makeBody(configuration: Configuration) -> some View {
        if secondary {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.glass)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.glassProminent)
        }
    }
}
