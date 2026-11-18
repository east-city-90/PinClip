import SwiftUI
import AppKit

// magpie 基础组件（色值/字重/圆角/阴影均按 magpie-ui-design-reference 实测令牌）

/// 条目类型小图标（灰阶克制：ctlFg on pill）
struct KindIcon: View {
    let kind: ClipKind
    var body: some View {
        Image(systemName: Theme.kindSymbol(kind))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.ctlFg)
            .frame(width: 20, height: 20)
            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// 来源图标：App 图标 / favicon；无图时回退首字母徽标（accentSoft + accent）
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
                Circle().fill(Theme.accentSoft)
                Text((fallbackText ?? "?").prefix(1))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 16, height: 16)
        }
    }
}

/// magpie 分段控件（界面标志性控件）：无轨道背景，仅选中项有白色浮块 + 发丝小阴影
struct MagpieSegmented: View {
    let options: [HistoryFilter]
    let binding: Binding<HistoryFilter>

    private var thumbFill: Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.15)
                : NSColor.white
        })
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { opt in
                let on = binding.wrappedValue == opt
                Button {
                    binding.wrappedValue = opt
                } label: {
                    Text(opt.label)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(on ? Theme.fg : Theme.ctlFg)
                .background(
                    Group {
                        if on {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(thumbFill)
                                .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
                                .shadow(color: .black.opacity(0.08), radius: 0.5)
                        }
                    }
                )
            }
        }
        .padding(2)
    }
}

/// 弹层 Toast（magpie pop：94–96% 底 + blur(24) + 11px 圆角 + 三层柔影）
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Theme.popTint
                }
                .clipShape(RoundedRectangle(cornerRadius: 11))
            )
            .shadow(color: .black.opacity(0.16), radius: 22, y: 8)
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            .shadow(color: .black.opacity(0.10), radius: 0.5)
    }
}

/// 置顶徽标（6px 强调色圆点样式语言）
struct PinBadge: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 8))
            .foregroundStyle(Theme.accent)
    }
}

/// 分组微标签（magpie 签名手法：11px / 600 / .05em 字距 / muted）
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
        .tracking(0.5)
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 图标文字钮（magpie text 按钮：静默灰字，悬停 pill 底）
struct AppIconButton: View {
    let systemName: String
    var active = false
    var helpText = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Theme.accent : Theme.ctlFg)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? Theme.accentSoft : (hovering ? Theme.pill : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(helpText)
    }
}

// MARK: - 毛玻璃背景（underWindowBackground 模糊 + magpie pop 基底 tint）

struct GlassBackground: View {
    var tintOpacity: Double = 1.0

    var body: some View {
        ZStack {
            NSVisualEffectViewWrapper()
            Theme.popTint.opacity(tintOpacity)
        }
    }

    static func layered() -> some View {
        ZStack {
            GlassBackground()
            Theme.popTint
        }
    }
}

struct NSVisualEffectViewWrapper: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Liquid Glass 表面：macOS 26+ 用系统液态玻璃材质，旧系统回退毛玻璃
extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(in: shape)
        } else {
            self
                .background(
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        Theme.popTint.opacity(0.6)
                    }
                    .clipShape(shape)
                )
        }
    }
}

// MARK: - 元信息行（11px muted 层级）

struct MetaLine: View {
    let parts: [String?]

    var body: some View {
        let texts = parts.compactMap { $0 }.filter { !$0.isEmpty }
        HStack(spacing: 4) {
            ForEach(texts.indices, id: \.self) { i in
                if i > 0 {
                    Text("·").foregroundStyle(Theme.faint)
                }
                Text(texts[i])
                    .lineLimit(1)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.muted)
    }
}
