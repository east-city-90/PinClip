import AppKit
import Observation
import SwiftUI

// MARK: - 截图状态机（设计方案 §3.3：idle → 遮罩选区 → 编辑态 → 复制/保存/贴图/取消）

enum CaptureTool: String, CaseIterable {
    case none = "无"
    case rect = "矩形"
    case ellipse = "椭圆"
    case line = "直线"
    case arrow = "箭头"
    case pen = "画笔"
    case text = "文字"
    case mosaic = "马赛克"
    case number = "序号"

    var symbol: String {
        switch self {
        case .none: return "arrow.up.left.and.arrow.down.right"
        case .rect: return "rectangle"
        case .ellipse: return "oval"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .text: return "textformat"
        case .mosaic: return "square.grid.3x3"
        case .number: return "number.circle"
        }
    }

    /// 工具条展示顺序（微信式：几何类 → 笔类 → 特效类）
    static var toolbarOrder: [CaptureTool] {
        [.rect, .ellipse, .line, .arrow, .pen, .text, .mosaic, .number]
    }
}

/// 一笔标注（坐标：选区局部，单位 point，原点=选区左上）
struct Stroke: Identifiable {
    enum Kind: CaseIterable {
        case rect, ellipse, line, arrow, pen, text, mosaic, number
    }

    let id = UUID()
    var kind: Kind
    var color: Color = .red
    var width: CGFloat = 3
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    var points: [CGPoint] = []      // pen 路径
    var text: String = ""
    var number: Int = 0
}

/// 单显示器截图状态（每个遮罩窗口一份）
@MainActor
@Observable
final class DisplayCaptureState {
    // 会话数据
    let displayID: CGDirectDisplayID
    let screen: NSScreen
    let bgImage: CGImage                 // 冻结帧（物理像素）
    let pixelatedImage: CGImage?         // 马赛克底（预计算）
    let scale: CGFloat                   // backing scale
    let bgPointSize: CGSize              // bg 在视图空间的 point 尺寸
    let snapWindows: [SnapWindow]        // 窗口吸附候选（全局左上原点 point）
    let isPrimaryInteraction: Bool       // 光标所在屏

    // 状态机
    var phase: Phase = .picking
    enum Phase { case picking, editing }

    /// 编辑态拖拽模式（微信式：拖角调整大小 / 拖内部移动 / 拖外部重新框选）
    var editDrag: EditDrag?
    enum EditDrag {
        case move(originalOrigin: CGPoint, anchor: CGPoint)
        case resize(fixedCorner: CGPoint)
    }

    // 选区（视图空间 = 屏幕局部，左上原点 point）
    var selection: CGRect?
    var dragStart: CGPoint?
    var hoverSnap: SnapWindow?

    // 编辑态
    var tool: CaptureTool = .none
    var strokeColor: Color = Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255) // #ef4444
    var strokeWidth: CGFloat = 3
    var strokes: [Stroke] = []
    var activeStroke: Stroke?
    var numberCounter = 1
    var textDraft: TextDraft?
    struct TextDraft {
        let point: CGPoint
        var content: String = ""
    }
    var exportFlash: Bool = false
    /// 导出时是否包背景+阴影装饰（CleanShot 式，工具条可切换）
    var decorated: Bool = false
    /// 选区尺寸角标（左上角 W×H，跟随设置，默认关）
    var showBadge: Bool = false

    init(displayID: CGDirectDisplayID, screen: NSScreen, bgImage: CGImage, scale: CGFloat,
         snapWindows: [SnapWindow], isPrimaryInteraction: Bool) {
        self.displayID = displayID
        self.screen = screen
        self.bgImage = bgImage
        self.scale = scale
        self.snapWindows = snapWindows
        self.isPrimaryInteraction = isPrimaryInteraction
        self.bgPointSize = CGSize(width: CGFloat(bgImage.width) / scale, height: CGFloat(bgImage.height) / scale)
        self.pixelatedImage = ImageKit.pixelated(bgImage)
    }

    // MARK: 选区

    func beginDrag(at point: CGPoint) {
        guard phase == .picking else { return }
        dragStart = point
        selection = CGRect(origin: point, size: .zero)
    }

    func updateDrag(to point: CGPoint) {
        guard let start = dragStart else { return }
        selection = CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)
        )
        // 实际拖动超过 4px 才清除吸附高亮（微动点击仍可采纳窗口 → 点击截全图）
        if let sel = selection, sel.width > 4, sel.height > 4 { hoverSnap = nil }
    }

    func endDrag(at point: CGPoint) {
        guard let start = dragStart else { return }
        dragStart = nil
        updateDrag(to: point)

        // 微动点击：命中吸附窗口 → 采纳窗口框为选区（出现工具条，可继续标注）；无吸附则取消选区
        if let sel = selection, sel.width < 8, sel.height < 8 {
            if let snap = hoverSnap {
                selection = snapRectToLocal(snap.rect)
                phase = .editing
                tool = .none
                return
            } else {
                selection = nil
                return
            }
        }
        // 最小选区
        if let sel = selection, sel.width < 12, sel.height < 12 { selection = nil; return }
        phase = .editing
        tool = .none
    }

    /// 全局左上坐标 → 本屏视图局部
    private func snapRectToLocal(_ rect: CGRect) -> CGRect {
        let topLeft = ScreenGeometry.screenTopLeft(of: screen)
        return CGRect(x: rect.minX - topLeft.x, y: rect.minY - topLeft.y,
                      width: rect.width, height: rect.height)
    }

    func pointInView(from globalTopLeft: CGPoint) -> CGPoint {
        let topLeft = ScreenGeometry.screenTopLeft(of: screen)
        return CGPoint(x: globalTopLeft.x - topLeft.x, y: globalTopLeft.y - topLeft.y)
    }

    // MARK: 编辑态选区调整（微信式）

    /// 判定拖拽落点属于哪种编辑操作；返回 false = 落点在选区外 → 重新框选
    @discardableResult
    func beginEditDrag(at point: CGPoint) -> Bool {
        guard let sel = selection else { return false }
        let corner = Self.nearestCorner(of: sel, to: point)
        if hypot(point.x - corner.x, point.y - corner.y) <= 10 {
            editDrag = .resize(fixedCorner: Self.oppositeCorner(of: sel, nearest: corner))
            return true
        }
        if sel.insetBy(dx: 6, dy: 6).contains(point) {
            editDrag = .move(originalOrigin: sel.origin, anchor: point)
            return true
        }
        return false
    }

    func updateEditDrag(to point: CGPoint) {
        switch editDrag {
        case .move(let origin, let anchor):
            selection?.origin = CGPoint(
                x: origin.x + (point.x - anchor.x),
                y: origin.y + (point.y - anchor.y)
            )
        case .resize(let fixed):
            selection = CGRect(
                x: min(fixed.x, point.x), y: min(fixed.y, point.y),
                width: abs(point.x - fixed.x), height: abs(point.y - fixed.y)
            )
        case nil:
            break
        }
    }

    func endEditDrag() {
        if case .resize = editDrag, let sel = selection, sel.width < 12 || sel.height < 12 {
            selection = CGRect(
                x: sel.minX, y: sel.minY,
                width: max(sel.width, 12), height: max(sel.height, 12)
            )
        }
        editDrag = nil
    }

    /// 选区外重新框选：清空标注、回到 picking 拖拽流程
    func startReselect(at point: CGPoint) {
        phase = .picking
        strokes = []
        activeStroke = nil
        numberCounter = 1
        textDraft = nil
        tool = .none
        hoverSnap = nil
        beginDrag(at: point)
    }

    static func nearestCorner(of rect: CGRect, to point: CGPoint) -> CGPoint {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ]
        return corners.min {
            hypot(point.x - $0.x, point.y - $0.y) < hypot(point.x - $1.x, point.y - $1.y)
        } ?? .zero
    }

    static func oppositeCorner(of rect: CGRect, nearest: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + rect.maxX - nearest.x, y: rect.minY + rect.maxY - nearest.y)
    }

    // MARK: 标注

    func commitStroke(_ stroke: Stroke) {
        strokes.append(stroke)
    }

    func undo() {
        guard let last = strokes.popLast() else { return }
        if last.kind == .number {
            numberCounter = max(1, numberCounter - 1)
        }
    }

    /// 提交文字草稿（草稿 point 是遮罩根视图坐标，内部转为选区局部）
    func commitTextDraft() {
        defer { textDraft = nil }
        guard let draft = textDraft, !draft.content.isEmpty, let sel = selection else { return }
        var stroke = Stroke(kind: .text, color: strokeColor)
        stroke.start = CGPoint(x: draft.point.x - sel.minX, y: draft.point.y - sel.minY)
        stroke.text = draft.content
        strokes.append(stroke)
    }

    /// 选区内的物理像素尺寸提示（如 628×412）
    var sizeHint: String? {
        guard let sel = selection else { return nil }
        return "\(Int((sel.width * scale).rounded()))×\(Int((sel.height * scale).rounded()))"
    }

    // MARK: 导出（ImageRenderer 与实时视图共用同一渲染路径）

    func exportImage(action: CaptureAction) -> CGImage? {
        guard let sel = selection else { return nil }
        let content = CaptureContentView(
            bg: bgImage,
            pixelated: pixelatedImage,
            scale: scale,
            bgPointSize: bgPointSize,
            selection: CGRect(origin: .zero, size: sel.size),   // 导出时选区平移到原点
            selectionOrigin: sel.origin,
            strokes: strokes,
            activeStroke: nil
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(sel.size)
        return renderer.cgImage
    }

    /// 导出选区的全局左上坐标（point，供元数据/保存命名用）
    var selectionGlobalRect: CGRect? {
        guard let sel = selection else { return nil }
        let topLeft = ScreenGeometry.screenTopLeft(of: screen)
        return CGRect(x: sel.minX + topLeft.x, y: sel.minY + topLeft.y, width: sel.width, height: sel.height)
    }
}

/// 屏幕坐标换算：全局屏幕空间（左上原点，point）↔ NSScreen frame（左下原点）
enum ScreenGeometry {
    /// 某屏的全局左上原点（左上坐标系）
    static func screenTopLeft(of screen: NSScreen) -> CGPoint {
        // screens[0] 是主屏（frame 原点 (0,0)），其 maxY 即全局坐标系总高度
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
    }
}

// MARK: - 遮罩+选区+标注的统一渲染（实时视图与 ImageRenderer 导出共用）

struct CaptureContentView: View {
    let bg: CGImage
    let pixelated: CGImage?
    let scale: CGFloat
    let bgPointSize: CGSize
    let selection: CGRect          // 内容局部坐标（导出时 origin=.zero；实时时为屏局部坐标）
    let selectionOrigin: CGPoint   // bg 对齐偏移（实时时=selection.origin；导出时同 origin）
    let strokes: [Stroke]
    let activeStroke: Stroke?

    var body: some View {
        Color.clear
            .frame(width: selection.width, height: selection.height)
            .overlay(alignment: .topLeading) {
                Image(decorative: bg, scale: scale)
                    .frame(width: bgPointSize.width, height: bgPointSize.height)
                    .offset(x: -selectionOrigin.x, y: -selectionOrigin.y)
            }
            .overlay(alignment: .topLeading) {
                StrokeCanvas(strokes: strokes + [activeStroke].compactMap { $0 },
                             pixelated: pixelated, scale: scale,
                             bgOrigin: CGPoint(x: -selectionOrigin.x, y: -selectionOrigin.y),
                             bgSize: bgPointSize)
                    .frame(width: selection.width, height: selection.height)
            }
            .clipped()
    }
}

/// 标注画布：所有笔画的绘制逻辑唯一来源
struct StrokeCanvas: View {
    let strokes: [Stroke]
    let pixelated: CGImage?
    let scale: CGFloat
    let bgOrigin: CGPoint      // bg 图相对画布原点的偏移（负值）
    let bgSize: CGSize

    var body: some View {
        Canvas { ctx, size in
            for stroke in strokes {
                draw(stroke, in: &ctx, size: size)
            }
        }
    }

    private func draw(_ stroke: Stroke, in ctx: inout GraphicsContext, size: CGSize) {
        switch stroke.kind {
        case .rect:
            let rect = strokeRect(stroke)
            ctx.stroke(Path(rect), with: .color(stroke.color), lineWidth: stroke.width)
        case .ellipse:
            let rect = strokeRect(stroke)
            ctx.stroke(Path(ellipseIn: rect), with: .color(stroke.color), lineWidth: stroke.width)
        case .line:
            var path = Path()
            path.move(to: stroke.start)
            path.addLine(to: stroke.end)
            ctx.stroke(path, with: .color(stroke.color), style: StrokeStyle(lineWidth: stroke.width, lineCap: .round))
        case .arrow:
            drawArrow(stroke, in: &ctx)
        case .pen:
            guard stroke.points.count > 1 else { return }
            var path = Path()
            path.move(to: stroke.points[0])
            for p in stroke.points.dropFirst() { path.addLine(to: p) }
            ctx.stroke(path, with: .color(stroke.color), style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round))
        case .mosaic:
            drawMosaic(stroke, in: &ctx)
        case .text:
            let resolved = ctx.resolve(
                Text(stroke.text)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(stroke.color)
            )
            ctx.draw(resolved, at: stroke.start, anchor: .topLeading)
        case .number:
            let r: CGFloat = 11
            let center = stroke.start
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(stroke.color))
            let resolved = ctx.resolve(
                Text("\(stroke.number)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            )
            ctx.draw(resolved, at: center, anchor: .center)
        }
    }

    private func strokeRect(_ stroke: Stroke) -> CGRect {
        CGRect(x: min(stroke.start.x, stroke.end.x), y: min(stroke.start.y, stroke.end.y),
               width: abs(stroke.end.x - stroke.start.x), height: abs(stroke.end.y - stroke.start.y))
    }

    private func drawArrow(_ stroke: Stroke, in ctx: inout GraphicsContext) {
        var path = Path()
        path.move(to: stroke.start)
        path.addLine(to: stroke.end)
        ctx.stroke(path, with: .color(stroke.color), style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round))

        // 箭头头部
        let angle = atan2(stroke.end.y - stroke.start.y, stroke.end.x - stroke.start.x)
        let head: CGFloat = max(stroke.width * 4, 12)
        let a = CGPoint(x: stroke.end.x - head * cos(angle - .pi / 7), y: stroke.end.y - head * sin(angle - .pi / 7))
        let b = CGPoint(x: stroke.end.x - head * cos(angle + .pi / 7), y: stroke.end.y - head * sin(angle + .pi / 7))
        var headPath = Path()
        headPath.move(to: a)
        headPath.addLine(to: stroke.end)
        headPath.addLine(to: b)
        ctx.stroke(headPath, with: .color(stroke.color), style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round))
    }

    private func drawMosaic(_ stroke: Stroke, in ctx: inout GraphicsContext) {
        guard let pixelated else { return }
        let rect = strokeRect(stroke)
        ctx.drawLayer { layer in
            layer.clip(to: Path(rect))
            // 马赛克底图与 bg 同一坐标系（含 bgOrigin 偏移）
            layer.draw(
                Image(decorative: pixelated, scale: scale),
                in: CGRect(origin: bgOrigin, size: bgSize)
            )
        }
    }
}
