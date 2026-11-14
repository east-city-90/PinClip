import SwiftUI

/// 截图工具条（微信式）：浅色胶囊 · 工具八件套 · 调色/粗细 · 撤销 · 绿色✓复制主按钮 · 保存/贴图/取消
struct CaptureToolbar: View {
    let state: DisplayCaptureState
    let controller: OverlayController

    /// 颜色槽位（微信式六色）
    private let palette: [Color] = [
        Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255),   // 红
        Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255),  // 黄
        Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255),   // 绿
        Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255),  // 蓝
        Color.white,
        Color.black,
    ]

    var body: some View {
        HStack(spacing: 5) {
            // 标注工具（微信式顺序）
            ForEach(CaptureTool.toolbarOrder, id: \.self) { tool in
                toolButton(tool)
            }

            divider

            // 调色 + 粗细（选中标注工具时展开）
            if state.tool != .none {
                paletteButtons
                widthButtons
                divider
            }

            undoButton
            divider
            confirmButtons
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .glassSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .fixedSize()
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 18)
    }

    private func toolButton(_ tool: CaptureTool) -> some View {
        let selected = state.tool == tool
        return Button {
            state.tool = selected ? .none : tool   // 再点一次取消选中（微信行为）
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 13))
                .frame(width: 27, height: 27)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Theme.selectionBlue : Color(nsColor: .labelColor))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Theme.selectionBlue.opacity(0.15) : Color.clear)
        )
        .help("\(tool.rawValue)（点击后拖拽/单击选区）")
    }

    private var paletteButtons: some View {
        HStack(spacing: 4) {
            ForEach(palette.indices, id: \.self) { i in
                let color = palette[i]
                Button {
                    state.strokeColor = color
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 13, height: 13)
                        .overlay(
                            Circle().stroke(
                                state.strokeColor == color ? Theme.selectionBlue : Color(nsColor: .separatorColor),
                                lineWidth: state.strokeColor == color ? 2 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var widthButtons: some View {
        HStack(spacing: 3) {
            ForEach([2.0, 4.0, 7.0], id: \.self) { w in
                Button {
                    state.strokeWidth = w
                } label: {
                    Circle()
                        .fill(Color(nsColor: .labelColor))
                        .frame(width: w + 2, height: w + 2)
                        .padding(3)
                        .background(
                            Circle().fill(state.strokeWidth == w ? Theme.selectionBlue.opacity(0.30) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("线宽 \(Int(w))")
            }
        }
    }

    private var undoButton: some View {
        Button {
            state.undo()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13))
                .frame(width: 27, height: 27)
        }
        .buttonStyle(.plain)
        .foregroundStyle(state.strokes.isEmpty ? Color(nsColor: .quaternaryLabelColor) : Color(nsColor: .labelColor))
        .disabled(state.strokes.isEmpty)
        .help("撤销 ⌘Z")
    }

    private var confirmButtons: some View {
        HStack(spacing: 5) {
            // 背景+阴影装饰开关（CleanShot 式导出）
            Button {
                state.decorated.toggle()
            } label: {
                Text("装饰")
                    .font(.system(size: 12, weight: state.decorated ? .semibold : .regular))
                    .padding(.horizontal, 8)
                    .frame(height: 27)
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.decorated ? Theme.selectionBlue : Color(nsColor: .labelColor))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(state.decorated ? Theme.selectionBlue.opacity(0.15) : Color.clear)
            )
            .help("背景 + 阴影装饰导出")

            // 微信式绿色主按钮：✓ 复制
            Button {
                controller.finalize(action: .copy)
            } label: {
                Label("复制", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 27)
            }
            .buttonStyle(.plain)
            .background(Theme.wechatGreen, in: Capsule())
            .help("复制到剪贴板 ⏎ / 双击选区")

            Button {
                controller.finalize(action: .save)
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 13))
                    .frame(width: 27, height: 27)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: .labelColor))
            .help("保存到桌面 ⌘S")

            Button {
                controller.finalize(action: .pin)
            } label: {
                Image(systemName: "pin")
                    .font(.system(size: 13))
                    .frame(width: 27, height: 27)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: .labelColor))
            .help("贴图")

            Button {
                controller.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 27, height: 27)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .help("取消 Esc")
        }
    }
}
