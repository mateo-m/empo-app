import AuthenticationServices
import GameProbe
import StoreKit
import SwiftUI

struct PlusScreen: View {

    private let plus = EmpoPlus.shared
    private let store = PlusStore.shared

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL
    @State private var isWorking = false
    @State private var failure: Failure?
    @State private var managesSubscription = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing._3xl) {
                PlusOrbit(isMember: plus.hasPlus).padding(.top, Spacing.lg)
                headline.padding(.horizontal, Spacing._3xl)
                places
                if offersSubscription {
                    quiet(String(localized: "Restore purchase")) { Task { await restore() } }
                }
            }
            .padding(.bottom, Spacing._3xl)
        }
        .background(Color(.systemGroupedBackground))
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .safeAreaBar(edge: .bottom) {
            buttons
                .padding(.horizontal, Spacing._2xl)
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.md)
        }
        .overlay {
            if isWorking { ProgressView().accessibilityLabel("Loading") }
        }
        .manageSubscriptionsSheet(isPresented: $managesSubscription)
        .task {
            guard sellsSubscription else { return }
            await store.loadProduct()
            await store.refresh()
        }
        .navigationTitle("Empo Plus")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Empo \(plusWord)").font(.headline).plusShine().accessibilityAddTraits(.isHeader)
            }
        }
    }

    // The GitHub build has no App Store to sell through.
    private var sellsSubscription: Bool { !UpdateChecker.isSideloadBuild }

    private var stage: PlusStage {
        if store.isSubscribed { return .member }
        switch (plus.isSignedIn, plus.pass) {
        case (true, let pass?) where pass.grantsPlus(at: .now): return .member
        case (true, let pass?) where pass.includesPlus: return .expired
        case (true, _): return .notYet
        case (false, let pass?) where pass.grantsPlus(at: .now): return .signInAgain(until: pass.expiresAt)
        case (false, _): return .join
        }
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
            Text("Restoring your saves stays free, also after Plus ends.")
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
                } else if plus.hasPlus {
                    Image(systemName: "checkmark").foregroundStyle(.brand)
                        .accessibilityLabel("Included")
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
        VStack(spacing: Spacing.md) {
            switch stage {
            case .join:
                if UpdateChecker.isSideloadBuild {
                    primary(String(localized: "Join on Patreon")) { openURL(EmpoPlus.joinURL) }
                    secondary(String(localized: "Already a member? Sign in")) { Task { await signIn() } }
                } else {
                    subscribe
                    Button {
                        Task { await signIn() }
                    } label: {
                        Text("Sign in with Patreon").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondary)
                }
            case .notYet:
                if UpdateChecker.isSideloadBuild {
                    primary(String(localized: "Join on Patreon")) { openURL(EmpoPlus.joinURL) }
                } else {
                    subscribe
                }
                secondary(String(localized: "Check again")) { Task { await checkAgain() } }
                quiet(String(localized: "Sign out of Patreon")) { plus.signOut() }
            case .expired:
                primary(String(localized: "Check again")) { Task { await checkAgain() } }
                quiet(String(localized: "Sign out of Patreon")) { plus.signOut() }
            case .signInAgain:
                primary("Sign in with Patreon") { Task { await signIn() } }
            case .member:
                if store.isSubscribed {
                    quiet(String(localized: "Manage subscription")) { managesSubscription = true }
                }
                if plus.isSignedIn {
                    quiet(String(localized: "Sign out of Patreon")) { plus.signOut() }
                }
            }
            if let failure {
                Label(failure.line, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.destructive)
            }
            if failure == .tooManyDevices {
                secondary(String(localized: "Sign out other devices")) {
                    Task { await signIn(replace: true) }
                }
            }
            if offersSubscription { subscriptionTerms }
        }
        .disabled(isWorking)
    }

    private var subscribe: some View {
        primary(
            store.product.map { String(localized: "Subscribe for \($0.displayPrice) a month") }
                ?? String(localized: "Subscribe")
        ) {
            Task { await purchase() }
        }
    }

    private var offersSubscription: Bool {
        sellsSubscription && !store.isSubscribed && stage.offersSubscription
    }

    // App Review asks for the renewal terms and both links next to the
    // purchase button.
    private var subscriptionTerms: some View {
        Text(
            AttributedString(localized: "Renews every month until you cancel.") + " "
                + link("Terms", to: EmpoLink.terms) + " · " + link("Privacy", to: EmpoLink.privacy)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .tint(.brand)
        .multilineTextAlignment(.center)
    }

    private func link(_ title: String.LocalizationValue, to url: URL) -> AttributedString {
        var text = AttributedString(localized: title)
        text.link = url
        return text
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

    private func signIn(replace: Bool = false) async {
        isWorking = true
        defer { isWorking = false }
        failure = nil
        do throws(EmpoPlus.SignInFailure) {
            try await plus.signIn(using: webAuthenticationSession, replace: replace)
        } catch {
            switch error {
            case .cancelled: break
            case .server: failure = .line(String(localized: "Couldn't sign in with Patreon. Try again."))
            case .tooManyDevices: failure = .tooManyDevices
            case .notSaved:
                failure = .line(
                    String(localized: "Empo couldn't save the sign-in on this device. Try again."))
            }
        }
    }

    private func purchase() async {
        isWorking = true
        defer { isWorking = false }
        failure = nil
        await store.loadProduct()
        do throws(PlusStore.PurchaseFailure) {
            try await store.purchase()
        } catch {
            switch error {
            case .cancelled: break
            case .pending: failure = .line(String(localized: "Your purchase is waiting for approval."))
            case .failed: failure = .line(String(localized: "Couldn't reach the App Store. Try again."))
            }
        }
    }

    private func restore() async {
        isWorking = true
        defer { isWorking = false }
        failure = nil
        if await !store.restore() {
            failure = .line(String(localized: "Couldn't reach the App Store. Try again."))
        } else if !store.isSubscribed {
            failure = .line(String(localized: "No Empo Plus purchase on this Apple Account."))
        }
    }

    private func checkAgain() async {
        isWorking = true
        defer { isWorking = false }
        failure = nil
        if await !plus.renew(force: true) {
            failure = .line(String(localized: "Couldn't check your membership. Try again."))
        }
    }

    private enum Failure: Equatable {
        case line(String)
        case tooManyDevices

        var line: String {
            switch self {
            case .line(let line): line
            case .tooManyDevices: String(localized: "Empo Plus works on up to 3 devices at a time.")
            }
        }
    }
}

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
    case join, notYet, expired
    case signInAgain(until: Date)
    case member

    var offersSubscription: Bool {
        switch self {
        case .join, .notYet: true
        default: false
        }
    }

    var headline: Text {
        switch self {
        case .member: Text("Thank you for supporting Empo")
        case .notYet: Text("Your Patreon account isn't a member yet")
        case .expired: Text("Empo couldn't check your membership")
        case .signInAgain: Text("Sign in to Patreon again")
        case .join: Text("Keep your saves in more places")
        }
    }

    var detail: Text {
        switch self {
        case .member:
            Text("You have Empo \(plusWord).\nAdd Dropbox, Google Drive, or your own server in Backups.")
        case .notYet: Text("Join on Patreon, then tap Check again.")
        case .expired: Text("Connect to the internet, then tap Check again.")
        case .signInAgain(let date):
            Text(
                "\(plusWord) stays on until \(date.formatted(date: .abbreviated, time: .omitted)). Sign in to keep it."
            )
        case .join:
            Text("iCloud Drive stays free. \(plusWord) adds Dropbox, Google Drive, and your own server.")
        }
    }
}

private let plusPlaces: [BackupProviderKind] = [.iCloudDrive, .dropbox, .googleDrive, .s3, .webdav]

private func placeTitle(_ service: BackupProviderKind) -> String {
    switch service {
    case .s3: String(localized: "S3 storage")
    case .webdav: String(localized: "WebDAV server")
    default: service.serviceName
    }
}

private struct PlusOrbit: View {
    let isMember: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var launches = 0
    @State private var spin = 0.0

    private let radius: CGFloat = 118

    var body: some View {
        ZStack {
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
            .animation(Motion.slow.delay(dealt(index)), value: isMember)
    }

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

private func reach(_ duration: Double) -> Animation {
    .timingCurve(0.45, 0, 0.15, 1, duration: duration)
}

/// Each gap is 80% of the gap before.
private func dealt(_ index: Int, gap: Double = 0.09) -> Double {
    (0..<index).reduce(0) { total, step in total + gap * pow(0.8, Double(step)) }
}

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
