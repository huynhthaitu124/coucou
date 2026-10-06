import SwiftUI

/// Top-level SwiftUI view rendered inside the 720×320 transparent panel.
/// The island is drawn at the top-center; everything else is transparent and click-through.
/// Note: drag-drop is handled at the AppKit level in IslandWindowController (FileDropNSView),
/// not in SwiftUI, to avoid interfering with SwiftUI hit-testing.
struct IslandRootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            IslandContainer(state: state)
                .frame(maxWidth: .infinity, alignment: .center)

        }
        .ignoresSafeArea()
    }
}

// MARK: - Notch Live Activity View (Apple Dynamic Island style inside the Notch)

struct NotchLiveActivityView: View {
    let suggestion: ProactiveSuggestion
    @ObservedObject var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat

    /// Calculate the hardware camera notch dangerous area (MacBook notch height)
    private var safeAreaTop: CGFloat {
        state.hasNotch ? max(state.notchHeight, 33) : max(state.notchHeight, 26)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Push content completely down past the physical notch cutout
            Spacer().frame(height: safeAreaTop)

            HStack(spacing: 12) {
                // Ultra-short title and punchy detail (no icon)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(suggestion.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Color(hex: "#F9FAFB"))
                        .lineLimit(1)
                    if let detail = suggestion.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 9.5))
                            .foregroundColor(Color(hex: "#9CA3AF"))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                // Action button ("Thực hiện")
                Button {
                    CoucouSentinel.shared.acceptSuggestion(suggestion, state: state)
                } label: {
                    Text("Thực hiện")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Color(hex: "#0B0C0E"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4.5)
                        .background(
                            LinearGradient(
                                colors: [Color.white, Color(hex: "#E5E7EB")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(Capsule())
                        .shadow(color: Color.black.opacity(0.25), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    NotificationCenter.default.post(name: .botSetTgEs, object: hovering ? CGFloat(1.18) : CGFloat(1.0))
                }

                // Dismiss button
                Button {
                    CoucouSentinel.shared.dismissSuggestion(state: state)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color(hex: "#9CA3AF"))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
        }
        .frame(width: islandW, height: islandH, alignment: .top)
    }
}

// MARK: - Island container

struct IslandContainer: View {
    @ObservedObject var state: AppState
    @State private var islandWidth:  CGFloat = IslandConst.notchWidth
    @State private var islandHeight: CGFloat = IslandConst.notchHeight
    @State private var cornerRadius: CGFloat = IslandConst.roundedCorner
    // topRadius > 0 → convex expanded corners; < 0 → concave ear cutouts
    @State private var islandTopRadius: CGFloat = 0
    @State private var greetNotif: Bool = false

    private let openSpring = Animation.spring(response: 0.5, dampingFraction: 0.72)
    private let closeEase  = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.34)

    private var chatPromptHeight: CGFloat {
        if state.isLargeExpanded {
            let base: CGFloat = 400
            let perMsg: CGFloat = 40
            return min(520, base + CGFloat(state.chatHistory.count) * perMsg)
        } else {
            let base: CGFloat = 240
            let perMsg: CGFloat = 40
            return min(300, base + CGFloat(state.chatHistory.count) * perMsg)
        }
    }

    /// Pixels the content must be pushed down to clear the concave ear transparent area.
    /// = 0 in expanded mode (no ears), = earRadius in compact/notch mode.
    private var earOffset: CGFloat { max(0, -islandTopRadius) }

    var body: some View {
        // Canvas active during drag-over (.upload), post-drop animation (.uploading),
        // AND choose overlay (.choose) — canvas handles the full sequence through user action.
        // Engine deactivates when user clicks a canvas choose button or navigates away.
        let uploadActive = state.mode == .expanded
            && UploadSequenceEngine.shared.isActive
            && (state.view == .upload || state.view == .uploading || state.view == .choose)

        let greetingActive = state.mode == .expanded && state.view == .greeting

        return ZStack(alignment: .topLeading) {
            // Black island shape
            IslandShape(width: islandWidth, height: islandHeight,
                        cornerRadius: cornerRadius, topRadius: islandTopRadius)
                .fill(Color.black)

            // Content
            if state.mode == .expanded {
                if greetingActive {
                    // Greeting canvas: fixed 640-wide, centered by offset so x=320 aligns with island center
                    GreetingCanvasView(state: state)
                        .frame(width: IslandConst.expandedWidth, height: 150)
                        .offset(x: (islandWidth - IslandConst.expandedWidth) / 2)
                        .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                              cornerRadius: cornerRadius, topRadius: islandTopRadius))
                        .transition(
                            .asymmetric(
                                insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.08)),
                                removal: .opacity.animation(.easeIn(duration: 0.12))
                            )
                        )
                } else if uploadActive {
                    ZStack(alignment: .topLeading) {
                        UploadCanvasView(state: state)
                            .frame(width: islandWidth, height: islandHeight)
                            .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                                  cornerRadius: cornerRadius, topRadius: islandTopRadius))
                        // Header overlaid: canvas CARD_Y=42 aligns exactly with header bottom,
                        // matching normal view proportions (8pt top + 34pt header + card + 10pt bottom).
                        IslandHeader(state: state)
                            .frame(width: islandWidth, height: 34)
                            .offset(y: 8)
                    }
                    .transition(
                        .asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.08)),
                            removal: .opacity.animation(.easeIn(duration: 0.12))
                        )
                    )
                } else {
                    IslandContentView(state: state)
                        .frame(width: islandWidth, height: islandHeight - earOffset)
                        .offset(y: earOffset)
                        .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                              cornerRadius: cornerRadius, topRadius: islandTopRadius))
                        .transition(
                            .asymmetric(
                                insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.08)),
                                removal: .opacity.animation(.easeIn(duration: 0.12))
                            )
                        )
                }
            }

            // Notch Live Activity: Rendered directly inside the notch body when active
            if let suggestion = state.proactiveSuggestion, state.mode != .expanded {
                NotchLiveActivityView(suggestion: suggestion, state: state, islandW: islandWidth, islandH: islandHeight)
                    .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                          cornerRadius: cornerRadius, topRadius: islandTopRadius))
                    .transition(.opacity)
            }

            // Single BotPlacement — always alive in the view tree so spring animations
            // fire from the current position (e.g. choose at 60,101) when canvas deactivates.
            // Hidden during upload canvas, greeting, or session history list.
            let hideBot = uploadActive || greetingActive || (state.mode == .expanded && state.view == .history)
            BotPlacement(state: state, islandW: islandWidth, islandH: islandHeight)
                // Keep idle animations inside the resting strip. Expanded views
                // retain the panel's full height for particles and hands.
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: islandWidth,
                                      height: state.mode == .expanded ? 320 : islandHeight)
                }
                .opacity(hideBot ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: hideBot)

            CountdownBar(state: state, islandW: islandWidth)

            // Compact mini grid for other tasks hidden per user preference for chat-only Coucou
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .topLeading)
        .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                               cornerRadius: cornerRadius, topRadius: islandTopRadius))
        .onChange(of: state.mode) { oldMode, newMode in
            let shrinking = modeOrder(newMode) < modeOrder(oldMode)
            let anim = shrinking ? closeEase : openSpring
            let (w, h) = islandSize(mode: newMode, view: state.view,
                                    progress: state.uploadProgress,
                                    hasProactiveSuggestion: state.proactiveSuggestion != nil,
                                    isLarge: state.isLargeExpanded,
                                    nw: state.notchWidth, nh: state.notchHeight)
            let cr  = newMode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            let tr: CGFloat = 0
            withAnimation(anim) {
                islandWidth      = w
                if newMode == .expanded {
                    islandHeight = (state.view == .prompt) ? chatPromptHeight : (state.view == .history ? (state.isLargeExpanded ? 480 : 280) : h)
                } else {
                    islandHeight = h
                }
                cornerRadius     = cr
                islandTopRadius  = tr
            }
        }
        .onChange(of: state.view) { _, newView in
            guard state.mode == .expanded else { return }
            // Deactivate engine if user navigates outside the upload flow
            let uploadViews: Set<IslandView> = [.upload, .uploading, .choose]
            if UploadSequenceEngine.shared.isActive && !uploadViews.contains(newView) {
                UploadSequenceEngine.shared.deactivate()
            }
            let (w, h) = islandSize(mode: .expanded, view: newView,
                                    progress: state.uploadProgress,
                                    hasProactiveSuggestion: state.proactiveSuggestion != nil,
                                    isLarge: state.isLargeExpanded,
                                    nw: state.notchWidth, nh: state.notchHeight)
            withAnimation(openSpring) {
                islandWidth  = w
                islandHeight = newView == .prompt ? chatPromptHeight : (newView == .history ? (state.isLargeExpanded ? 480 : 280) : h)
            }
        }
        .onChange(of: state.chatHistory.count) { _, _ in
            guard state.mode == .expanded, state.view == .prompt else { return }
            withAnimation(openSpring) { islandHeight = chatPromptHeight }
        }
        .onChange(of: state.isLargeExpanded) { _, isLarge in
            guard state.mode == .expanded else { return }
            let (w, h) = islandSize(mode: .expanded, view: state.view,
                                    progress: state.uploadProgress,
                                    hasProactiveSuggestion: state.proactiveSuggestion != nil,
                                    isLarge: isLarge,
                                    nw: state.notchWidth, nh: state.notchHeight)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                islandWidth  = w
                if state.view == .prompt {
                    islandHeight = chatPromptHeight
                } else if state.view == .history {
                    islandHeight = isLarge ? 480 : 280
                } else {
                    islandHeight = h
                }
            }
        }
        .onAppear {
            let (w, h) = islandSize(mode: state.mode, view: state.view,
                                    progress: state.uploadProgress,
                                    hasProactiveSuggestion: state.proactiveSuggestion != nil,
                                    isLarge: state.isLargeExpanded,
                                    nw: state.notchWidth, nh: state.notchHeight)
            islandWidth      = w
            if state.mode == .expanded {
                islandHeight = state.view == .prompt ? chatPromptHeight : (state.view == .history ? (state.isLargeExpanded ? 480 : 280) : h)
            } else {
                islandHeight = h
            }
            cornerRadius     = state.mode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            islandTopRadius  = 0
        }
        .onChange(of: state.proactiveSuggestion) { _, newSug in
            guard state.mode != .expanded else { return }
            let (w, h) = islandSize(mode: state.mode, view: state.view,
                                    progress: state.uploadProgress,
                                    hasProactiveSuggestion: newSug != nil,
                                    nw: state.notchWidth, nh: state.notchHeight)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
                islandWidth = w
                islandHeight = h
                cornerRadius = newSug != nil ? 18 : IslandConst.roundedCorner
            }
        }
    }

    private func modeOrder(_ m: IslandMode) -> Int {
        switch m { case .hidden: return 0; case .compact: return 1; case .expanded: return 2 }
    }
}

// MARK: - Island shape
//
// topRadius > 0  → convex rounded top corners (expanded mode)
// topRadius < 0  → concave ear cutouts, |topRadius| = ear radius (compact/notch mode)
// topRadius = 0  → sharp top corners (transient during animation)

struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat   // bottom corners
    var topRadius: CGFloat      // see above

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>, CGFloat> {
        get { .init(.init(.init(width, height), cornerRadius), topRadius) }
        set {
            width        = newValue.first.first.first
            height       = newValue.first.first.second
            cornerRadius = newValue.first.second
            topRadius    = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cr = max(0, cornerRadius)
        var p  = Path()

        if topRadius >= 0 {
            // ── Convex rounded top corners (expanded) ──────────────────────────
            let tr = min(topRadius, min(width / 2, height / 2))
            p.move(to: CGPoint(x: tr, y: 0))
            p.addLine(to: CGPoint(x: width - tr, y: 0))
            // Top-right convex corner
            p.addArc(center: CGPoint(x: width - tr, y: tr), radius: tr,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // Right edge
            p.addLine(to: CGPoint(x: width, y: height - cr))
            // Bottom-right corner
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            p.addLine(to: CGPoint(x: cr, y: height))
            // Bottom-left corner
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge
            p.addLine(to: CGPoint(x: 0, y: tr))
            // Top-left convex corner
            p.addArc(center: CGPoint(x: tr, y: tr), radius: tr,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            // ── Concave ear cutouts (compact / notch) ─────────────────────────
            let er = -topRadius   // positive ear radius
            p.move(to: CGPoint(x: 0, y: 0))
            // Top-left ear
            p.addArc(center: CGPoint(x: 0, y: er), radius: er,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // Top edge
            p.addLine(to: CGPoint(x: width - er, y: er))
            // Top-right ear
            p.addArc(center: CGPoint(x: width, y: er), radius: er,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            // Right edge
            p.addLine(to: CGPoint(x: width, y: height - cr))
            // Bottom-right corner
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            p.addLine(to: CGPoint(x: cr, y: height))
            // Bottom-left corner
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge back to top-left corner
            p.addLine(to: CGPoint(x: 0, y: 0))
        }

        p.closeSubpath()
        return p
    }
}

// MARK: - Bot placement helper

struct BotPlacement: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat

    var body: some View {
        let (cx, cy, diameter, opacity) = botPosition(mode: state.mode, view: state.view, islandW: islandW, islandH: islandH, uploadProgress: state.uploadProgress, hasNotch: state.hasNotch)
        let canvasSize = diameter / 0.6
        let overhang: CGFloat = 40
        let isUploading = state.view == .uploading

        Group {
            // No glow in uploading mode — the tiny dot doesn't need it
            if state.mode == .expanded && !isUploading {
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: botGlowColor(state.effectiveState), location: 0),
                            .init(color: .clear, location: 0.62)
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 1.1
                    ))
                    .frame(width: diameter * 2.2, height: diameter * 2.2)
                    .blur(radius: 6)
                    .opacity(botGlowOpacity(state.effectiveState))
                    .position(x: cx, y: cy)
                    .animation(.easeInOut(duration: 0.4), value: state.effectiveState)
            }

            // Uploading: no particle overhang (no hearts during upload), positioned directly at cy.
            // BotEngine cy = H/2 + 0 + oy*R + R*0.06 ≈ H/2 (body centered in canvas).
            // With .position(x:y:) placing the frame center at (uploadCx, cy), bot is at cy ✓.
            //
            // Normal: extra 40pt canvas at top for heart particles; position offset up by 20pt;
            // BotEngine compensates with cy = H/2 + particleOverhang/2 + oy*R + R*0.06.
            if isUploading {
                TimelineView(.animation) { tl in
                    let elapsed: Double = {
                        guard let start = state.uploadStartTime else { return 0 }
                        return tl.date.timeIntervalSince(start)
                    }()
                    let t = min(1.0, max(0, elapsed / state.uploadDuration))
                    // cx = 36 + 526*t: bot center at fill right edge (bar left=36, width=526)
                    let uploadCx = 36 + CGFloat(t * (2 - t)) * 526
                    BotCanvasView(state: state, particleOverhang: 0)
                        .frame(width: canvasSize, height: canvasSize)
                        .opacity(state.isDraggingBot ? 0 : opacity)
                        .position(x: uploadCx, y: cy)
                }
                .transition(.scale(scale: 0.01, anchor: .center).combined(with: .opacity))
            } else {
                BotCanvasView(state: state, particleOverhang: overhang)
                    .frame(width: canvasSize, height: canvasSize + overhang)
                    .opacity(state.isDraggingBot ? 0 : opacity)
                    .position(x: cx, y: cy - overhang / 2)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: cx)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: cy)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: canvasSize)
                    .transition(.scale(scale: 0.01, anchor: .center).combined(with: .opacity))
            }
        }
        // Branch switch (uploading ↔ normal) animates with a fast spring: uploading dot
        // scales out at bar-end while normal bot scales in at choose position.
        .animation(.spring(response: 0.36, dampingFraction: 0.72), value: isUploading)
        // Slap, drag, and hover are handled by the AppKit NSEvent monitor in
        // IslandWindowController — not SwiftUI gestures — so this is safe.
        .allowsHitTesting(false)
    }

    private func botGlowColor(_ s: BotState) -> Color {
        switch s {
        case .working:   return Color(hex: "#3B9EFF")
        case .thinking:  return Color(hex: "#A78BFA")
        case .searching: return Color(hex: "#6366F1")
        case .approval:  return Color(hex: "#F5A524")
        case .error:     return Color(hex: "#F4505E")
        case .finished:  return Color(hex: "#34D399")
        case .ratelimit: return Color(hex: "#F59E0B")
        default:         return Color.white
        }
    }

    private func botGlowOpacity(_ s: BotState) -> Double {
        switch s {
        case .idle, .sleeping: return 0.15
        case .dizzy:           return 0.0
        default:               return 0.65
        }
    }
}

func botPosition(mode: IslandMode, view: IslandView, islandW: CGFloat, islandH: CGFloat, uploadProgress: Double, hasNotch: Bool = true) -> (CGFloat, CGFloat, CGFloat, Double) {
    let resting = IslandRestingLayout(width: islandW, height: islandH)
    switch mode {
    case .hidden:
        return hasNotch ? (46, 16, 6, 0)
            : (islandW / 2, resting.botCenterY, resting.botDiameter, 1)
    case .compact:
        let isExtended = islandH > 50
        let botY = isExtended ? 16 : resting.botCenterY
        return (40, botY, resting.botDiameter, 1)
    case .expanded:
        if view == .history {
            return (0, 0, 0, 0)
        }
        let layout = IslandConst.viewLayouts[view]!
        let diameter = layout.botDiameter
        if diameter == 0 {
            return (0, 0, 0, 0)
        }
        // Uploading: Mochi dot rides the leading edge of the progress fill.
        // Bar in island coords: left=36, width=526. cx = 36 + progress*526 (dot center at fill right edge).
        // cy comes from ViewLayout.botY (bar center in island coords).
        if view == .uploading {
            let cx = 36 + CGFloat(uploadProgress) * 526
            return (cx, layout.botY ?? 103, diameter, 1)
        }
        let cx = layout.botX
        let cy: CGFloat
        if let fixedY = layout.botY {
            cy = fixedY
        } else {
            // Center of the fixed 84pt card (VStack top=8, header=34 → content starts at y=42)
            let headerBottom: CGFloat = 42
            let cardH: CGFloat = 84
            cy = headerBottom + (islandH - headerBottom - cardH) / 2 + cardH / 2
        }
        return (cx, cy, diameter, 1)
    }
}

// MARK: - Countdown bar

struct CountdownBar: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    @State private var barWidth: CGFloat = 0
    @State private var timer: Timer? = nil

    var body: some View {
        GeometryReader { _ in
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: barWidth, height: 2)
                .cornerRadius(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            updateBar()
        }
    }

    private func updateBar() {
        guard state.mode == .expanded && !state.isPinned else {
            barWidth = 0
            return
        }
        let autoClose = state.autoCloseInterval
        let window = min(10.0, autoClose * 0.6)
        let elapsed = Date.now.timeIntervalSince(state.lastActivity)
        let remaining = autoClose - elapsed
        if remaining < window {
            barWidth = max(0, CGFloat(remaining / window) * 160)
        } else {
            barWidth = 0
        }
    }
}

// MARK: - Island content (header + views, only in expanded mode)

struct IslandContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            IslandHeader(state: state)
                .frame(height: 34)
                .opacity(state.view == .confused ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: state.view == .confused)

            ZStack {
                ForEach(IslandView.allCases, id: \.self) { v in
                    let active = state.view == v
                    // Views that fill available height instead of the fixed 98pt content frame:
                    // chat (prompt) is always flexible; mail is flexible only when active so
                    // it doesn't push the ZStack taller when inactive.
                    let isTall = v == .prompt || v == .history || (v == .mail && active)
                    let anim: Animation = active
                        ? .spring(response: 0.4, dampingFraction: 0.8).delay(0.16)
                        : .easeIn(duration: 0.16)
                    IslandViewContent(view: v, state: state)
                        .frame(maxWidth: .infinity)
                        .frame(height: isTall ? nil : 98)
                        .frame(minHeight: (isTall && !active) ? 0 : nil, maxHeight: isTall ? .infinity : nil)
                        .opacity(active ? 1 : 0)
                        .scaleEffect(active ? 1 : 0.97)
                        .allowsHitTesting(active)
                        .animation(anim, value: state.view)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .foregroundColor(Color(hex: "#F5F6F8"))
    }
}

// MARK: - Island header (tabs + icons)

struct IslandHeader: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            // Left: Chat title & new chat button
            HStack(spacing: 8) {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        state.view = .prompt
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 11))
                        Text("Chat")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(state.view == .prompt ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(state.view == .prompt ? Color(hex: "#1D1F23") : Color.clear)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if !state.chatHistory.isEmpty {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            state.archiveCurrentSession()
                            state.chatHistory.removeAll()
                            state.currentSessionId = nil
                            state.promptContext = nil
                            state.dismissedContextKey = nil
                            ClaudeService.shared.clearConversation()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 11))
                            Text("New")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(Color(hex: "#8E939C"))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Start new conversation")
                }

                // Session History Tab Button
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        state.view = (state.view == .history) ? .prompt : .history
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: state.view == .history ? "clock.arrow.circlepath" : "clock")
                            .font(.system(size: 11))
                        Text("History")
                            .font(.system(size: 11))
                        if !state.sessions.isEmpty {
                            Text("\(state.sessions.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(state.view == .history ? Color(hex: "#F5F6F8") : Color(hex: "#A78BFA"))
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(state.view == .history ? Color.white.opacity(0.2) : Color(hex: "#A78BFA").opacity(0.18))
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundColor(state.view == .history ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(state.view == .history ? Color(hex: "#1D1F23") : Color.white.opacity(0.06))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Lịch sử phiên chat")
            }
            .padding(.leading, 14)

            Spacer()

            // Right: action icons (Expand toggle + Settings toggle + Sound toggle)
            HStack(spacing: 13) {
                // Expand / Restore button
                Button(action: {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        state.isLargeExpanded.toggle()
                    }
                    NotificationCenter.default.post(name: .botSquash, object: nil)
                    NotificationCenter.default.post(name: .triggerEmote, object: state.isLargeExpanded ? BotEmote.proud : BotEmote.happy)
                    if state.isLargeExpanded {
                        NotificationCenter.default.post(name: .botParticle, object: Particle.ParticleType.star)
                    }
                }) {
                    Image(systemName: state.isLargeExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(state.isLargeExpanded ? Color(hex: "#A78BFA") : Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                .help(state.isLargeExpanded ? "Thu nhỏ lại kích thước chuẩn" : "Mở rộng khung Coucou")

                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        state.view = (state.view == .settings) ? .prompt : .settings
                    }
                    NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.wink)
                }) {
                    Image(systemName: state.view == .settings ? "gearshape.fill" : "gearshape")
                        .font(.system(size: 14))
                        .foregroundColor(state.view == .settings ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                .help("Cài đặt")

                Button(action: { state.soundEnabled.toggle() }) {
                    Image(systemName: state.soundEnabled ? "speaker.wave.2" : "speaker.slash")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                .help(state.soundEnabled ? "Tắt âm thanh" : "Bật âm thanh")
            }
            .padding(.trailing, 16)
        }
        .frame(maxHeight: .infinity)
    }
}

struct TabButton: View {
    let icon: String
    let view: IslandView
    @ObservedObject var state: AppState
    var preAction: (() -> Void)? = nil
    @State private var isHovered = false

    private var isOn: Bool {
        if view == .overview { return state.view == .overview || state.view == .empty }
        return state.view == view
    }

    var body: some View {
        Button(action: {
            preAction?()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                state.view = view
            }
        }) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(isOn ? Color(hex: "#F5F6F8") : (isHovered ? Color(hex: "#B0B5BE") : Color(hex: "#8E939C")))
                .frame(width: 30, height: 22)
                .background(
                    isOn ? Color(hex: "#1D1F23") :
                    isHovered ? Color.white.opacity(0.07) : Color.clear
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact mini mochi grid (2×2 to the right of the notch)

struct CompactMiniGrid: View {
    @ObservedObject var state: AppState

    private var others: [AgentTask] {
        Array(state.tasks.filter { $0.id != state.focusId }.prefix(4))
    }

    var body: some View {
        let cols = [GridItem(.fixed(12), spacing: 4), GridItem(.fixed(12), spacing: 4)]
        LazyVGrid(columns: cols, spacing: 4) {
            ForEach(others) { task in
                MiniBotCanvasView(task: task)
                    .frame(width: 12 / 0.6, height: 12 / 0.6)
                    .frame(width: 12, height: 12, alignment: .center)
            }
        }
        .frame(width: 28, height: 28)
    }
}

// MARK: - Color helper

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let val = UInt64(h, radix: 16) ?? 0
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >> 8)  & 0xFF) / 255
        let b = Double( val        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
