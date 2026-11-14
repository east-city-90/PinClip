import SwiftUI
import AppKit

/// Liquid Glass 表面：macOS 26+ 用系统液态玻璃材质，旧系统回退 NSVisualEffectView 毛玻璃
extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(in: shape)
        } else {
            self
                .background(GlassBackground.layered())
                .clipShape(shape)
        }
    }
}

/// magpie 毛玻璃底：NSVisualEffectView（behindWindow 模糊）+ 半透明灰阶底
/// 对应设计令牌 backdrop-filter: blur(20px) saturate(180%) + rgba 半透明
struct GlassBackground: NSViewRepresentable {
    var tintOpacity: Double = 0.25

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// (effectView, tint) 由调用方 ZStack 叠加
    static func layered(tintOpacity: Double = 0.25) -> some View {
        ZStack {
            GlassBackground(tintOpacity: tintOpacity)
            Color(nsColor: .windowBackgroundColor).opacity(tintOpacity)
        }
    }
}

/// magpie 靛蓝胶囊分段控件（全部/文本/图片/文件）——选中态靛蓝底白字
struct MagpieSegmented: View {
    let options: [HistoryFilter]
    let binding: Binding<HistoryFilter>

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { opt in
                let selected = binding.wrappedValue == opt
                Button {
                    binding.wrappedValue = opt
                } label: {
                    Text(opt.label)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.white : Color(nsColor: .secondaryLabelColor))
                .background(selected ? Theme.accent : Color.clear, in: Capsule())
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

// 共享小组件（magpie 风格：13px 密集刻度 + 靛蓝主色 + 语义色适配深浅色）

/// 条目类型小图标
struct KindIcon: View {
    let kind: ClipKind

    var body: some View {
        Image(systemName: Theme.kindSymbol(kind))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.accent)
            .frame(width: 20, height: 20)
            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// 元信息行 "A · B · C"（11pt 次要色）
struct MetaLine: View {
    let parts: [String?]

    var body: some View {
        let texts = parts.compactMap { $0 }.filter { !$0.isEmpty }
        HStack(spacing: 4) {
            ForEach(texts.indices, id: \.self) { i in
                if i > 0 {
                    Text("·").foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                Text(texts[i])
                    .lineLimit(1)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }
}

/// 📌 置顶角标
struct PinBadge: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 8))
            .foregroundStyle(Theme.accent)
    }
}

/// 来源图标：App 图标 / favicon；无图时回退域名/应用名首字母徽标
struct SourceIconView: View {
    let image: NSImage?
    let fallbackText: String?

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.15))
                Text((fallbackText ?? "?").prefix(1))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 16, height: 16)
        }
    }
}

/// 底部毛玻璃 Toast
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }
}

/// 分组标题（今天 / 昨天 / 本周 / 更早 / ★ 置顶）
struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            if title == "★ 置顶" {
                PinBadge()
                Text("置顶")
            } else {
                Text(title)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .textCase(nil)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 28×28 hover 高亮图标按钮
struct AppIconButton: View {
    let systemName: String
    var active = false
    var helpText = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Theme.accent : Color(nsColor: .secondaryLabelColor))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? Theme.accent.opacity(0.14) : Color.clear)
        )
        .help(helpText)
    }
}
