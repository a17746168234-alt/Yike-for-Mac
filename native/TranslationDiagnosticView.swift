import SwiftUI

struct TranslationDiagnosticView: View {
    let diagnostic: TranslationDiagnostic

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(diagnostic.title, systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text("原因").fontWeight(.semibold)
                Text(diagnostic.reason).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("解决方法").fontWeight(.semibold)
                Text(diagnostic.recovery).foregroundStyle(.secondary)
            }
            if let detail = diagnostic.technicalDetail {
                Text("错误代码：\(detail)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
