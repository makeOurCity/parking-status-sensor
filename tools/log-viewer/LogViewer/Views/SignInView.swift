import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var auth: CognitoAuthService
    @State private var username = AWSConfig.loginUsernameHint
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case username, password
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.accent.opacity(0.18), Color(.systemGroupedBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Theme.accent, Theme.accent.opacity(0.7)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 72, height: 72)
                                .shadow(color: Theme.accent.opacity(0.4), radius: 16, y: 8)
                            Image(systemName: "sensor.fill")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(.white)
                        }

                        VStack(spacing: 4) {
                            Text("駐車場センサ")
                                .font(.title2.weight(.bold))
                                .fontDesign(.rounded)
                            Text("ログビューア")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 40)

                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "envelope.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            TextField("ユーザー名（メール）", text: $username)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                .disableAutocorrection(true)
                                .focused($focusedField, equals: .username)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                        }
                        .modifier(FieldBackground())

                        HStack(spacing: 10) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            SecureField("パスワード", text: $password)
                                .focused($focusedField, equals: .password)
                                .submitLabel(.go)
                                .onSubmit(signIn)
                        }
                        .modifier(FieldBackground())

                        Text("初回のみサインインが必要です。以降はアプリがセッションを自動的に更新します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    .cardStyle()

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(Theme.full)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardStyle()
                    }

                    Button(action: signIn) {
                        HStack {
                            Spacer()
                            if isSigningIn {
                                ProgressView().tint(.white)
                            } else {
                                Text("サインイン")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accent.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .opacity(username.isEmpty || password.isEmpty ? 0.5 : 1)
                    }
                    .disabled(username.isEmpty || password.isEmpty || isSigningIn)
                }
                .padding(20)
            }
        }
    }

    private func signIn() {
        guard !username.isEmpty, !password.isEmpty, !isSigningIn else { return }
        focusedField = nil
        errorMessage = nil
        isSigningIn = true
        Task {
            do {
                try await auth.signIn(username: username, password: password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSigningIn = false
        }
    }
}

private struct FieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
