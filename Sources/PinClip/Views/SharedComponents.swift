import SwiftUI
import AppKit

// magpie 基础组件（色值/字重/圆角/阴影均按 magpie-ui-design-reference 实测令牌）

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

/// 弹层 Toast（magpie pop：94–96% 底 + blur(24) + 11px 圆角 + 三层柔影）
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            )
            .shadow(color: .black.opacity(0.16), radius: 22, y: 8)
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            .shadow(color: .black.opacity(0.10), radius: 0.5)
    }
}

/// 置顶徽标（强调色图钉）
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
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Liquid Glass 表面（macOS 26+ 系统液态玻璃；旧系统回退毛玻璃）

extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(in: shape)
        } else {
            self
                .background(
                    Rectangle().fill(.ultraThinMaterial)
                )
                .clipShape(shape)
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
