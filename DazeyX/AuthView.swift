// AuthView.swift
// Gate: the camera is only created once the user is signed in.

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView().tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
        case .signedOut:
            AuthView()
        case .signedIn:
            CameraView()
        }
    }
}

struct AuthView: View {
    @EnvironmentObject private var auth: AuthManager

    private enum Mode { case signIn, signUp }
    private enum Field { case email, password, confirm }

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?
    @FocusState private var focus: Field?

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private var canSubmit: Bool {
        guard !busy, trimmedEmail.contains("@"), password.count >= 6 else { return false }
        return mode == .signIn || password == confirm
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text("Dazey X").font(.system(size: 40, weight: .bold))
                    Text(mode == .signIn ? "Sign in to continue" : "Create your account")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, 80)

                if !SupabaseConfig.isConfigured {
                    banner(AuthError.notConfigured.localizedDescription, color: .orange)
                }

                VStack(spacing: 12) {
                    field {
                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .email)
                            .submitLabel(.next)
                            .onSubmit { focus = .password }
                    }
                    field {
                        SecureField("Password (min 6 characters)", text: $password)
                            .textContentType(mode == .signIn ? .password : .newPassword)
                            .focused($focus, equals: .password)
                            .submitLabel(mode == .signIn ? .go : .next)
                            .onSubmit {
                                if mode == .signIn { submit() } else { focus = .confirm }
                            }
                    }
                    if mode == .signUp {
                        field {
                            SecureField("Confirm password", text: $confirm)
                                .textContentType(.newPassword)
                                .focused($focus, equals: .confirm)
                                .submitLabel(.go)
                                .onSubmit(submit)
                        }
                        if !confirm.isEmpty && confirm != password {
                            Text("Passwords don't match").font(.footnote).foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if let error { banner(error, color: .red) }
                if let info { banner(info, color: .green) }

                Button(action: submit) {
                    ZStack {
                        if busy { ProgressView().tint(.black) }
                        else { Text(mode == .signIn ? "Sign In" : "Create Account").fontWeight(.semibold) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(RoundedRectangle(cornerRadius: 14).fill(canSubmit ? Color.white : Color.white.opacity(0.35)))
                    .foregroundStyle(.black)
                }
                .disabled(!canSubmit)

                if mode == .signIn {
                    Button("Forgot password?", action: resetPassword)
                        .font(.footnote)
                        .disabled(busy)
                }

                Button {
                    withAnimation { mode = (mode == .signIn ? .signUp : .signIn) }
                    error = nil; info = nil; confirm = ""
                } label: {
                    Group {
                        if mode == .signIn {
                            Text("Don't have an account? **Sign up**")
                        } else {
                            Text("Already have an account? **Sign in**")
                        }
                    }
                    .font(.subheadline)
                }
                .disabled(busy)
            }
            .padding(.horizontal, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .foregroundStyle(.white)
        .tint(.white)
        .background(Color.black.ignoresSafeArea())
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.1)))
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.12)))
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        error = nil
        info = nil
        busy = true
        let email = trimmedEmail, password = password, mode = mode
        Task {
            defer { busy = false }
            do {
                if mode == .signIn {
                    try await auth.signIn(email: email, password: password)
                } else if try await auth.signUp(email: email, password: password) == .confirmEmail {
                    info = "Account created. Check \(email) for a confirmation link, then sign in."
                    self.mode = .signIn
                    self.password = ""
                    confirm = ""
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func resetPassword() {
        error = nil
        info = nil
        guard trimmedEmail.contains("@") else {
            error = "Enter your email above first."
            return
        }
        busy = true
        let email = trimmedEmail
        Task {
            defer { busy = false }
            do {
                try await auth.sendPasswordReset(email: email)
                info = "If an account exists for \(email), a reset link is on its way."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
