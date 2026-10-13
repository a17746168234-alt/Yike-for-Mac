import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

@MainActor final class UserProfile: ObservableObject {
    static let shared = UserProfile()
    @Published var revision = 0
    private func key(_ email: String) -> String {
        "yike.profile." + SHA256.hash(data: Data(email.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func name(_ email: String) -> String { UserDefaults.standard.string(forKey: key(email) + ".name") ?? "Yike 用户" }
    func avatar(_ email: String) -> NSImage? {
        guard let data = UserDefaults.standard.data(forKey: key(email) + ".avatar") else { return nil }
        return NSImage(data: data)
    }
    static func valid(_ name: String) -> Bool {
        let chars = Array(name.unicodeScalars)
        return !chars.isEmpty && chars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) || (0x3400...0x9FFF).contains($0.value) } && chars.reduce(0) { $0 + ($1.isASCII ? 1 : 2) } <= 12
    }
    func cachedName(_ email: String) -> String? { UserDefaults.standard.string(forKey: key(email) + ".name") }
    func cachedAvatar(_ email: String) -> Data? { UserDefaults.standard.data(forKey: key(email) + ".avatar") }
    func uploadAvatar(_ email: String) -> Data? {
        guard let source = cachedAvatar(email), let image = NSImage(data: source) else { return nil }
        let side = min(image.size.width, image.size.height)
        let target = NSImage(size: NSSize(width: 128, height: 128))
        target.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128), from: NSRect(x: (image.size.width-side)/2, y: (image.size.height-side)/2, width: side, height: side), operation: .copy, fraction: 1)
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }
    func save(_ email: String, name: String, image: Data?) {
        UserDefaults.standard.set(name, forKey: key(email) + ".name")
        UserDefaults.standard.set(image, forKey: key(email) + ".avatar")
        revision += 1
    }
    func applyServerProfile(email: String?, name: String?, avatarData: String?) {
        guard let email else { return }
        if let name, Self.valid(name) { UserDefaults.standard.set(name, forKey: key(email) + ".name") }
        if name != nil {
            if let avatarData, let data = Data(base64Encoded: avatarData) { UserDefaults.standard.set(data, forKey: key(email) + ".avatar") }
            else { UserDefaults.standard.removeObject(forKey: key(email) + ".avatar") }
        }
        revision += 1
    }
}

struct ProfileAvatar: View {
    @ObservedObject private var profile = UserProfile.shared
    let email: String?
    let size: CGFloat
    var body: some View {
        Group {
            if let email, let image = profile.avatar(email) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }.frame(width: size, height: size).clipShape(Circle())
    }
}

struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    let email: String
    @State private var name = ""
    @State private var avatar: Data?
    @State private var message = ""
    @State private var saving = false
    var body: some View {
        VStack(spacing: 18) {
            Text("编辑个人资料").font(.title3.bold())
            Button(action: chooseImage) {
                Group {
                    if let avatar, let image = NSImage(data: avatar) { Image(nsImage: image).resizable().scaledToFill() }
                    else { Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary) }
                }.frame(width: 72, height: 72).clipShape(Circle())
            }.buttonStyle(.plain).help("选择头像")
            HStack { Button("更换头像", action: chooseImage); Button("恢复默认") { avatar = nil } }
            TextField("用户名", text: $name).textFieldStyle(.roundedBorder)
            Text("最多 6 个中文或 12 个英文字母，可混合输入。")
                .font(.caption).foregroundStyle(.secondary)
            Text("资料会同步保存到服务器，并在本机缓存。") .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    saving = true
                    Task {
                        do {
                            try await SharedTrialAccount.shared.saveProfile(email: email, name: name, image: avatar)
                            UserProfile.shared.save(email, name: name, image: avatar)
                            dismiss()
                        } catch { message = error.localizedDescription }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(!UserProfile.valid(name) || saving)
            }
        }.padding(26).frame(width: 350)
        .onAppear {
            name = UserProfile.shared.name(email)
            if !UserProfile.valid(name) { name = "Yike用户" }
            avatar = UserProfile.shared.cachedAvatar(email)
        }
    }
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { message = "无法读取图片，请选择其他图片。"; return }
        let side = min(image.size.width, image.size.height)
        let result = NSImage(size: NSSize(width: 128, height: 128))
        result.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128), from: NSRect(x: (image.size.width-side)/2, y: (image.size.height-side)/2, width: side, height: side), operation: .copy, fraction: 1)
        result.unlockFocus()
        guard let tiff = result.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]), data.count <= 20_000 else { message = "头像处理失败或图片过大，请重试。"; return }
        avatar = data; message = ""
    }
}

struct TranslationEngineMark: View {
    let engine: TranslationEngine
    var body: some View {
        Group {
            if engine == .apple { Image(systemName: "desktopcomputer").resizable().scaledToFit() }
            else if engine == .sharedDeepL { Image(nsImage: MenuBarIcon.make()).renderingMode(.template).resizable().scaledToFit() }
            else {
                Canvas { context, size in
                    var hex = Path()
                    let points: [CGPoint] = [.init(x: 0.5,y: 0),.init(x: 0.9,y: 0.23),.init(x: 0.9,y: 0.7),.init(x: 0.6,y: 0.86),.init(x: 0.6,y: 1),.init(x: 0.1,y: 0.7),.init(x: 0.1,y: 0.23)]
                    hex.addLines(points.map { CGPoint(x: $0.x*size.width,y: $0.y*size.height) }); hex.closeSubpath()
                    context.fill(hex, with: .foreground)
                    context.blendMode = .destinationOut
                    let a = CGPoint(x: size.width*0.38,y: size.height*0.32), b = CGPoint(x: size.width*0.65,y: size.height*0.48), c = CGPoint(x: size.width*0.38,y: size.height*0.65)
                    var links = Path(); links.move(to: a); links.addLine(to: b); links.addLine(to: c)
                    context.stroke(links, with: .color(.white), lineWidth: 1)
                    for p in [a,b,c] { context.fill(Path(ellipseIn: CGRect(x:p.x-1.6,y:p.y-1.6,width:3.2,height:3.2)), with: .color(.white)) }
                }.compositingGroup()
            }
        }.frame(width: 14, height: 14).accessibilityHidden(true)
    }
}
