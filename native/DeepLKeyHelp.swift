import SwiftUI

struct DeepLKeyHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            step("1", title: "注册并申请 API Free") {
                Text("打开官方申请页，选择 API Free，按提示注册或登录。网页翻译账号或普通 DeepL Pro 订阅不等于 API 套餐。")
                addressLink("注册 / 申请 API Free", address: "https://www.deepl.com/pro-api", symbol: "person.badge.plus")
            }
            Divider()
            step("2", title: "登录并获取密钥") {
                Text("进入账号的 API Keys 页面，创建或复制完整密钥。API Free 密钥通常以 :fx 结尾，请一并复制。")
                addressLink("登录账号 / 打开我的密钥", address: "https://www.deepl.com/your-account/keys", symbol: "key.horizontal")
            }
            Divider()
            step("3", title: "回到 Yike 填写") {
                Text("在密钥输入框中粘贴，点击“保存并使用 DeepL”。密钥保存在本机系统钥匙串中，分享安装包时无需附带。")
            }
            Divider()
            addressLink("官方密钥说明与常见问题", address: "https://developers.deepl.com/docs/getting-started/auth", symbol: "questionmark.circle")
            Text("找不到密钥？确认已开通 API Free。本应用使用 Free 接口，每月免费 50 万字符。地区、注册验证及套餐条件以官网为准，申请时请确认选择免费方案。")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func step<Content: View>(_ number: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .frame(width: 25, height: 25)
                .background(Color.accentColor.opacity(0.1), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 13, weight: .semibold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addressLink(_ title: String, address: String, symbol: String) -> some View {
        Link(destination: URL(string: address)!) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(address).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help(address)
        .accessibilityLabel(title + "，在浏览器打开")
    }
}
