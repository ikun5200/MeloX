import SwiftUI
import UIKit

struct QQLoginView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case qq
        case wechat
        case phone

        var id: String { rawValue }

        var title: String {
            switch self {
            case .qq: L10n.string("ui.login.mode.qq")
            case .wechat: L10n.string("ui.login.mode.wechat")
            case .phone: L10n.string("ui.login.mode.phone")
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(NeteaseAPI.self) private var api

    @State private var service = QQLoginService()
    @State private var mode: Mode = .qq
    @State private var qrCode: QQLoginQRCode?
    @State private var qrImage: UIImage?
    @State private var qrState: QQLoginQRState = .waiting
    @State private var pollTask: Task<Void, Never>?
    @State private var isWorking = false
    @State private var errorMessage: String?

    @State private var phone = ""
    @State private var countryCode = "86"
    @State private var authCode = ""
    @State private var phoneCodeSent = false
    @State private var captchaURL: URL?
    @State private var showsCaptchaAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, _ in
                    resetQRCode()
                    Task { await loadQRCode() }
                }

                if mode == .phone {
                    phoneLoginContent
                } else {
                    qrLoginContent
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
            .navigationTitle("ui.login.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ui.common.cancel", role: .cancel) {
                        dismiss()
                    }
                }
            }
            .task {
                await loadQRCode()
            }
            .onDisappear {
                pollTask?.cancel()
            }
            .alert(
                "ui.login.phone.captcha",
                isPresented: $showsCaptchaAlert
            ) {
                if let captchaURL {
                    Link("ui.login.phone.open_captcha", destination: captchaURL)
                }
                Button("ui.common.ok", role: .cancel) {}
            } message: {
                Text("ui.login.phone.captcha.message")
            }
        }
    }

    private var qrLoginContent: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white)
                    .frame(width: 240, height: 240)

                if let qrImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 224, height: 224)
                } else if isWorking {
                    ProgressView()
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                }
            }

            Text(qrStatusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if qrState.isFinished {
                Button("ui.login.refresh") {
                    resetQRCode()
                    Task { await loadQRCode() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var phoneLoginContent: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("+86", text: $countryCode)
                    .keyboardType(.numberPad)
                    .frame(width: 64)
                    .textFieldStyle(.roundedBorder)

                TextField(
                    "ui.login.phone.placeholder",
                    text: $phone
                )
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .textFieldStyle(.roundedBorder)
            }

            Button("ui.login.phone.send") {
                Task { await sendAuthCode() }
            }
            .buttonStyle(.bordered)
            .disabled(phone.isEmpty || isWorking)

            if phoneCodeSent {
                TextField(
                    "ui.login.phone.code_placeholder",
                    text: $authCode
                )
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textFieldStyle(.roundedBorder)

                Button("ui.login.phone.submit") {
                    Task { await loginWithPhone() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(authCode.isEmpty || isWorking)

                Text("ui.login.phone.sent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isWorking {
                ProgressView("ui.login.working")
            }
        }
    }

    private var qrStatusText: String {
        switch qrState {
        case .waiting:
            mode == .qq
                ? L10n.string("ui.login.qr.waiting")
                : L10n.string("ui.login.qr.waiting_wechat")
        case .scanned:
            L10n.string("ui.login.qr.scanned")
        case .confirmed:
            L10n.string("ui.login.working")
        case .expired:
            L10n.string("ui.login.qr.expired")
        case .refused:
            L10n.string("ui.login.qr.refused")
        case .credential:
            L10n.string("ui.login.working")
        }
    }

    private func loadQRCode() async {
        guard mode != .phone else { return }
        pollTask?.cancel()
        resetQRCode()
        isWorking = true
        defer { isWorking = false }

        do {
            let code = mode == .qq
                ? try await service.fetchQQQRCode()
                : try await service.fetchWeChatQRCode()
            qrCode = code
            qrImage = UIImage(data: code.imageData)
            qrState = .waiting
            startPolling(code)
        } catch {
            errorMessage = error.localizedDescription
            if let qrCode {
                qrImage = UIImage(data: qrCode.imageData)
            }
        }
    }

    private func startPolling(_ code: QQLoginQRCode) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                do {
                    let state = mode == .qq
                        ? try await service.pollQQQRCode(code)
                        : try await service.pollWeChatQRCode(code)
                    qrState = state
                    switch state {
                    case .credential(let credential):
                        completeLogin(credential)
                        return
                    case .expired, .refused:
                        return
                    case .waiting, .scanned, .confirmed:
                        try? await Task.sleep(for: .seconds(2))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }
        }
    }

    private func resetQRCode() {
        pollTask?.cancel()
        pollTask = nil
        qrCode = nil
        qrImage = nil
        qrState = .waiting
        errorMessage = nil
    }

    private func sendAuthCode() async {
        guard !phone.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await service.sendPhoneAuthCode(
                phone: phone,
                countryCode: Int(countryCode) ?? 86
            )
            switch result.state {
            case .sent:
                phoneCodeSent = true
            case .captcha:
                captchaURL = result.securityURL.flatMap(URL.init(string:))
                showsCaptchaAlert = true
            case .frequency:
                errorMessage = L10n.string("ui.login.phone.frequency")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loginWithPhone() async {
        guard !phone.isEmpty, !authCode.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let credential = try await service.authorizePhone(
                phone: phone,
                code: authCode
            )
            completeLogin(credential)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func completeLogin(_ credential: QQCredential) {
        settings.saveQQCredential(credential)
        api.updateQQCredential(credential)
        dismiss()
    }
}

private extension QQLoginQRState {
    var isFinished: Bool {
        switch self {
        case .expired, .refused:
            true
        case .waiting, .scanned, .confirmed, .credential:
            false
        }
    }
}
