import SwiftUI

/// Keep the dedicated authentication form proportional in its own dialog.
struct AccountFormScale: ViewModifier {
    @State private var contentHeight: CGFloat = 560
    private let scale: CGFloat = 0.86
    func body(content: Content) -> some View {
        content
            .frame(width: 520)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { contentHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { contentHeight = $0 }
            })
            .scaleEffect(scale, anchor: .top)
            .frame(width: 520 * scale, height: contentHeight * scale, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

struct AccountSecuritySummary: View {
    @ObservedObject private var account = SharedTrialAccount.shared
    @ObservedObject var model: TranslatorViewModel
    @State private var showAuthentication = false
    @State private var showProfile = false
    @ObservedObject private var profile = UserProfile.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Button { if account.account?.email != nil { showProfile = true } else { showAuthentication = true } } label: {
                    HStack(spacing: 14) {
                        ProfileAvatar(email: account.account?.email, size: 44)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(account.account?.email.map { profile.name($0) } ?? "未登录")
                                .font(.system(size: 15, weight: .semibold))
                            if let email = account.account?.email {
                                Text(email).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help("编辑头像与用户名")
                Spacer(minLength: 12)
                Button(account.isSignedIn ? "管理账号" : "登录") { showAuthentication = true }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
            }
            if account.account?.email != nil {
                Button("编辑头像与用户名") { showProfile = true }.font(.system(size: 12))
            }
            if let current = account.account {
                Divider()
                QuotaUsageView(title: "赠送额度", used: current.used, total: current.granted)
            }
            if account.feedbackIsError && !account.feedback.isEmpty {
                HStack {
                    Text(account.feedback).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("重试") { Task { await account.refresh() } }
                }
            }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .task { await account.refresh() }
        .sheet(isPresented: $showProfile) {
            if let email = account.account?.email { ProfileEditor(email: email) }
        }
        .sheet(isPresented: $showAuthentication) { AccountAuthenticationSheet(model: model) }
    }
}

struct AccountAuthenticationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var account = SharedTrialAccount.shared
    @ObservedObject var model: TranslatorViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Yike 账号", systemImage: "person.crop.circle")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 24).padding(.vertical, 20)
            Divider()
            ScrollView {
                TrialAccountSettings(model: model)
                    .modifier(AccountFormScale())
                    .padding(.horizontal, 20).padding(.vertical, 18)
            }
        }
        .frame(width: 520, height: 540)
        .background { AdaptiveGlassBackdrop(materialOpacity: 0.92, tintOpacity: 0.16).ignoresSafeArea() }
        .onChange(of: account.account?.email) { email in
            if email != nil { dismiss() }
        }
    }
}

struct QuotaUsageView: View {
    let title: String
    let used: Int
    let total: Int
    private var fraction: Double { min(1, max(0, Double(used) / Double(max(1, total)))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Text("\(max(0, used).formatted()) / \(max(0, total).formatted()) 字符")
                    .foregroundStyle(.secondary).monospacedDigit()
            }.font(.system(size: 11))
            HStack(spacing: 12) {
                ProgressView(value: fraction).tint(fraction >= 0.9 ? .red : .accentColor)
                Text("已用 \((fraction * 100).formatted(.number.precision(.fractionLength(1))))%")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
        }.accessibilityElement(children: .combine)
    }
}

struct AccountFormInput: View {
    let title: String
    let hint: String
    let symbol: String
    @Binding var text: String
    var secure = false
    @State private var revealed = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Color.accentColor.opacity(0.65)).frame(width: 21)
                Group {
                    if secure && !revealed { SecureField(hint, text: $text) }
                    else { TextField(hint, text: $text) }
                }.textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
                    .accessibilityLabel(title)
                if !text.isEmpty {
                    Button { text = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).accessibilityLabel("清空" + title)
                }
                if secure {
                    Button { revealed.toggle(); focused = true } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye").font(.system(size: 15)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).accessibilityLabel(revealed ? "隐藏密码" : "显示密码")
                }
            }.padding(.horizontal, 15).frame(height: 46)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(focused ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.10), lineWidth: 1))
                .shadow(color: focused ? Color.accentColor.opacity(0.08) : .clear, radius: 3)
        }
    }
}

struct AccountPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.label
            Image(systemName: "arrow.right").font(.system(size: 15, weight: .medium))
        }.font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(LinearGradient(colors: [Color(red: 0.25, green: 0.39, blue: 0.87), Color(red: 0.20, green: 0.31, blue: 0.72)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 11))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.40)
    }
}
