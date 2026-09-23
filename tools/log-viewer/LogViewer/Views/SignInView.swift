import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var auth: CognitoAuthService
    @State private var username = AWSConfig.loginUsernameHint
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ユーザー名（メール）", text: $username)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .disableAutocorrection(true)
                    SecureField("パスワード", text: $password)
                        .onSubmit(signIn)
                } footer: {
                    Text("初回のみサインインが必要です。以降はアプリがセッションを自動的に更新します。")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: signIn) {
                        if isSigningIn {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("サインイン")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isSigningIn)
                }
            }
            .navigationTitle("駐車場センサ ログビューア")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func signIn() {
        guard !username.isEmpty, !password.isEmpty, !isSigningIn else { return }
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
