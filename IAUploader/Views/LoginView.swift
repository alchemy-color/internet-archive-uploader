import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model

    @State private var email = ""
    @State private var password = ""
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var showS3Fields = false
    @State private var hasLoadedDefaults = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if model.accountState == .signedIn {
                    signedInContent
                } else {
                    signedOutContent
                }
            }
            .frame(maxWidth: 470)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 36)
        }
        .task {
            guard !hasLoadedDefaults else { return }
            hasLoadedDefaults = true
            if email.isEmpty { email = model.lastEmail }
        }
    }

    // MARK: Signed out

    private var signedOutContent: some View {
        VStack(spacing: 22) {
            BrandMark()
                .padding(.top, 18)

            VStack(spacing: 6) {
                Text("Sign in to the Internet Archive")
                    .font(.title2.weight(.semibold))
                Text("Your uploads are stored in your archive.org account. Your password is never saved on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Email")
                        TextField("you@example.com", text: $email)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.emailAddress)
                            .onSubmit(signIn)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Password")
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(signIn)
                    }

                    if let loginError = model.loginError {
                        InfoBanner(kind: .error, message: loginError)
                    }

                    Button(action: signIn) {
                        HStack(spacing: 8) {
                            if model.accountState == .signingIn {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(model.accountState == .signingIn ? "Signing In…" : "Sign In")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.accountState == .signingIn || email.isEmpty || password.isEmpty)

                    HStack {
                        Button("Create a free account") {
                            if let url = URL(string: "https://archive.org/account/login.createaccount.php") {
                                FilePicker.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                        Spacer()
                        Button("Forgot password?") {
                            if let url = URL(string: "https://archive.org/account/login") {
                                FilePicker.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }

                    Divider()

                    DisclosureGroup(isExpanded: $showS3Fields) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Use an access key and secret key from archive.org/account/s3.php. This skips the email and password sign-in.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            TextField("Access key", text: $accessKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            SecureField("Secret key", text: $secretKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))

                            HStack {
                                Button("Get S3 keys") {
                                    if let url = URL(string: "https://archive.org/account/s3.php") {
                                        FilePicker.open(url)
                                    }
                                }
                                .buttonStyle(.link)
                                .font(.callout)
                                Spacer()
                                Button("Save Keys") {
                                    model.signInWithKeys(accessKey: accessKey, secretKey: secretKey)
                                }
                                .buttonStyle(.bordered)
                                .disabled(accessKey.trimmingCharacters(in: .whitespaces).isEmpty || secretKey.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Use S3 API keys instead")
                            .font(.callout)
                    }
                }
            }

            Text("Credentials are saved in a user-only file under ~/.config/IAUploader. The app talks directly to archive.org and no third-party servers.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
        }
    }

    // MARK: Signed in

    private var signedInContent: some View {
        VStack(spacing: 20) {
            BrandMark()
                .padding(.top, 18)

            VStack(spacing: 6) {
                Text("You're signed in")
                    .font(.title2.weight(.semibold))
                Text("Ready to upload to the Internet Archive.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let credentials = model.credentials {
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.accentColor.opacity(0.15))
                                .frame(width: 46, height: 46)
                                .overlay(
                                    Image(systemName: credentials.isS3Only ? "key.fill" : "person.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(Color.accentColor)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(credentials.displayName)
                                    .font(.headline)
                                Text(credentials.isS3Only ? "Signed in with S3 keys" : "Signed in to archive.org")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusPill(text: "Connected", color: .green, systemImage: "checkmark")
                        }

                        Divider()

                        HStack(spacing: 12) {
                            Button("New Item") {
                                model.startNewItem()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                            Button("Sign Out") {
                                model.signOut()
                                password = ""
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Spacer()
                        }

                        Text("Uploading makes your files publicly available on archive.org. Only upload content you have the rights to share.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !model.history.records.isEmpty {
                Card("Recent uploads", systemImage: "clock.arrow.circlepath") {
                    VStack(spacing: 0) {
                        ForEach(model.history.records.prefix(3)) { record in
                            Button {
                                if let url = record.itemURL { FilePicker.open(url) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "archivebox")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(record.title.isEmpty ? record.identifier : record.title)
                                            .font(.callout)
                                            .lineLimit(1)
                                        Text(record.identifier)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if record.id != model.history.records.prefix(3).last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func signIn() {
        Task {
            await model.signIn(email: email, password: password)
            if model.accountState == .signedIn {
                password = ""
            }
        }
    }
}

struct BrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.38, blue: 0.68), Color(red: 0.06, green: 0.20, blue: 0.42)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(.white.opacity(0.16))
                )
            Image(systemName: "building.columns.fill")
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        .accessibilityHidden(true)
    }
}
