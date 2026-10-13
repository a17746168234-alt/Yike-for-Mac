import SwiftUI
import Foundation

struct TrialAccount: Codable {
    let username: String
    let email: String?
    let granted: Int
    let used: Int
    let remaining: Int
    let profileName: String?
    let avatarData: String?
    enum CodingKeys: String, CodingKey { case username, email, granted, used, remaining, profileName = "profile_name", avatarData = "avatar_data" }
}
struct TrialConfiguration: Decodable {
    let enabled: Bool
    let gift: Int
    let message: String
    let pool_limit: Int
    let pool_remaining: Int
}
private struct TrialHTTPFailure: Decodable { let code: String; let message: String }

struct TrialServiceError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class SharedTrialAccount: ObservableObject {
    static let shared = SharedTrialAccount()
    @Published private(set) var account: TrialAccount?
    @Published private(set) var configuration: TrialConfiguration?
    @Published private(set) var busy = false
    @Published var feedback = ""
    @Published var feedbackIsError = false
    private var token = ""
    private var authRevision = UUID()
    private var didRestoreSession = false
    private let secretStore = SecretTextStore(service: SecureKeyStore.applicationID + ".yike-account", account: "session", fileName: "account-session")
    private var pendingRequests: [Data: String] = [:]
    var isSignedIn: Bool { !token.isEmpty }
    var baseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "YikeTrialAPIBaseURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    func restoreSessionAfterLaunch() {
        guard !didRestoreSession else { return }
        didRestoreSession = true
        token = (try? secretStore.load()) ?? ""
        objectWillChange.send()
        authRevision = UUID()
        if isSignedIn { Task { await refresh() } }
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, authenticated: Bool = true) async throws -> T {
        guard let baseURL else { throw TrialServiceError(code: "not_configured", message: "此版本尚未配置公共体验服务，请更新 Yike。") }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 50
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else {
                let failure = try? JSONDecoder().decode(TrialHTTPFailure.self, from: data)
                throw TrialServiceError(code: failure?.code ?? "http_\(http.statusCode)", message: failure?.message ?? "公共体验服务暂不可用（\(http.statusCode)），请稍后重试。")
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as URLError where error.code != .cancelled {
            throw TrialServiceError(code: "network", message: "无法连接 Yike 公共体验服务，请检查网络后重试。Apple 翻译和自填密钥不受影响。")
        }
    }

    func refresh() async {
        let revision = authRevision
        do {
            let config: TrialConfiguration = try await request("v1/config", authenticated: false)
            guard revision == authRevision else { return }
            configuration = config
            if isSignedIn {
                struct Response: Decodable { let account: TrialAccount }
                let response: Response = try await request("v1/me")
                guard revision == authRevision else { return }
                account = response.account
                await synchronizeProfile(response.account)
            }
        } catch {
            guard revision == authRevision else { return }
            if (error as? TrialServiceError)?.code == "login_required" { clearSession() }
            feedback = error.localizedDescription; feedbackIsError = true
        }
    }

    private struct AuthResponse: Decodable { let token: String; let account: TrialAccount; let message: String }
    struct EmailChallenge: Decodable { let challenge_id: String; let message: String }
    private func accept(_ response: AuthResponse) throws {
        try secretStore.save(response.token)
        authRevision = UUID(); token = response.token; account = response.account; pendingRequests.removeAll()
        feedback = response.message; feedbackIsError = false
        Task { await synchronizeProfile(response.account) }
    }

    private func synchronizeProfile(_ remote: TrialAccount) async {
        guard let email = remote.email else { return }
        if remote.profileName == nil, let localName = UserProfile.shared.cachedName(email), UserProfile.valid(localName) {
            try? await saveProfile(email: email, name: localName, image: UserProfile.shared.uploadAvatar(email))
        } else {
            UserProfile.shared.applyServerProfile(email: email, name: remote.profileName, avatarData: remote.avatarData)
        }
    }

    func saveProfile(email: String, name: String, image: Data?) async throws {
        guard isSignedIn, account?.email == email else { throw TrialServiceError(code: "login_required", message: "请先登录对应的 Yike 账号。") }
        let encoded = image?.base64EncodedString()
        guard (encoded?.count ?? 0) <= 28_000 else { throw TrialServiceError(code: "avatar", message: "头像过大，请重新选择图片。") }
        struct Response: Decodable { let account: TrialAccount; let message: String }
        let response: Response = try await request("v1/profile", method: "POST", body: ["profile_name": name, "avatar_data": encoded ?? NSNull()])
        account = response.account
        feedback = response.message; feedbackIsError = false
    }
    func signIn(email: String, password: String) async {
        guard !busy else { return }
        busy = true; feedback = ""; defer { busy = false }
        do {
            let response: AuthResponse = try await request("v2/login", method: "POST", body: ["email":email,"password":password], authenticated: false)
            try accept(response)
        } catch { feedback = error.localizedDescription; feedbackIsError = true }
    }
    func sendCode(email: String, password: String, purpose: String) async -> String? {
        guard !busy else { return nil }
        busy = true; feedback = ""; defer { busy = false }
        do {
            let response: EmailChallenge = try await request("v2/\(purpose)/send", method: "POST", body: ["email":email,"password":password], authenticated: purpose == "bind")
            feedback = response.message; feedbackIsError = false
            return response.challenge_id
        } catch { feedback = error.localizedDescription; feedbackIsError = true; return nil }
    }
    func verify(email: String, code: String, challenge: String, purpose: String, password: String) async -> Bool {
        guard !busy else { return false }
        busy = true; feedback = ""; defer { busy = false }
        do {
            let body: [String:Any] = ["email":email,"code":code,"challenge_id":challenge,"new_password":password]
            if purpose == "reset" {
                struct Response: Decodable { let message: String }
                let response: Response = try await request("v2/reset/verify", method: "POST", body: body, authenticated: false)
                feedback = response.message; feedbackIsError = false
            } else {
                let response: AuthResponse = try await request("v2/\(purpose)/verify", method: "POST", body: body, authenticated: purpose == "bind")
                try accept(response)
            }
            return true
        } catch { feedback = error.localizedDescription; feedbackIsError = true; return false }
    }

    private func clearSession() {
        authRevision = UUID(); token = ""; account = nil; pendingRequests.removeAll()
        try? secretStore.delete()
    }
    func logout() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        struct Response: Decodable { let message: String }
        do {
            let _: Response = try await request("v1/logout", method: "POST", body: [:])
            clearSession(); feedback = "已退出登录。"; feedbackIsError = false
        } catch { feedback = "暂时无法撤销服务器会话，请联网后重试退出。"; feedbackIsError = true }
    }
    func changePassword(old: String, new: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            struct Response: Decodable { let message: String }
            let response: Response = try await request("v1/password", method: "POST", body: ["old_password":old,"new_password":new])
            clearSession(); feedback = response.message; feedbackIsError = false
        } catch { feedback = error.localizedDescription; feedbackIsError = true }
    }
    func translate(_ texts: [String], source: String, target: String) async throws -> [String] {
        guard isSignedIn else { throw TrialServiceError(code: "login_required", message: "请在设置的“账号与安全”中注册或登录，领取公共 DeepL 体验额度。") }
        let revision = authRevision
        let content: [String: Any] = ["text":texts,"source":source,"target":target]
        let fingerprint = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        let id = pendingRequests[fingerprint] ?? UUID().uuidString
        pendingRequests[fingerprint] = id
        var body = content; body["request_id"] = id
        struct Response: Decodable { let translations: [String]; let account: TrialAccount }
        do {
            let result: Response = try await SharedQuotaRetry.run {
                try Task.checkCancellation()
                guard revision == self.authRevision else { throw CancellationError() }
                return try await self.request("v1/translate", method: "POST", body: body)
            }
            try Task.checkCancellation()
            guard revision == authRevision else { throw CancellationError() }
            account = result.account
            guard result.translations.count == texts.count else { throw TranslationFailure.invalidResponse }
            pendingRequests.removeValue(forKey: fingerprint)
            return result.translations
        } catch {
            // An explicit rejection may safely use a new request ID next time. Network
            // failures retain the ID so retries cannot double-charge the same request.
            if revision == authRevision, let failure = error as? TrialServiceError, failure.code != "network" {
                pendingRequests.removeValue(forKey: fingerprint)
            }
            throw error
        }
    }
}

struct TrialAccountSettings: View {
    @ObservedObject private var account = SharedTrialAccount.shared
    @ObservedObject var model: TranslatorViewModel
    @State private var mode = "login"
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var code = ""
    @State private var challenge = ""
    @State private var resendAfter = Date.distantPast
    @State private var privacy = false
    private var bindingEmail: Bool { account.isSignedIn && account.account?.email == nil }
    private var purpose: String { bindingEmail ? "bind" : (mode == "forgot" ? "reset" : "register") }
    private var verified: Bool { account.account?.email != nil }
    private var validEmail: Bool { email.contains("@") && email.contains(".") }
    private func changeMode(_ value: String) {
        mode = value; challenge = ""; code = ""; password = ""; confirmation = ""
        account.feedback = ""
    }
    private func accountTab(_ label: String, value: String) -> some View {
        Button { changeMode(value) } label: {
            Text(label).font(.system(size: 18, weight: mode == value ? .semibold : .regular))
                .foregroundStyle(mode == value ? Color.primary : Color.secondary)
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    if mode == value { Capsule().fill(Color.accentColor).frame(height: 2) }
                }
        }.buttonStyle(.plain).accessibilityAddTraits(mode == value ? .isSelected : [])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if verified, let current = account.account {
                Label(current.email ?? current.username, systemImage: "person.crop.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                QuotaUsageView(title: "体验额度", used: current.used, total: current.granted)
                HStack {
                    Button("刷新余额") { Task { await account.refresh() } }
                    Button("重设密码") { Task { await account.logout(); changeMode("forgot") } }
                    Button("退出登录") {
                        Task { await account.logout(); if !account.isSignedIn && model.selectedEngine == .sharedDeepL { model.setEngine(.apple) } }
                    }
                }
            } else {
                if bindingEmail {
                    Text("验证邮箱").font(.system(size: 20, weight: .semibold))
                    Text("验证后可使用邮箱登录，原账号额度补齐至 20 万字符。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else if mode == "forgot" {
                    Text("找回密码").font(.system(size: 20, weight: .semibold))
                } else {
                    HStack(spacing: 24) {
                        accountTab("登录", value: "login")
                        accountTab("注册", value: "register")
                        Spacer()
                    }.padding(.bottom, 4)
                }
                AccountFormInput(title: "邮箱", hint: "请输入邮箱地址", symbol: "envelope", text: $email)
                    .disabled(!challenge.isEmpty)
                if challenge.isEmpty && !bindingEmail && mode != "forgot" {
                    AccountFormInput(title: "密码", hint: "至少 10 位", symbol: "key", text: $password, secure: true)
                    if mode == "register" { AccountFormInput(title: "确认密码", hint: "再次输入密码", symbol: "lock", text: $confirmation, secure: true) }
                }
                if !challenge.isEmpty {
                    AccountFormInput(title: "邮箱验证码", hint: "请输入 6 位验证码", symbol: "number.square", text: $code)
                    if purpose == "reset" {
                        AccountFormInput(title: "新密码", hint: "至少 10 位", symbol: "key", text: $password, secure: true)
                        AccountFormInput(title: "确认新密码", hint: "再次输入新密码", symbol: "lock", text: $confirmation, secure: true)
                    }
                    Button(purpose == "reset" ? "重设密码" : "验证并登录") {
                        Task {
                            if await account.verify(email: email, code: code, challenge: challenge, purpose: purpose, password: password) {
                                challenge = ""; password = ""; confirmation = ""; code = ""; mode = "login"
                            }
                        }
                    }.buttonStyle(AccountPrimaryButton())
                        .disabled(code.count != 6 || (purpose == "reset" && (password.count < 10 || password != confirmation)))
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let seconds = max(0, Int(ceil(resendAfter.timeIntervalSince(timeline.date))))
                        Button(seconds > 0 ? "\(seconds) 秒后可重发" : "重新发送验证码") { challenge = ""; code = "" }
                            .disabled(seconds > 0)
                    }
                } else {
                    if mode == "login" && !bindingEmail {
                        HStack {
                            Spacer()
                            Button("忘记密码？") { changeMode("forgot") }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color(red: 0.86, green: 0.31, blue: 0.34))
                        }
                    }
                    Button(mode == "login" && !bindingEmail ? "登录" : "发送邮箱验证码") {
                        Task {
                            if mode == "login" && !bindingEmail { await account.signIn(email: email, password: password) }
                            else if let id = await account.sendCode(email: email, password: password, purpose: purpose) {
                                challenge = id; resendAfter = Date().addingTimeInterval(60); password = ""; confirmation = ""
                            }
                        }
                    }.buttonStyle(AccountPrimaryButton())
                        .disabled(!validEmail || (!bindingEmail && mode != "forgot" && password.count < 10) || (mode == "register" && password != confirmation))
                }
                HStack {
                    if !bindingEmail && mode == "forgot" {
                        Button("返回登录") { changeMode("login") }.foregroundStyle(Color.accentColor)
                    } else if bindingEmail { Button("退出账号") { Task { await account.logout() } } }
                    Spacer()
                    Button("隐私说明") { privacy = true }
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                Text("邮箱验证注册，赠送 20 万字符翻译额度。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if account.busy { ProgressView().controlSize(.small) }
            if !account.feedback.isEmpty {
                Label(account.feedback, systemImage: account.feedbackIsError ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(account.feedbackIsError ? Color.orange : Color.green)
            }
        }
        .padding(24).frame(maxWidth: 520, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.05), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .center)
        .textFieldStyle(.roundedBorder).controlSize(.large)
        .buttonStyle(.bordered).disabled(account.busy)
        .task { await account.refresh() }
        .popover(isPresented: $privacy) {
            Text("邮箱仅用于账号验证与安全通知。DeepL 高质量翻译将文字经 Yike 服务器发送至 DeepL；服务器保存账号和额度记录，译文短时缓存用于防止重复扣额。赠送额度仅领取一次，受服务可用余额限制。")
                .font(.system(size: 12)).padding(20).frame(width: 320)
        }
    }
}
