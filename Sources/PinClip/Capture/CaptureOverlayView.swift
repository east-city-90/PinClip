import SwiftUI

/// 截图遮罩主视图：冻结帧背景 + 暗化遮罩 + 选区 + 窗口吸附高亮 + 标注 + 工具条 + 放大镜 + 尺寸角标
struct CaptureOverlayView: View {
    let state: DisplayCaptureState
    let controller: OverlayController
    @FocusState private var textFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 冻结帧背景
            Image(decorative: state.bgImage, scale: state.scale)
                .frame(width: state.bgPointSize.width, height: state.bgPointSize.height)

            maskView

            if state.phase == .picking, let snap = state.hoverSnap {
                snapHighlight(snap)
            }

            if let sel = state.selection {
                // 选区内容 + 标注（与导出共用同一渲染组件）
                // 注意修饰符顺序：border 必须在 offset 之前，否则边框画在位移前的 frame 上
                CaptureContentView(
                    bg: state.bgImage,
                    pixelated: state.pixelatedImage,
                    scale: state.scale,
                    bgPointSize: state.bgPointSize,
                    selection: sel,
                    selectionOrigin: sel.origin,
                    strokes: state.strokes,
                    activeStroke: state.activeStroke
                )
                .border(Theme.selectionBlue, width: 2)
                .offset(x: sel.minX, y: sel.minY)

                if state.phase == .editing {
                    cornerHandles(for: sel)
                }

                if state.showBadge, let hint = state.sizeHint {
                    sizeBadge(hint, at: sel)
                }

                if state.phase == .editing {
                    CaptureToolbar(state: state, controller: controller)
                        .position(toolbarPosition(for: sel))
                }

                if let draft = state.textDraft {
                    textDraftField(draft)
                }
            }

            // 放大镜（picking 态：悬停/拖拽时跟随光标；吸附高亮出现时隐藏避免干扰）
            if state.phase == .picking, state.hoverSnap == nil, let cp = state.cursorPoint {
                MagnifierView(state: state, at: cp)
            }
        }
        .frame(width: state.bgPointSize.width, height: state.bgPointSize.height)
        .contentShape(Rectangle())
        .gesture(captureGesture)
        // 注意：不要在此处加 onTapGesture——与 minimumDistance:0 的拖拽手势产生识别竞争，
        // 会吞掉第一次拖拽（曾导致"第一次画选区不生效"）
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                if state.phase == .picking {
                    if state.dragStart == nil {
                        state.hoverSnap = topSnapWindow(containing: location)
                    }
                    state.cursorPoint = location
                }
            case .ended:
                if state.dragStart == nil {
                    state.hoverSnap = nil
                    state.cursorPoint = nil
                }
            }
        }
        .onChange(of: state.cursorPoint) { _, newPoint in
            // 放大镜取色：1×1 绘制采样，代价极小
            guard let cp = newPoint else {
                state.cursorColorHex = nil
                return
            }
            let pixel = CGPoint(x: cp.x * state.scale, y: cp.y * state.scale)
            state.cursorColorHex = ImageKit.sampleColor(of: state.bgImage, atPixel: pixel)
        }
    }

    /// 四角手柄（微信式白色小方块 + 蓝色描边）
    private func cornerHandles(for sel: CGRect) -> some View {
        ForEach(0..<4, id: \.self) { i in
            let p = [
                CGPoint(x: sel.minX, y: sel.minY), CGPoint(x: sel.maxX, y: sel.minY),
                CGPoint(x: sel.minX, y: sel.maxY), CGPoint(x: sel.maxX, y: sel.maxY),
            ][i]
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.white)
                .frame(width: 9, height: 9)
                .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(Theme.selectionBlue, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.25), radius: 1)
                .offset(x: p.x - 4.5, y: p.y - 4.5)
        }
    }

    // MARK: 手势（选区与标注共用根手势，按状态机分派）

    private var captureGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                switch state.phase {
                case .picking:
                    if state.dragStart == nil {
                        state.beginDrag(at: value.startLocation)
                    }
                    // 按住 ⇧ 锁定正方形
                    state.updateDrag(to: value.location, square: NSEvent.modifierFlags.contains(.shift))
                    state.cursorPoint = value.location
                case .editing:
                    if state.tool == .none, state.textDraft == nil {
                        // 工具栏区域：根手势完全不干预，按下与点击交给按钮自身处理
                        // （否则 startReselect 会在按下时清空选区——"工具栏消失需重画"的根因）
                        if let sel = state.selection,
                           state.toolbarFrame(for: sel).contains(value.startLocation) {
                            return
                        }
                        // 微信式：拖角调整 / 拖内部移动 / 拖外部重新框选
                        if state.editDrag == nil, state.dragStart == nil, !state.beginEditDrag(at: value.startLocation) {
                            state.startReselect(at: value.startLocation)
                        }
                        if state.editDrag != nil {
                            state.updateEditDrag(to: value.location)
                        } else if state.dragStart != nil {
                            state.updateDrag(to: value.location, square: NSEvent.modifierFlags.contains(.shift))
                        }
                    } else {
                        updateActiveStroke(at: value.location, anchor: value.startLocation, moved: abs(value.translation.width) + abs(value.translation.height))
                    }
                }
            }
            .onEnded { value in
                switch state.phase {
                case .picking:
                    state.endDrag(at: value.location)
                case .editing:
                    if state.editDrag != nil {
                        state.endEditDrag()
                    } else if state.dragStart != nil {
                        state.endDrag(at: value.location)
                    } else {
                        finishActiveStroke(at: value.location, moved: abs(value.translation.width) + abs(value.translation.height))
                    }
                }
            }
    }

    // MARK: 遮罩（选区挖孔，4 块矩形避免超大阴影层）

    @ViewBuilder
    private var maskView: some View {
        let dark = Color.black.opacity(0.35)
        if let sel = state.selection {
            let s = sel
            ZStack(alignment: .topLeading) {
                dark.frame(width: state.bgPointSize.width, height: max(s.minY, 0))
                    .offset(x: 0, y: 0)
                dark.frame(width: max(s.minX, 0), height: s.height)
                    .offset(x: 0, y: s.minY)
                dark.frame(width: max(state.bgPointSize.width - s.maxX, 0), height: s.height)
                    .offset(x: s.maxX, y: s.minY)
                dark.frame(width: state.bgPointSize.width, height: max(state.bgPointSize.height - s.maxY, 0))
                    .offset(x: 0, y: s.maxY)
            }
        } else {
            Color.black.opacity(0.35)
        }
    }

    private func snapHighlight(_ snap: SnapWindow) -> some View {
        let local = state.pointInView(from: CGPoint(x: snap.rect.minX, y: snap.rect.minY))
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.selectionBlue, lineWidth: 2))
            Text("\(snap.appName)\(snap.title.isEmpty ? "" : " · \(snap.title)")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .offset(x: local.x, y: max(local.y - 22, 0))
        }
        .frame(width: snap.rect.width, height: snap.rect.height)
        .offset(x: local.x, y: local.y)
    }

    private func sizeBadge(_ hint: String, at sel: CGRect) -> some View {
        Text(hint)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
            .offset(
                x: sel.minX,
                y: sel.minY > 26 ? sel.minY - 24 : sel.minY + 4
            )
    }

    private func toolbarPosition(for sel: CGRect) -> CGPoint {
        let frame = state.toolbarFrame(for: sel)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: 文字工具输入框

    private func textDraftField(_ draft: DisplayCaptureState.TextDraft) -> some View {
        TextField("输入文字，回车确认", text: Binding(
            get: { state.textDraft?.content ?? "" },
            set: { state.textDraft?.content = $0 }
        ))
        .textFieldStyle(.plain)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(state.strokeColor)
        .focused($textFocused)
        .onSubmit {
            commitTextDraft()
        }
        .onAppear { textFocused = true }
        .frame(minWidth: 160)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
        .offset(x: draft.point.x, y: draft.point.y)
    }

    // MARK: 标注笔画

    /// 手势回调坐标（遮罩根视图空间）→ 选区局部坐标（笔画绘制空间）
    /// 根因修复：StrokeCanvas 以选区左上为原点，不转换则笔画画在画布外被裁掉（表现为"无法标注"）
    private func selLocal(_ point: CGPoint) -> CGPoint {
        guard let sel = state.selection else { return point }
        return CGPoint(x: point.x - sel.minX, y: point.y - sel.minY)
    }

    private func updateActiveStroke(at location: CGPoint, anchor: CGPoint, moved: CGFloat) {
        let end = selLocal(location)
        let start = selLocal(anchor)
        switch state.tool {
        case .rect, .ellipse, .mosaic, .line, .arrow:
            state.activeStroke = Stroke(
                kind: state.tool.strokeKind, color: state.strokeColor, width: state.strokeWidth,
                start: start, end: end
            )
        case .pen:
            if var stroke = state.activeStroke, stroke.kind == .pen {
                stroke.points.append(end)
                state.activeStroke = stroke
            } else {
                var stroke = Stroke(kind: .pen, color: state.strokeColor, width: state.strokeWidth)
                stroke.points = [start, end]
                state.activeStroke = stroke
            }
        case .text, .number, .none:
            break
        }
    }

    private func finishActiveStroke(at location: CGPoint, moved: CGFloat) {
        let point = selLocal(location)
        switch state.tool {
        case .rect, .ellipse, .mosaic, .line, .arrow, .pen:
            if let stroke = state.activeStroke, moved >= 3 {
                state.commitStroke(stroke)
            }
            state.activeStroke = nil
        case .text:
            if moved < 6 {
                // 文字输入框定位在遮罩根视图空间（提交时由 state.commitTextDraft 转换为选区局部）
                state.textDraft = DisplayCaptureState.TextDraft(point: location)
            }
        case .number:
            if moved < 6 {
                var stroke = Stroke(kind: .number, color: state.strokeColor)
                stroke.start = point
                stroke.number = state.numberCounter
                state.numberCounter += 1
                state.commitStroke(stroke)
            }
        case .none:
            break
        }
    }

    private func commitTextDraft() {
        state.commitTextDraft()
    }

    // MARK: 窗口吸附

    private func topSnapWindow(containing point: CGPoint) -> SnapWindow? {
        for snap in state.snapWindows {
            let local = state.pointInView(from: CGPoint(x: snap.rect.minX, y: snap.rect.minY))
            let rect = CGRect(origin: local, size: snap.rect.size)
            if rect.contains(point) {
                return snap
            }
        }
        return nil
    }
}

// MARK: - 放大镜（选区悬停/拖拽时的像素级放大 + 坐标/颜色提示）

struct MagnifierView: View {
    let state: DisplayCaptureState
    let at: CGPoint

    private let lensSize: CGFloat = 96
    private let zoom: CGFloat = 6

    var body: some View {
        VStack(spacing: 4) {
            lens
            Text(labelText)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.65), in: Capsule())
        }
        .offset(x: offset.x, y: offset.y)
        .allowsHitTesting(false)
    }

    /// 贴光标右下；靠右/靠下时翻到另一侧，避免出屏
    private var offset: CGPoint {
        let pad: CGFloat = 18
        var x = at.x + pad
        var y = at.y + pad
        let total = lensSize + 24
        if x + total > state.bgPointSize.width { x = at.x - total - pad }
        if y + total > state.bgPointSize.height { y = at.y - total - pad }
        return CGPoint(x: x, y: y)
    }

    private var lens: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: state.bgImage, scale: state.scale)
                .resizable()
                .interpolation(.none)
                .frame(width: state.bgPointSize.width * zoom, height: state.bgPointSize.height * zoom)
                .offset(x: lensSize / 2 - at.x * zoom, y: lensSize / 2 - at.y * zoom)
            crosshair
        }
        .frame(width: lensSize, height: lensSize, alignment: .topLeading)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.selectionBlue, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }

    private var crosshair: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.9))
                .frame(width: lensSize, height: 1)
                .shadow(color: .black.opacity(0.6), radius: 0.5)
            Rectangle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 1, height: lensSize)
                .shadow(color: .black.opacity(0.6), radius: 0.5)
        }
        .allowsHitTesting(false)
    }

    private var labelText: String {
        let px = Int(at.x * state.scale), py = Int(at.y * state.scale)
        if let hex = state.cursorColorHex {
            return "\(px), \(py) · \(hex)"
        }
        return "\(px), \(py)"
    }
}

extension CaptureTool {
    /// SwiftUI 工具枚举 → 笔画枚举
    var strokeKind: Stroke.Kind {
        switch self {
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case .pen: return .pen
        case .text: return .text
        case .mosaic: return .mosaic
        case .number: return .number
        case .none: return .rect
        }
    }
}
