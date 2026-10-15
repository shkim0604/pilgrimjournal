import JournalData
import SwiftUI

struct AppLockView: View {
    @EnvironmentObject private var lock: AppLockCoordinator
    @State private var password = ""
    @State private var isPresentingReset = false

    var body: some View {
        ZStack {
            appBackground
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(JournalTheme.brandPrimary)
                Text("Pilgrim Journal 잠금")
                    .font(.title2.bold())
                    .foregroundStyle(JournalTheme.ink)
                SecureField("비밀번호", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit { submit() }
                    .frame(maxWidth: 320)
                if let retryAfter = lock.retryAfter, retryAfter > .now {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(retryText(until: retryAfter, now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = lock.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    if lock.configuration.allowsBiometrics {
                        Button {
                            Task { _ = await lock.unlockWithBiometrics() }
                        } label: {
                            Label("Face ID / Touch ID", systemImage: "faceid")
                        }
                    }
                    Button("잠금 해제") { submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(password.isEmpty || isRetrying)
                }
                Button("비밀번호를 잊으셨나요?") {
                    isPresentingReset = true
                }
                .font(.caption)
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $isPresentingReset) {
            AppLockResetView()
        }
    }

    private var isRetrying: Bool {
        lock.retryAfter.map { $0 > .now } ?? false
    }

    private var appBackground: Color {
        JournalTheme.canvas
    }

    private func submit() {
        guard !password.isEmpty, !isRetrying else { return }
        let candidate = password
        Task {
            if await lock.unlock(password: candidate) {
                password = ""
            }
        }
    }

    private func retryText(until: Date, now: Date) -> String {
        let seconds = max(0, Int(ceil(until.timeIntervalSince(now))))
        return String(localized: "\(seconds)초 후 다시 시도할 수 있습니다.")
    }
}

private struct AppLockResetView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var lock: AppLockCoordinator
    @State private var newPassword = ""
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("기기 암호 또는 생체 인증으로 소유자를 확인한 뒤 새 앱 비밀번호를 설정합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("새 비밀번호 (6자 이상)", text: $newPassword)
                        .textContentType(.newPassword)
                    SecureField("새 비밀번호 확인", text: $confirmation)
                        .textContentType(.newPassword)
                }
                if let error = lock.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("비밀번호 재설정")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("기기 인증 후 재설정") {
                        Task {
                            if await lock.resetPassword(
                                newPassword: newPassword,
                                confirmation: confirmation
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(newPassword.isEmpty || confirmation.isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            appBackground
                .ignoresSafeArea()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(JournalTheme.brandPrimary)
                .accessibilityLabel("Pilgrim Journal 잠김")
        }
    }

    private var appBackground: Color {
        JournalTheme.canvas
    }
}

struct AppLockSettingsView: View {
    @EnvironmentObject private var lock: AppLockCoordinator
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var timeout = AppLockTimeout.immediately
    @State private var allowsBiometrics = true
    @State private var successMessage: String?

    var body: some View {
        Form {
            Section("보호 범위") {
                Text("앱 잠금은 이 기기에서 일기 화면을 보호합니다. 데이터베이스와 CloudKit 기록을 비밀번호로 종단 간 암호화하지는 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if lock.configuration.isEnabled {
                enabledSettings
            } else {
                passwordFields(includeCurrent: false, includeOptions: true)
                Section {
                    Button("앱 잠금 켜기") {
                        Task {
                            if await lock.configure(
                                password: newPassword,
                                confirmation: confirmation,
                                timeout: timeout,
                                allowsBiometrics: allowsBiometrics
                            ) {
                                clearFields()
                                successMessage = String(localized: "앱 잠금을 켰습니다.")
                            }
                        }
                    }
                    .disabled(newPassword.isEmpty || confirmation.isEmpty)
                }
            }

            if let successMessage {
                Text(successMessage)
                    .foregroundStyle(.green)
            }
            if let error = lock.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("앱 잠금")
        .onAppear {
            timeout = lock.configuration.timeout
            allowsBiometrics = lock.configuration.allowsBiometrics
        }
    }

    @ViewBuilder
    private var enabledSettings: some View {
        Section("잠금 설정") {
            Picker("자동 잠금", selection: $timeout) {
                ForEach(AppLockTimeout.allCases) { value in
                    Text(value.localizedName).tag(value)
                }
            }
            Toggle("Face ID / Touch ID 사용", isOn: $allowsBiometrics)
            Button("설정 저장") {
                Task {
                    if await lock.updateConfiguration(
                        timeout: timeout,
                        allowsBiometrics: allowsBiometrics
                    ) {
                        successMessage = String(localized: "잠금 설정을 저장했습니다.")
                    }
                }
            }
            Button("지금 잠그기") { lock.lockNow() }
        }

        passwordFields(includeCurrent: true, includeOptions: false)

        Section("비밀번호 관리") {
            Button("비밀번호 변경") {
                Task {
                    if await lock.changePassword(
                        currentPassword: currentPassword,
                        newPassword: newPassword,
                        confirmation: confirmation
                    ) {
                        clearFields()
                        successMessage = String(localized: "비밀번호를 변경했습니다.")
                    }
                }
            }
            .disabled(currentPassword.isEmpty || newPassword.isEmpty || confirmation.isEmpty)

            Button("기기 인증 후 비밀번호 재설정") {
                Task {
                    if await lock.resetPassword(
                        newPassword: newPassword,
                        confirmation: confirmation
                    ) {
                        clearFields()
                        successMessage = String(localized: "비밀번호를 재설정했습니다.")
                    }
                }
            }
            .disabled(newPassword.isEmpty || confirmation.isEmpty)

            Button("앱 잠금 끄기", role: .destructive) {
                Task {
                    if await lock.disable(currentPassword: currentPassword) {
                        clearFields()
                        successMessage = String(localized: "앱 잠금을 껐습니다.")
                    }
                }
            }
            .disabled(currentPassword.isEmpty)
        }
    }

    @ViewBuilder
    private func passwordFields(
        includeCurrent: Bool,
        includeOptions: Bool
    ) -> some View {
        Section(includeCurrent ? "비밀번호 변경" : "새 비밀번호") {
            if includeCurrent {
                SecureField("현재 비밀번호", text: $currentPassword)
                    .textContentType(.password)
            }
            SecureField("새 비밀번호 (6자 이상)", text: $newPassword)
                .textContentType(.newPassword)
            SecureField("새 비밀번호 확인", text: $confirmation)
                .textContentType(.newPassword)
            if includeOptions {
                Picker("자동 잠금", selection: $timeout) {
                    ForEach(AppLockTimeout.allCases) { value in
                        Text(value.localizedName).tag(value)
                    }
                }
                Toggle("Face ID / Touch ID 사용", isOn: $allowsBiometrics)
            }
        }
    }

    private func clearFields() {
        currentPassword = ""
        newPassword = ""
        confirmation = ""
    }
}
