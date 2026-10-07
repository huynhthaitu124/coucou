import SwiftUI

/// Top-level SwiftUI view rendered inside the 720×320 transparent panel.
/// The island is drawn at the top-center; everything else is transparent and click-through.
/// Note: drag-drop is handled at the AppKit level in IslandWindowController (FileDropNSView),
/// not in SwiftUI, to avoid interfering with SwiftUI hit-testing.
struct IslandRootView: View {
    @EnvironmentObject var state: AppState

    private var alignment: Alignment {
        switch state.coucouPosition {
        case .notch:       return .top
        case .topLeft:     return .topLeading
        case .topRight:    return .topTrailing
        case .leftEdge:    return .leading
        case .rightEdge:   return .trailing
        case .bottomLeft:  return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    private var paddingEdges: EdgeInsets {
        EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    }

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            IslandContainer(state: state)
                .padding(paddingEdges)
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: state.coucouPosition)
        .ignoresSafeArea()
    }
}

// MARK: - Suggestion Bottom Border Progress Bar (Runs inward towards center)

struct SuggestionProgressBar: View {
    var totalWidth: CGFloat? = nil
    let duration: TimeInterval
    var isPaused: Bool = false
    let onFinished: () -> Void

    @State private var progress: CGFloat = 1.0
    @State private var elapsed: TimeInterval = 0
    @State private var timerTask: Task<Void, Never>? = nil

    var body: some View {
        GeometryReader { geo in
            let barWidth = totalWidth ?? geo.size.width
            ZStack(alignment: .center) {
                // Subtle track line at bottom border
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: barWidth, height: 1.5)

                // Pure white glowing progress bar running gradually inward towards center
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.8),
                                Color.white,
                                Color.white.opacity(0.8)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, barWidth * progress), height: 2)
                    .shadow(color: Color.white.opacity(0.9), radius: 3, x: 0, y: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 2.5)
        .onAppear {
            startTimer()
        }
        .onDisappear {
            timerTask?.cancel()
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        let stepSeconds: TimeInterval = 0.025 // 40 FPS, silky smooth
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000)
                guard !Task.isCancelled else { break }
                if !isPaused {
                    elapsed += stepSeconds
                    let remaining = max(0.0, 1.0 - (elapsed / duration))
                    progress = CGFloat(remaining)
                    if remaining <= 0.001 {
                        onFinished()
                        break
                    }
                }
            }
        }
    }
}

// MARK: - Notch Live Activity View (Apple Dynamic Island style inside the Notch)

struct NotchLiveActivityView: View {
    let suggestion: ProactiveSuggestion
    @ObservedObject var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat

    @State private var isHovered = false

    /// Calculate the hardware camera notch dangerous area (MacBook notch height)
    private var safeAreaTop: CGFloat {
        if state.coucouPosition != .notch {
            return 6
        }
        return state.hasNotch ? max(state.notchHeight, 33) : max(state.notchHeight, 26)
    }

    var isVertical: Bool {
        state.coucouPosition == .leftEdge || state.coucouPosition == .rightEdge
    }

    var body: some View {
        Group {
            if isVertical {
                // Sleek Vertical Dynamic Island on Screen Edge (compact, no extra horizontal text)
                VStack(spacing: 8) {
                    // Top space reserved for bot (height 44)
                    Spacer().frame(height: 44)

                    // Spark indicator icon with suggestion tooltip
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#38BDF8"))
                        .frame(width: 24, height: 24)
                        .background(Color(hex: "#38BDF8").opacity(0.15))
                        .clipShape(Circle())
                        .help(suggestion.title + (suggestion.detail != nil ? ": \(suggestion.detail!)" : ""))

                    // Action button: glowing circle action
                    Button {
                        CoucouSentinel.shared.acceptSuggestion(suggestion, state: state)
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(hex: "#0B0C0E"))
                            .frame(width: 28, height: 28)
                            .background(
                                LinearGradient(
                                    colors: [Color.white, Color(hex: "#E5E7EB")],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .clipShape(Circle())
                            .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help("Thực hiện: \(suggestion.title)")
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
                    .help("Bỏ qua")

                    Spacer(minLength: 2)

                    // Progress bar at bottom
                    SuggestionProgressBar(
                        totalWidth: 24,
                        duration: 10.0,
                        isPaused: isHovered
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                            CoucouSentinel.shared.dismissSuggestion(state: state)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .frame(width: islandW, height: islandH, alignment: .top)
            } else {
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
                    .frame(height: 35)

                    Spacer(minLength: 0)

                    // White progress bar running gradually inward to center at bottom border
                    SuggestionProgressBar(
                        totalWidth: max(60, islandW - 28),
                        duration: 10.0,
                        isPaused: isHovered
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                            CoucouSentinel.shared.dismissSuggestion(state: state)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .frame(width: islandW, height: islandH, alignment: .top)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
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

    private let openSpring = Animation.spring(response: 0.46, dampingFraction: 0.76)
    private let closeEase  = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.30)

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
    /// Flush with screen top at all times.
    private var earOffset: CGFloat { 0 }

    private var stateAuraColor: Color {
        switch state.effectiveState {
        case .idle:      return Color(hex: "#38BDF8") // Signature Novra Grokbot electric cyan ambient aura
        case .working:   return Color(hex: "#0EA5E9")
        case .thinking:  return Color(hex: "#8B5CF6")
        case .approval:  return Color(hex: "#F59E0B")
        case .question:  return Color(hex: "#06B6D4")
        case .error:     return Color(hex: "#EF4444") // Warm coral-red bloom
        case .finished:  return Color(hex: "#10B981") // Mint emerald bloom
        case .dizzy:     return Color(hex: "#EC4899")
        case .ratelimit: return Color(hex: "#F97316")
        case .sleeping:  return Color(hex: "#64748B")
        case .searching: return Color(hex: "#6366F1")
        }
    }

    private var stateAuraOpacity: Double {
        switch state.effectiveState {
        case .idle:                           return 0.14 // Luminous cool cyan wash
        case .error:                          return 0.34 // Rich warm peach-red bloom like video frame 4
        case .working, .thinking, .searching: return 0.22
        case .approval, .question:            return 0.25
        case .finished, .dizzy:               return 0.24
        default:                              return 0.08
        }
    }

    private var cardBottomBloomOpacity: Double {
        switch state.effectiveState {
        case .error:                          return 0.48 // Vibrant warm coral-red bottom bloom matching video Frame 25 & 30
        case .idle:                           return 0.10 // Subtle ice-cyan floor wash
        case .working, .thinking, .searching: return 0.24
        case .approval, .question:            return 0.28
        case .finished, .dizzy:               return 0.26
        default:                              return 0.08
        }
    }

    private var earRadius: CGFloat {
        guard state.coucouPosition == .notch else { return 0 }
        return 20
    }

    private var virtualWidth: CGFloat {
        islandWidth + earRadius * 2
    }

    var body: some View {
        // greetingActive: GreetingCanvasView overlays the island with its own full-width layout.
        // Engine deactivates when user clicks a canvas choose button or navigates away.
        let uploadActive = state.mode == .expanded
            && UploadSequenceEngine.shared.isActive
            && (state.view == .upload || state.view == .uploading || state.view == .choose)

        let greetingActive = state.mode == .expanded && state.view == .greeting
        let earR = earRadius
        let vWidth = virtualWidth

        return ZStack(alignment: .topLeading) {
            // Layer 1: Deep OLED obsidian black base
            IslandShape(width: vWidth, height: islandHeight,
                        cornerRadius: cornerRadius, topRadius: islandTopRadius,
                        position: state.coucouPosition, earRadius: earR)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "#090A0D"),
                            Color(hex: "#050608")
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Layer 2: Precision hardware specular rim stroke (mirroring MacBook notch glass edge)
            IslandShape(width: vWidth, height: islandHeight,
                        cornerRadius: cornerRadius, topRadius: islandTopRadius,
                        position: state.coucouPosition, earRadius: earR)
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.18), location: 0.0),
                            .init(color: Color.white.opacity(0.08), location: 0.35),
                            .init(color: Color.white.opacity(0.03), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.85
                )

            // Content
            if state.mode == .expanded {
                if greetingActive {
                    // Greeting canvas: fixed 640-wide, centered by offset so x=320 aligns with island center
                    GreetingCanvasView(state: state)
                        .frame(width: IslandConst.expandedWidth, height: 150)
                        .offset(x: earR + (islandWidth - IslandConst.expandedWidth) / 2)
                        .clipShape(IslandShape(width: vWidth, height: islandHeight,
                                              cornerRadius: cornerRadius, topRadius: islandTopRadius,
                                              position: state.coucouPosition, earRadius: earR))
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
                            .offset(x: earR)
                            .clipShape(IslandShape(width: vWidth, height: islandHeight,
                                                  cornerRadius: cornerRadius, topRadius: islandTopRadius,
                                                  position: state.coucouPosition, earRadius: earR))
                        // Header overlaid: canvas CARD_Y=42 aligns exactly with header bottom,
                        // matching normal view proportions (8pt top + 34pt header + card + 10pt bottom).
                        IslandHeader(state: state)
                            .frame(width: islandWidth, height: 34)
                            .offset(x: earR, y: 8)
                    }
                    .transition(
                        .asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.08)),
                            removal: .opacity.animation(.easeIn(duration: 0.12))
                        )
                    )
                } else {
                    let expandedW = state.isLargeExpanded ? IslandConst.largeExpandedWidth : IslandConst.expandedWidth
                    let expandedH = (state.view == .prompt) ? chatPromptHeight : (state.view == .history ? (state.isLargeExpanded ? 480 : 280) : islandHeight)
                    IslandContentView(state: state)
                        .frame(width: expandedW, height: expandedH, alignment: .top)
                        .offset(x: earR + (islandWidth - expandedW) / 2)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                                    .animation(.spring(response: 0.46, dampingFraction: 0.82)),
                                removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .top))
                                    .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26))
                            )
                        )
                }
            }

            // Notch Live Activity: Rendered directly inside the notch body when active
            if let suggestion = state.proactiveSuggestion, state.mode != .expanded {
                NotchLiveActivityView(suggestion: suggestion, state: state, islandW: islandWidth, islandH: islandHeight)
                    .offset(x: earR)
                    .clipShape(IslandShape(width: vWidth, height: islandHeight,
                                          cornerRadius: cornerRadius, topRadius: islandTopRadius,
                                          position: state.coucouPosition, earRadius: earR))
                    .transition(.opacity)
            }

            // Single BotPlacement — always alive in the view tree so spring animations
            // fire from the current position (e.g. choose at 60,101) when canvas deactivates.
            // Hidden during upload canvas, greeting, or session history list.
            let hideBot = uploadActive || greetingActive || (state.mode == .expanded && state.view == .history)
            if state.mode == .expanded {
                BotPlacement(state: state, islandW: islandWidth, islandH: islandHeight)
                    .offset(x: earR)
                    // Retain panel height for particles and hands in expanded mode without clipping.
                    .mask(alignment: .topLeading) {
                        Rectangle().frame(width: vWidth, height: 600)
                    }
                    .opacity(hideBot ? 0 : 1)
                    .animation(.easeInOut(duration: 0.25), value: hideBot)
            } else {
                BotPlacement(state: state, islandW: islandWidth, islandH: islandHeight)
                    .offset(x: earR)
                    .opacity(hideBot ? 0 : 1)
                    .animation(.easeInOut(duration: 0.25), value: hideBot)
            }

            CountdownBar(state: state, islandW: islandWidth)
                .offset(x: earR)

            // Compact mini grid for other tasks hidden per user preference for chat-only Coucou
        }
        .frame(width: vWidth, height: islandHeight, alignment: .topLeading)
        .clipShape(IslandShape(width: vWidth, height: islandHeight,
                               cornerRadius: cornerRadius, topRadius: islandTopRadius,
                               position: state.coucouPosition, earRadius: earR))
        .onChange(of: state.mode) { oldMode, newMode in
            let shrinking = modeOrder(newMode) < modeOrder(oldMode)
            let anim = shrinking ? closeEase : openSpring
            let (w, h) = islandSize(mode: newMode, view: state.view,
                                    progress: state.uploadProgress,
                                    hasProactiveSuggestion: state.proactiveSuggestion != nil,
                                    isLarge: state.isLargeExpanded,
                                    nw: state.notchWidth, nh: state.notchHeight,
                                    position: state.coucouPosition)
            let cr  = newMode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            let tr: CGFloat = (state.coucouPosition == .notch) ? 0 : cr
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
        .onChange(of: state.coucouPosition) { _, newPos in
            let (w, h) = islandSize(mode: state.mode, view: state.view,
                                    progress: state.uploadProgress,
                                    hasProactiveSuggestion: state.proactiveSuggestion != nil,
                                    isLarge: state.isLargeExpanded,
                                    nw: state.notchWidth, nh: state.notchHeight,
                                    position: newPos)
            let cr = state.mode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                islandWidth = w
                islandHeight = (state.mode == .expanded && state.view == .prompt) ? chatPromptHeight : h
                cornerRadius = cr
                islandTopRadius = (newPos == .notch) ? 0 : cr
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
                                    nw: state.notchWidth, nh: state.notchHeight,
                                    position: state.coucouPosition)
            islandWidth      = w
            if state.mode == .expanded {
                islandHeight = state.view == .prompt ? chatPromptHeight : (state.view == .history ? (state.isLargeExpanded ? 480 : 280) : h)
            } else {
                islandHeight = h
            }
            cornerRadius     = state.mode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            islandTopRadius  = (state.coucouPosition == .notch) ? 0 : cornerRadius
        }
        .onChange(of: state.proactiveSuggestion) { _, newSug in
            guard state.mode != .expanded else { return }
            let (w, h) = islandSize(mode: state.mode, view: state.view,
                                    progress: state.uploadProgress,
                                    hasProactiveSuggestion: newSug != nil,
                                    nw: state.notchWidth, nh: state.notchHeight,
                                    position: state.coucouPosition)
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
    var position: CoucouPosition = .notch
    var earRadius: CGFloat = 0

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
        if position == .notch {
            let earR = max(0, earRadius)
            // Curvature of the 2 corners not touching the screen edge (bottom-left and bottom-right):
            // Smooth rounded bottom corners (18pt)
            let bottomR = min(max(0, cornerRadius), 18)
            var p  = Path()

            // 1. Top edge: from left ear tip (0, 0) to right ear tip (width, 0)
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: width, y: 0))

            // 2. Right ear: concave curve flaring from (width, 0) down to (width - earR, earR)
            if earR > 0 {
                p.addQuadCurve(to: CGPoint(x: width - earR, y: earR),
                               control: CGPoint(x: width - earR, y: 0))
            }

            // 3. Right edge
            p.addLine(to: CGPoint(x: width - earR, y: height - bottomR))

            // 4. Bottom-right convex corner
            if bottomR > 0 {
                p.addArc(center: CGPoint(x: width - earR - bottomR, y: height - bottomR), radius: bottomR,
                         startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            }

            // 5. Bottom edge
            p.addLine(to: CGPoint(x: earR + bottomR, y: height))

            // 6. Bottom-left convex corner
            if bottomR > 0 {
                p.addArc(center: CGPoint(x: earR + bottomR, y: height - bottomR), radius: bottomR,
                         startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            }

            // 7. Left edge
            p.addLine(to: CGPoint(x: earR, y: earR))

            // 8. Left ear: concave curve flaring from (earR, earR) up to (0, 0)
            if earR > 0 {
                p.addQuadCurve(to: CGPoint(x: 0, y: 0),
                               control: CGPoint(x: earR, y: 0))
            }

            p.closeSubpath()
            return p
        }

        // Non-notch corner & edge dock shapes:
        // Flush against screen edge (0 radius on touching edges),
        // smooth inward curves facing the workspace.
        let t = min(1.0, max(0.0, (width - 70) / 200)) // 0.0 when idle/compact, 1.0 when expanded
        let expR: CGFloat = IslandConst.expandedCorner // 24
        let idleInwardR: CGFloat = 18
        let tl: CGFloat
        let tr: CGFloat
        let bl: CGFloat
        let br: CGFloat

        switch position {
        case .topLeft:
            // Flush against Top (y=0) and Left (x=0) — ALWAYS 0, no gap against screen
            tl = 0
            tr = 0
            bl = 0
            br = idleInwardR + (expR - idleInwardR) * t
        case .topRight:
            // Flush against Top (y=0) and Right (x=width) — ALWAYS 0, no gap against screen
            tl = 0
            tr = 0
            bl = idleInwardR + (expR - idleInwardR) * t
            br = 0
        case .bottomLeft:
            // Flush against Bottom (y=height) and Left (x=0) — ALWAYS 0, no gap against screen
            tl = 0
            tr = idleInwardR + (expR - idleInwardR) * t
            bl = 0
            br = 0
        case .bottomRight:
            // Flush against Bottom (y=height) and Right (x=width) — ALWAYS 0, no gap against screen
            tl = idleInwardR + (expR - idleInwardR) * t
            tr = 0
            bl = 0
            br = 0
        case .leftEdge:
            // Flush against Left (x=0) — ALWAYS 0, no gap against screen
            tl = 0
            tr = idleInwardR + (expR - idleInwardR) * t
            bl = 0
            br = idleInwardR + (expR - idleInwardR) * t
        case .rightEdge:
            // Flush against Right (x=width) — ALWAYS 0, no gap against screen
            tl = idleInwardR + (expR - idleInwardR) * t
            tr = 0
            bl = idleInwardR + (expR - idleInwardR) * t
            br = 0
        case .notch:
            tl = 0
            tr = 0
            bl = 18 + (expR - 18) * t
            br = 18 + (expR - 18) * t
        }

        return unevenRoundedPath(width: width, height: height, tl: tl, tr: tr, bl: bl, br: br)
    }

    private func unevenRoundedPath(width: CGFloat, height: CGFloat, tl: CGFloat, tr: CGFloat, bl: CGFloat, br: CGFloat) -> Path {
        let maxR = min(width / 2, height / 2)
        let ctl = max(0, min(tl, maxR))
        let ctr = max(0, min(tr, maxR))
        let cbl = max(0, min(bl, maxR))
        let cbr = max(0, min(br, maxR))

        var p = Path()
        p.move(to: CGPoint(x: ctl, y: 0))
        p.addLine(to: CGPoint(x: width - ctr, y: 0))
        if ctr > 0 {
            p.addArc(center: CGPoint(x: width - ctr, y: ctr), radius: ctr,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        } else {
            p.addLine(to: CGPoint(x: width, y: 0))
        }

        p.addLine(to: CGPoint(x: width, y: height - cbr))
        if cbr > 0 {
            p.addArc(center: CGPoint(x: width - cbr, y: height - cbr), radius: cbr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        } else {
            p.addLine(to: CGPoint(x: width, y: height))
        }

        p.addLine(to: CGPoint(x: cbl, y: height))
        if cbl > 0 {
            p.addArc(center: CGPoint(x: cbl, y: height - cbl), radius: cbl,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        } else {
            p.addLine(to: CGPoint(x: 0, y: height))
        }

        p.addLine(to: CGPoint(x: 0, y: ctl))
        if ctl > 0 {
            p.addArc(center: CGPoint(x: ctl, y: ctl), radius: ctl,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
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
        let (cx, cy, diameter, opacity) = botPosition(mode: state.mode, view: state.view, islandW: islandW, islandH: islandH, uploadProgress: state.uploadProgress, hasNotch: state.hasNotch, position: state.coucouPosition)
        let canvasSize = diameter / 0.6
        let overhang: CGFloat = state.mode == .expanded ? 40 : 0
        let isUploading = state.view == .uploading

        Group {
            // Uploading: no particle overhang (no hearts during upload), positioned directly at cy.
            // BotEngine cy = H/2 + 0 + oy*R + R*0.06 ≈ H/2 (body centered in canvas).
            // With .position(x:y:) placing the frame center at (uploadCx, cy), bot is at cy ✓.
            //
            // Normal: extra 40pt canvas at top for heart particles in expanded mode;
            // In compact mode: overhang is 0, canvas is centered cleanly at (cx, cy).
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
                let shrinking = state.mode == .hidden || state.mode == .compact
                let botAnim: Animation = shrinking
                    ? .timingCurve(0.4, 0, 0.2, 1, duration: 0.30)
                    : .spring(response: 0.46, dampingFraction: 0.76)
                BotCanvasView(state: state, particleOverhang: overhang)
                    .frame(width: canvasSize, height: canvasSize + overhang)
                    .opacity(state.isDraggingBot ? 0 : opacity)
                    .position(x: cx, y: cy - overhang / 2)
                    .animation(botAnim, value: cx)
                    .animation(botAnim, value: cy)
                    .animation(botAnim, value: canvasSize)
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
        case .idle:      return Color(hex: "#38BDF8") // Electric Cyan
        case .working:   return Color(hex: "#0EA5E9")
        case .thinking:  return Color(hex: "#A855F7") // Vibrant Violet
        case .searching: return Color(hex: "#6366F1")
        case .approval:  return Color(hex: "#F5A524")
        case .error:     return Color(hex: "#EF4444") // Coral Red
        case .finished:  return Color(hex: "#10B981") // Mint Green
        case .ratelimit: return Color(hex: "#F59E0B")
        default:         return Color(hex: "#38BDF8")
        }
    }

    private func botGlowOpacity(_ s: BotState) -> Double {
        switch s {
        case .idle:            return 0.38
        case .sleeping:        return 0.16
        case .dizzy:           return 0.0
        case .error:           return 0.55
        case .thinking:        return 0.48
        case .finished:        return 0.46
        default:               return 0.45
        }
    }
}

@MainActor
func botPosition(mode: IslandMode, view: IslandView, islandW: CGFloat, islandH: CGFloat, uploadProgress: Double, hasNotch: Bool = true, position: CoucouPosition = AppState.shared.coucouPosition) -> (CGFloat, CGFloat, CGFloat, Double) {
    let resting = IslandRestingLayout(width: islandW, height: islandH)
    switch mode {
    case .hidden:
        if position == .notch {
            return hasNotch ? (46, 16, 6, 0)
                : (islandW / 2, resting.botCenterY, resting.botDiameter, 1)
        } else if position == .leftEdge || position == .rightEdge {
            let botY: CGFloat = islandH > 70 ? 26 : islandH / 2
            return (islandW / 2, botY, 26, 1.0)
        } else {
            return (islandW / 2, islandH / 2, 26, 1.0)
        }
    case .compact:
        if position == .notch {
            let isExtended = islandH > 50
            let botY = isExtended ? 16 : resting.botCenterY
            return (40, botY, resting.botDiameter, 1)
        } else if position == .leftEdge || position == .rightEdge {
            let botY: CGFloat = islandH > 70 ? 26 : islandH / 2
            return (islandW / 2, botY, 26, 1.0)
        } else {
            return (islandW / 2, islandH / 2, 26, 1.0)
        }
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
        if view == .prompt || view == .searching || view == .result {
            // Chat prompt: Coucou sits at center-left of the card
            if islandH > 320 {
                cy = 136
            } else {
                cy = 98
            }
        } else if let fixedY = layout.botY {
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

            let headerGap: CGFloat = (state.view == .settings) ? 10 : 0
            if headerGap > 0 {
                Spacer().frame(height: headerGap)
            }

            ZStack(alignment: .top) {
                let isTall = state.view == .prompt || state.view == .history || state.view == .mail || state.view == .settings
                IslandViewContent(view: state.view, state: state)
                    .frame(maxWidth: .infinity)
                    .frame(height: isTall ? nil : 98)
                    .id(state.view)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 10)
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: state.view)
        }
        .padding(.top, 8)
        .padding(.bottom, state.view == .settings ? 12 : 10)
        .foregroundColor(Color(hex: "#F5F6F8"))
    }
}

// MARK: - Island header (tabs + icons)

struct IslandHeader: View {
    @ObservedObject var state: AppState
    @State private var copiedChat: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Left: Chat title & copy button (safely left of physical notch)
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
                    // New session button (safely left of physical notch)
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            state.archiveCurrentSession()
                            state.chatHistory.removeAll()
                            state.currentSessionId = nil
                            state.promptContext = nil
                            state.dismissedContextKey = nil
                            ClaudeService.shared.clearConversation()
                            UserDefaults.standard.set(true, forKey: "explicitNewSession")
                            UserDefaults.standard.removeObject(forKey: "savedActiveSessionId")
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
                    .help("Bắt đầu phiên chat mới")

                    // Copy full chat button
                    Button(action: {
                        state.copyFullConversationToClipboard()
                        copiedChat = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            copiedChat = false
                        }
                    }) {
                        HStack(spacing: 3.5) {
                            Image(systemName: copiedChat ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(copiedChat ? "Đã copy" : "Copy")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(copiedChat ? Color(hex: "#10B981") : Color(hex: "#8E939C"))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Sao chép toàn bộ cuộc trò chuyện vào Clipboard")
                }
            }
            .padding(.leading, 14)

            Spacer()

            // Right: Session History (safely right of physical notch) + Window controls
            HStack(spacing: 9) {

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

                // Subtle divider
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 13)
                    .padding(.horizontal, 2)

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
