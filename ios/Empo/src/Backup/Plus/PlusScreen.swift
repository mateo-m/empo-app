import AuthenticationServices
import GameProbe
import SwiftUI

struct PlusScreen: View {

    private let plus = EmpoPlus.shared

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing._3xl) {
                PlusOrbit(isMember: stage == .member).padding(.top, Spacing.lg)
                headline.padding(.horizontal, Spacing._3xl)
                places
            }
            .padding(.bottom, Spacing._3xl)
        }
        .background(Color(.systemGroupedBackground))
        // `safeAreaBar` gives the system scroll edge blur, so the page
        // shows through and the buttons stay legible over content.
        .safeAreaBar(edge: .bottom) {
            buttons
                .padding(.horizontal, Spacing._2xl)
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.md)
        }
        .overlay {
            if isWorking { ProgressView() }
        }
        .navigationTitle("Empo Plus")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                EmpoPlusName().font(.headline).accessibilityAddTraits(.isHeader)
            }
        }
        .task { await plus.renew() }
    }

    private var stage: PlusStage {
        if plus.hasPlus { return .member }
        if plus.isSignedIn { return .notYet }
        return .join
    }

    private var headline: some View {
        VStack(spacing: Spacing.md) {
            stage.headline.font(.title.weight(.bold))
            stage.detail.font(.body).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .plusShine()
    }

    private var places: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(spacing: 0) {
                ForEach(Array(plusPlaces.enumerated()), id: \.offset) { index, service in
                    if index > 0 { Divider().padding(.leading, 56) }
                    placeRow(service)
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: Radius.lg))
            Text("Restore is always free, also after a membership ends.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xl)
        }
        .padding(.horizontal, Spacing.xl)
    }

    private func placeRow(_ service: BackupProviderKind) -> some View {
        HStack(spacing: Spacing.lg) {
            ServiceMark(service: service, size: 24)
                .frame(width: 28)
            Text(placeTitle(service)).font(.body)
            Spacer()
            Group {
                if service == .iCloudDrive {
                    Text("Free").foregroundStyle(.secondary)
                } else if stage == .member {
                    Image(systemName: "checkmark").foregroundStyle(.brand)
                } else {
                    PlusBadge()
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
    }

    private var buttons: some View {
        VStack(spacing: Spacing.lg) {
            switch stage {
            case .join:
                if UpdateChecker.isSideloadBuild {
                    primary("Join on Patreon") { openURL(EmpoPlus.joinURL) }
                    secondary("Already a member? Sign in") { Task { await signIn() } }
                } else {
                    primary("Sign in with Patreon") { Task { await signIn() } }
                }
            case .notYet:
                if UpdateChecker.isSideloadBuild {
                    primary("Join on Patreon") { openURL(EmpoPlus.joinURL) }
                }
                secondary("Check again") { Task { await checkAgain() } }
                quiet("Sign out of Patreon") { plus.signOut() }
            case .member:
                quiet("Sign out of Patreon") { plus.signOut() }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.destructive)
            }
        }
        .disabled(isWorking)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.primary)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.brand)
    }

    private func quiet(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func signIn() async {
        isWorking = true
        defer { isWorking = false }
        failure = nil
        do throws(EmpoPlus.SignInFailure) {
            try await plus.signIn(using: webAuthenticationSession)
        } catch {
            if error == .server { failure = "Couldn't sign in with Patreon. Try again." }
        }
    }

    private func checkAgain() async {
        isWorking = true
        defer { isWorking = false }
        await plus.renew(force: true)
    }
}

/// The Plus screen in its own sheet, for the places that are not a
/// navigation stack.
struct PlusSheet: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PlusScreen()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

private enum PlusStage {
    case join, notYet, member

    var headline: Text {
        switch self {
        case .member: Text("You have Empo \(plusWord)")
        case .notYet: Text("Your Patreon account isn't a member yet")
        case .join: Text("Keep your saves in more places")
        }
    }

    var detail: Text {
        switch self {
        case .member: Text("Add Dropbox, Google Drive, or your own server in Backups.")
        case .notYet: Text("Join on Patreon, then tap Check again.")
        case .join:
            Text("iCloud Drive stays free. \(plusWord) adds Dropbox, Google Drive, and your own server.")
        }
    }
}

private let plusPlaces: [BackupProviderKind] = [.iCloudDrive, .dropbox, .googleDrive, .s3, .webdav]

private func placeTitle(_ service: BackupProviderKind) -> String {
    switch service {
    case .s3: "S3 storage"
    case .webdav: "WebDAV server"
    default: service.serviceName
    }
}

/// Empo in the middle, with the places a save can go on a ring
/// around it.
private struct PlusOrbit: View {
    let isMember: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var launches = 0
    @State private var spin = 0.0

    private let radius: CGFloat = 118

    var body: some View {
        ZStack {
            // One ripple leaves the icon as the first place comes out.
            Circle()
                .stroke(Color.brand, lineWidth: 2)
                .frame(width: radius * 2, height: radius * 2)
                .scaleEffect(entered ? 1 : 0.4)
                .opacity(entered || reduceMotion ? 0 : 0.6)
                .animation(reduceMotion ? nil : reach(1.1).delay(0.1), value: entered)
            Circle()
                .trim(from: 0, to: entered || reduceMotion ? 1 : 0)
                .stroke(
                    Color.brand.opacity(isMember ? 0.7 : Alpha.indicatorStroke),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 6])
                )
                .rotationEffect(.degrees(-90 + spin))
                .frame(width: radius * 2, height: radius * 2)
                .scaleEffect(entered || reduceMotion ? 1 : 0.5)
                .animation(reduceMotion ? nil : reach(0.9), value: entered)
                .animation(Motion.slow, value: isMember)
            ForEach(Array(plusPlaces.enumerated()), id: \.offset) { index, service in
                place(service, index: index)
            }
            center
        }
        .frame(height: 290)
        .accessibilityHidden(true)
        .task { await play() }
    }

    private func play() async {
        entered = true
        guard !reduceMotion else { return }
        var elapsed = 0.0
        for index in plusPlaces.indices {
            let start = 0.1 + dealt(index)
            try? await Task.sleep(for: .seconds(start - elapsed))
            elapsed = start
            launches += 1
        }
        try? await Task.sleep(for: .seconds(0.9))
        withAnimation(.linear(duration: 60).repeatForever(autoreverses: false)) { spin = 360 }
    }

    // Each place comes out from under the icon and swings out on a
    // curve to its spot on the ring.
    private func place(_ service: BackupProviderKind, index: Int) -> some View {
        let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(plusPlaces.count)
        let unlocked = service == .iCloudDrive || isMember
        return ServiceMark(service: service, size: 30, flat: !unlocked)
            // The page color hides the ring behind the logo.
            .frame(width: 52, height: 52)
            .background(Color(.systemGroupedBackground), in: .circle)
            .overlay(alignment: .bottomTrailing) {
                LockBadge()
                    .scaleEffect(entered && !unlocked ? 1 : 0.4)
                    .opacity(entered && !unlocked ? 1 : 0)
                    .animation(
                        reduceMotion ? nil : Motion.standard.delay(0.55 + dealt(index)), value: entered
                    )
                    .animation(Motion.standard, value: isMember)
            }
            .modifier(
                ArcEntrance(
                    progress: entered || reduceMotion ? 1 : 0,
                    end: CGSize(width: cos(angle) * radius, height: sin(angle) * radius))
            )
            .animation(
                reduceMotion
                    ? .easeOut(duration: Motion.durationNormal) : reach(0.8).delay(0.1 + dealt(index)),
                value: entered
            )
            // A sign-in colors the locked places in, one by one.
            .animation(Motion.slow.delay(dealt(index)), value: isMember)
    }

    // The icon lands first, then gives a small push as each place
    // leaves it.
    private var center: some View {
        // iOS does not load an app icon set as an image, so
        // `EmpoAppIcon` is a smaller copy of `AppIcon`.
        Image(.empoAppIcon)
            .resizable().scaledToFit()
            .frame(width: 96, height: 96)
            .clipShape(.rect(cornerRadius: 96 * 0.225, style: .continuous))
            .plusShine(over: .rect(cornerRadius: 96 * 0.225, style: .continuous))
            .cardShadow()
            .keyframeAnimator(initialValue: 1.0, trigger: launches) { icon, scale in
                icon.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(0.93, duration: 0.07, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
            }
            .scaleEffect(entered || reduceMotion ? 1 : 0.6)
            .rotationEffect(.degrees(entered || reduceMotion ? 0 : -12))
            .blur(radius: entered || reduceMotion ? 0 : 6)
            .opacity(entered || reduceMotion ? 1 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6), value: entered)
    }
}

/// A service logo with no shape behind it. A flat logo is one tone,
/// so every service has the same weight.
private struct ServiceMark: View {
    let service: BackupProviderKind
    var size: CGFloat = 24
    var flat = false

    var body: some View {
        ZStack {
            logo(template: true).foregroundStyle(.secondary).opacity(flat ? 1 : 0)
            logo(template: false).foregroundStyle(.brand).opacity(flat ? 0 : 1)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private func logo(template: Bool) -> some View {
        if let mark = service.markName {
            Image(mark)
                .renderingMode(template ? .template : .original)
                .resizable().scaledToFit()
        } else {
            Image(systemName: service.symbolName)
                .resizable().scaledToFit()
                .symbolVariant(.fill)
                .fontWeight(.semibold)
        }
    }
}

private struct LockBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Color.brand, in: .circle)
    }
}

/// A slow start, a fast middle, and a long soft stop: the bell-shaped
/// speed of a human reach (the minimum-jerk curve).
private func reach(_ duration: Double) -> Animation {
    .timingCurve(0.45, 0, 0.15, 1, duration: duration)
}

/// The start time of item `index`. Each gap is 80% of the gap before,
/// as a hand that deals cards gets faster.
private func dealt(_ index: Int, gap: Double = 0.09) -> Double {
    (0..<index).reduce(0) { total, step in total + gap * pow(0.8, Double(step)) }
}

/// Moves a view to `end` on a curve, not on a straight line, and
/// brings it into focus on the way.
private struct ArcEntrance: ViewModifier, Animatable {
    var progress: Double
    let end: CGSize
    var bend: CGFloat = 24
    var blur: CGFloat = 8
    var startScale: CGFloat = 0.5

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = CGFloat(progress)
        let length = max(hypot(end.width, end.height), 1)
        let lift = sin(p * .pi) * bend
        content
            .scaleEffect(startScale + (1 - startScale) * p)
            .blur(radius: (1 - p) * blur)
            .opacity(min(1, progress * 2.5))
            .offset(
                x: end.width * p - end.height / length * lift,
                y: end.height * p + end.width / length * lift)
    }
}

struct PlusBadge: View {
    var body: some View {
        // A Label moves the row separator of a List row to its own text.
        HStack(spacing: Spacing.xs) {
            Image(systemName: "lock.fill").foregroundStyle(.brand)
            PlusWord()
        }
    }
}

/// "Empo Plus", with "Plus" as its own mark.
struct EmpoPlusName: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: "Empo ")
            PlusWord()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Empo Plus")
    }
}

/// "Plus" in bold brand orange, on its own.
struct PlusWord: View {
    var body: some View {
        plusWord.plusShine()
    }
}

/// "Plus" in bold brand orange, to put inside a sentence or a title.
/// Give the view that holds the text `.plusShine()` for the light.
/// Not for a button title: orange on an orange button cannot be read.
let plusWord = Text(verbatim: "Plus").fontWeight(.bold).foregroundStyle(.brand)
    .customAttribute(PlusMark())

private struct PlusMark: TextAttribute {}

extension View {
    /// A light passes once over each "Plus" in the text of this view
    /// when it comes on screen.
    func plusShine() -> some View { modifier(PlusShine(shape: nil)) }

    /// The light of `plusShine()`, over the whole view in `shape`. For a
    /// button with a white title, which would hide the light, and for the
    /// app icon.
    func plusShine(over shape: some Shape) -> some View { modifier(PlusShine(shape: AnyShape(shape))) }
}

private struct PlusShine: ViewModifier {
    let shape: AnyShape?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0.0

    func body(content: Content) -> some View {
        let phase = reduceMotion ? 0 : phase
        Group {
            if let shape {
                content.modifier(PlusGlint(phase: phase, shape: shape))
            } else {
                content.textRenderer(PlusShineRenderer(phase: phase))
            }
        }
        .onAppear {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { self.phase = 0 }
            withAnimation(.easeInOut(duration: 0.9).delay(0.35)) { self.phase = 1 }
        }
    }
}

/// A tilted light band that crosses `rect` from top left to bottom right.
/// At phase 0 the whole band is before the rect, and at phase 1 the
/// whole band is past it, so no light stays on a corner.
private enum PlusBand {
    static let gradient = Gradient(colors: [.white.opacity(0), .white.opacity(0.5), .white.opacity(0)])
    private static let direction = CGVector(
        dx: cos(Angle.degrees(22).radians), dy: sin(Angle.degrees(22).radians))

    static func ends(in rect: CGRect, phase: Double) -> (start: CGPoint, end: CGPoint) {
        let width = rect.width * 0.6
        let first = along(CGPoint(x: rect.minX, y: rect.minY))
        let last = along(CGPoint(x: rect.maxX, y: rect.maxY))
        let start = first - width + (last - first + width) * phase
        return (point(at: start), point(at: start + width))
    }

    private static func along(_ point: CGPoint) -> Double {
        point.x * direction.dx + point.y * direction.dy
    }

    private static func point(at distance: Double) -> CGPoint {
        CGPoint(x: distance * direction.dx, y: distance * direction.dy)
    }
}

/// Draws the text, then the light band over the "Plus" runs only.
private struct PlusShineRenderer: TextRenderer, Animatable {
    var phase: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard run[PlusMark.self] != nil else {
                    context.draw(run)
                    continue
                }
                context.drawLayer { layer in
                    layer.draw(run)
                    let bounds = run.typographicBounds.rect
                    let band = PlusBand.ends(in: bounds, phase: phase)
                    // Paints only where the run already drew glyphs.
                    layer.blendMode = .sourceAtop
                    layer.fill(
                        Path(bounds),
                        with: .linearGradient(PlusBand.gradient, startPoint: band.start, endPoint: band.end))
                }
            }
        }
    }
}

/// A plain overlay whose gradient points change with the state did not
/// animate on the location screen.
private struct PlusGlint: ViewModifier, Animatable {
    var phase: Double
    let shape: AnyShape
    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                let size = CGSize(width: max(proxy.size.width, 1), height: max(proxy.size.height, 1))
                let band = PlusBand.ends(in: CGRect(origin: .zero, size: size), phase: phase)
                LinearGradient(
                    gradient: PlusBand.gradient,
                    startPoint: UnitPoint(x: band.start.x / size.width, y: band.start.y / size.height),
                    endPoint: UnitPoint(x: band.end.x / size.width, y: band.end.y / size.height))
            }
            .clipShape(shape)
            .allowsHitTesting(false)
        }
    }
}
