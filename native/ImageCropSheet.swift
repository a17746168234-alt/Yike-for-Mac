import SwiftUI
import AppKit
import ImageIO

struct ImageCropSheet: View {
    let item: ImageCropItem
    let cancel: () -> Void
    let confirm: (CGRect?) -> Void
    @State private var selection: CGRect?
    private var size: CGSize { CGSize(width: item.image.width, height: item.image.height) }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("裁剪翻译区域").font(.title2.bold())
                    Text("拖动框选要翻译的内容，减少无关文字。也可以直接使用整张图片。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            GeometryReader { geometry in
                let fitted = aspectFitRect(imageSize: size, in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.08)
                    Image(nsImage: NSImage(cgImage: item.image, size: size))
                        .resizable().frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                    if let selection {
                        Rectangle().fill(Color.accentColor.opacity(0.12))
                            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                            .frame(width: selection.width * fitted.width, height: selection.height * fitted.height)
                            .position(x: fitted.minX + selection.midX * fitted.width, y: fitted.minY + selection.midY * fitted.height)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                    guard let proposed = ImageCropGeometry.selection(from: value.startLocation, to: value.location, imageRect: fitted) else { return }
                    selection = proposed
                })
            }
            HStack {
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("重新框选") { selection = nil }.disabled(selection == nil)
                Spacer()
                Button("使用整张图片") { confirm(nil) }
                Button("裁剪并识别") {
                    guard let selection else { return }
                    confirm(selection)
                }
                .buttonStyle(.borderedProminent)
                .disabled((selection?.width ?? 0) * item.pixelSize.width < 8 || (selection?.height ?? 0) * item.pixelSize.height < 8)
            }.buttonStyle(.bordered)
        }.padding(24).frame(width: 780, height: 600)
    }
}
