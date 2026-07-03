import AppKit
import SwiftUI
import TokenMeterCore

struct PopoverView: View {
    @ObservedObject var store: ProviderStore
    @State private var activeTooltipID: String?
    @State private var measuredContentHeight: CGFloat = 0
    let initialPanelHeight: CGFloat
    let maxPanelHeight: CGFloat
    let onPreferredHeightChange: (CGFloat) -> Void

    private let chromeHeight: CGFloat = 62

    private var panelHeight: CGFloat {
        guard !store.providerSnapshots.isEmpty else {
            return min(maxPanelHeight, 220)
        }

        guard measuredContentHeight > 20 else {
            return min(maxPanelHeight, initialPanelHeight)
        }

        return min(maxPanelHeight, chromeHeight + measuredContentHeight)
    }

    var body: some View {
        GeometryReader { proxy in
            panelContent(currentHeight: proxy.size.height > 20 ? proxy.size.height : panelHeight)
        }
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            onPreferredHeightChange(panelHeight)
        }
        .onChange(of: panelHeight) { newHeight in
            onPreferredHeightChange(newHeight)
        }
        .task {
            await store.refreshNotificationAuthorizationState()
        }
    }

    private func panelContent(currentHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            header

            Divider()

            if store.providerSnapshots.isEmpty {
                emptyState
            } else {
                ThinScrollView { height in
                    if abs(measuredContentHeight - height) > 0.5 {
                        measuredContentHeight = height
                    }
                } content: {
                    VStack(spacing: 10) {
                        ForEach(store.providerSnapshots, id: \.providerId) { snapshot in
                            ProviderCardView(
                                snapshot: snapshot,
                                activeTooltipID: $activeTooltipID
                            )
                        }
                    }
                    .padding(12)
                }
                .frame(height: scrollViewportHeight(for: currentHeight))
            }
        }
        .frame(width: 320, height: currentHeight)
    }

    private func scrollViewportHeight(for currentHeight: CGFloat) -> CGFloat {
        max(1, currentHeight - chromeHeight)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("TokenMeter")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                NotificationPermissionControl(store: store)

                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(providerCountText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Text(store.localIndexStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var providerCountText: String {
        if store.isRefreshing {
            return "刷新中"
        }

        let okCount = store.providerSnapshots.filter { $0.status == .ok }.count
        return "\(okCount)/\(store.providerSnapshots.count)"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)

            Text("暂无用量数据")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NotificationPermissionControl: View {
    @ObservedObject var store: ProviderStore

    var body: some View {
        switch store.notificationAuthorizationState {
        case .notDetermined:
            Button {
                Task {
                    await store.requestNotificationAuthorization()
                }
            } label: {
                Label("开启通知", systemImage: "bell")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .focusable(false)
        case .denied:
            Button {
                store.openNotificationSettings()
            } label: {
                Image(systemName: "bell.slash.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .focusable(false)
        case .authorized, .unknown:
            EmptyView()
        }
    }
}

private extension View {
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: ViewHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ViewHeightPreferenceKey.self, perform: onChange)
    }
}

private struct ViewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ThinScrollView<Content: View>: NSViewRepresentable {
    let onContentHeightChange: (CGFloat) -> Void
    let content: Content

    init(
        onContentHeightChange: @escaping (CGFloat) -> Void = { _ in },
        @ViewBuilder content: () -> Content
    ) {
        self.onContentHeightChange = onContentHeightChange
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ThinScrollContainerView {
        let container = ThinScrollContainerView()
        container.onContentHeightChange = onContentHeightChange
        let hostingView = NSHostingView(rootView: content)
        context.coordinator.hostingView = hostingView
        container.setDocumentView(hostingView)
        return container
    }

    func updateNSView(_ nsView: ThinScrollContainerView, context: Context) {
        nsView.onContentHeightChange = onContentHeightChange
        context.coordinator.hostingView?.rootView = content
        nsView.updateDocumentLayout()
    }

    final class Coordinator {
        var hostingView: NSHostingView<Content>?
    }
}

private final class ThinScrollContainerView: NSView {
    private enum ThumbPresentation {
        case hidden
        case subtle
        case active
    }

    private let scrollView = NSScrollView()
    private let thumbView = NSView()
    private var documentConstraints: [NSLayoutConstraint] = []
    private var boundsObserver: NSObjectProtocol?
    private var documentFrameObserver: NSObjectProtocol?
    private var lastReportedContentHeight: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var thumbPresentation: ThumbPresentation = .hidden
    private var hasScrollableContent = false
    private var isMouseInside = false
    private var isDraggingThumb = false
    private var dragStartMouseY: CGFloat = 0
    private var dragStartScrollOffset: CGFloat = 0
    private var lastViewportHeight: CGFloat = 1
    private var lastContentHeight: CGFloat = 1
    private var hideThumbWorkItem: DispatchWorkItem?
    var onContentHeightChange: (CGFloat) -> Void = { _ in }

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureScrollView()
        configureThumb()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        hideThumbWorkItem?.cancel()
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
        if let documentFrameObserver {
            NotificationCenter.default.removeObserver(documentFrameObserver)
        }
    }

    func setDocumentView(_ documentView: NSView) {
        NSLayoutConstraint.deactivate(documentConstraints)
        if let documentFrameObserver {
            NotificationCenter.default.removeObserver(documentFrameObserver)
        }
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.postsFrameChangedNotifications = true
        documentView.setContentHuggingPriority(.required, for: .vertical)
        documentView.setContentCompressionResistancePriority(.required, for: .vertical)
        scrollView.documentView = documentView
        documentFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: documentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateThumb()
        }

        documentConstraints = [
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ]
        NSLayoutConstraint.activate(documentConstraints)
        updateDocumentLayout()
    }

    func updateDocumentLayout() {
        scrollView.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        needsLayout = true
        updateThumb()
        DispatchQueue.main.async { [weak self] in
            self?.layoutSubtreeIfNeeded()
            self?.updateThumb()
        }
    }

    override func layout() {
        super.layout()
        updateThumb()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInside = true
        showThumb(.subtle)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard !isDraggingThumb else {
            return
        }
        isMouseInside = false
        scheduleThumbHide(after: 0.8)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard hasScrollableContent else {
            return
        }

        if thumbView.frame.insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil)) {
            showThumb(.active)
        } else if isMouseInside {
            showThumb(.subtle)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard hasScrollableContent,
              thumbView.frame.insetBy(dx: -4, dy: -4).contains(point) else {
            super.mouseDown(with: event)
            return
        }

        isDraggingThumb = true
        dragStartMouseY = point.y
        dragStartScrollOffset = scrollView.contentView.bounds.origin.y
        showThumb(.active)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingThumb else {
            super.mouseDragged(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let maxScroll = max(1, lastContentHeight - lastViewportHeight)
        let verticalInset: CGFloat = 8
        let usableTrackHeight = max(1, bounds.height - verticalInset * 2)
        let thumbHeight = min(usableTrackHeight, max(28, usableTrackHeight * lastViewportHeight / lastContentHeight))
        let maxThumbOffset = max(1, usableTrackHeight - thumbHeight)
        let delta = point.y - dragStartMouseY
        let nextOffset = dragStartScrollOffset + delta * maxScroll / maxThumbOffset
        scrollTo(offset: nextOffset)
        showThumb(.active)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingThumb else {
            super.mouseUp(with: event)
            return
        }

        isDraggingThumb = false
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            isMouseInside = true
            if thumbView.frame.insetBy(dx: -4, dy: -4).contains(point) {
                showThumb(.active)
            } else {
                showThumb(.subtle)
            }
        } else {
            isMouseInside = false
            scheduleThumbHide(after: 0.8)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if hasScrollableContent,
           !thumbView.isHidden,
           thumbView.frame.insetBy(dx: -4, dy: -4).contains(point) {
            return self
        }

        return super.hitTest(point)
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.contentView.postsBoundsChangedNotifications = true

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateThumb()
            self?.handleScrollActivity()
        }
    }

    private func configureThumb() {
        thumbView.wantsLayer = true
        thumbView.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.34).cgColor
        thumbView.layer?.cornerRadius = 2.0
        thumbView.alphaValue = 0
        thumbView.isHidden = true
        thumbView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(thumbView)
    }

    private func updateThumb() {
        guard let documentView = scrollView.documentView else {
            hasScrollableContent = false
            showThumb(.hidden)
            return
        }

        scrollView.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()

        let viewportHeight = max(1, scrollView.contentView.bounds.height)
        let measuredContentHeight = max(1, documentView.fittingSize.height)
        reportContentHeight(measuredContentHeight)

        let contentHeight = max(viewportHeight, measuredContentHeight)
        lastViewportHeight = viewportHeight
        lastContentHeight = contentHeight
        guard contentHeight > viewportHeight + 1 else {
            if scrollView.contentView.bounds.origin.y != 0 {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            hasScrollableContent = false
            showThumb(.hidden)
            return
        }

        hasScrollableContent = true
        let verticalInset: CGFloat = 8
        let thumbWidth = currentThumbWidth
        let usableTrackHeight = max(1, bounds.height - verticalInset * 2)
        let thumbHeight = min(usableTrackHeight, max(28, usableTrackHeight * viewportHeight / contentHeight))
        let maxScroll = max(1, contentHeight - viewportHeight)
        let currentOffset = max(0, scrollView.contentView.bounds.origin.y)
        if currentOffset > maxScroll {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxScroll))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        let scrollOffset = min(maxScroll, max(0, scrollView.contentView.bounds.origin.y))
        let maxThumbOffset = max(0, usableTrackHeight - thumbHeight)
        let thumbY = verticalInset + maxThumbOffset * scrollOffset / maxScroll

        thumbView.frame = CGRect(
            x: bounds.width - thumbWidth - 4,
            y: thumbY,
            width: thumbWidth,
            height: thumbHeight
        )
    }

    private var currentThumbWidth: CGFloat {
        switch thumbPresentation {
        case .hidden, .subtle:
            return 4
        case .active:
            return 5
        }
    }

    private func handleScrollActivity() {
        guard !isDraggingThumb else {
            return
        }
        showThumb(.active)
        scheduleThumbSettle()
    }

    private func scrollTo(offset: CGFloat) {
        let maxScroll = max(0, lastContentHeight - lastViewportHeight)
        let clampedOffset = min(maxScroll, max(0, offset))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateThumb()
    }

    private func showThumb(_ presentation: ThumbPresentation) {
        hideThumbWorkItem?.cancel()
        thumbPresentation = hasScrollableContent ? presentation : .hidden
        updateThumbAppearance()
        if hasScrollableContent {
            updateThumb()
        }
    }

    private func updateThumbAppearance() {
        let alpha: CGFloat
        let colorAlpha: CGFloat
        switch thumbPresentation {
        case .hidden:
            alpha = 0
            colorAlpha = 0.0
        case .subtle:
            alpha = 1
            colorAlpha = 0.28
        case .active:
            alpha = 1
            colorAlpha = 0.58
        }

        thumbView.isHidden = thumbPresentation == .hidden
        thumbView.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(colorAlpha).cgColor
        thumbView.layer?.cornerRadius = currentThumbWidth / 2
        thumbView.alphaValue = alpha
    }

    private func scheduleThumbSettle() {
        hideThumbWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            if self.isMouseInside {
                self.showThumb(.subtle)
            } else {
                self.showThumb(.hidden)
            }
        }
        hideThumbWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: workItem)
    }

    private func scheduleThumbHide(after delay: TimeInterval) {
        hideThumbWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.showThumb(.hidden)
        }
        hideThumbWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func reportContentHeight(_ height: CGFloat) {
        guard abs(lastReportedContentHeight - height) > 0.5 else {
            return
        }

        lastReportedContentHeight = height
        DispatchQueue.main.async { [weak self] in
            self?.onContentHeightChange(height)
        }
    }
}

private struct ProviderCardView: View {
    let snapshot: ProviderUsageSnapshot
    @Binding var activeTooltipID: String?
    @State private var showsResetCredits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                ProviderIconView(providerId: snapshot.providerId)

                Text(snapshot.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                if snapshot.status != .ok {
                    StatusIconButton(
                        status: snapshot.status,
                        message: snapshot.message,
                        tooltipID: "status:\(snapshot.providerId)",
                        activeTooltipID: $activeTooltipID
                    )
                }

                Spacer()

                Text(timeText(snapshot.fetchedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            if !snapshot.groups.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    PrimaryUsageGroupView(
                        group: primaryGroup,
                        providerTitle: snapshot.displayName,
                        hidesSingleGroupTitle: snapshot.groups.count == 1
                    )

                    if !secondaryGroups.isEmpty {
                        SecondaryUsageGroupsView(
                            groups: secondaryGroups,
                            providerTitle: snapshot.displayName
                        )
                    }
                }
            } else {
                UnavailableLine()
            }

            if let resetCredits = snapshot.resetCredits {
                ResetCreditsDisclosureView(
                    providerId: snapshot.providerId,
                    summary: resetCredits,
                    isExpanded: $showsResetCredits,
                    activeTooltipID: $activeTooltipID
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(moduleBorderColor(strength: .strong), lineWidth: 1)
        )
    }

    private var primaryGroup: UsageGroup {
        let firstGroup = snapshot.groups[0]
        return UsageGroup(
            id: firstGroup.id,
            title: firstGroup.title,
            subtitle: firstGroup.subtitle,
            items: Array(firstGroup.items.prefix(2))
        )
    }

    private var secondaryGroups: [UsageGroup] {
        let firstGroup = snapshot.groups[0]
        let overflowItems = Array(firstGroup.items.dropFirst(2))
        var groups: [UsageGroup] = []

        if !overflowItems.isEmpty {
            groups.append(
                UsageGroup(
                    id: "\(firstGroup.id)-additional",
                    title: overflowItems.count == 1 ? overflowItems[0].label : "附加额度",
                    subtitle: nil,
                    items: overflowItems
                )
            )
        }

        groups.append(contentsOf: snapshot.groups.dropFirst())
        return groups
    }

    private var cardBackground: some ShapeStyle {
        Color(nsColor: .controlBackgroundColor)
    }
}

private struct ResetCreditsDisclosureView: View {
    let providerId: String
    let summary: ResetCreditSummary
    @Binding var isExpanded: Bool
    @Binding var activeTooltipID: String?

    private var items: [ResetCreditDisplayItem] {
        ResetCreditDisplay.items(for: summary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isExpanded.toggle()
                activeTooltipID = nil
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)

                    Text("重置卡")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("\(items.count) 张")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()

                    Spacer(minLength: 8)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if items.isEmpty {
                        Text("暂无未过期重置卡")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(items, id: \.index) { item in
                            ResetCreditRowView(
                                providerId: providerId,
                                item: item,
                                activeTooltipID: $activeTooltipID
                            )
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(isDarkAppearance ? 0.40 : 0.68))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(moduleBorderColor(strength: .medium), lineWidth: 1)
                )
            }
        }
    }
}

private struct ResetCreditRowView: View {
    let providerId: String
    let item: ResetCreditDisplayItem
    @Binding var activeTooltipID: String?

    private var tooltipID: String {
        "reset-credit:\(providerId):\(item.index)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("#\(item.index)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 24, alignment: .leading)

            ResetCreditProgressView(item: item)
                .frame(height: 7)

            Text(item.remainingText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(resetCreditColor(item.tone))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
                .lineLimit(1)

            TooltipIconButton(
                systemImage: "info.circle",
                tintColor: Color(nsColor: .tertiaryLabelColor),
                backgroundColor: nil,
                message: resetCreditDetailText(item.credit),
                width: 168,
                placement: .leading,
                distance: 4,
                tooltipID: tooltipID,
                activeTooltipID: $activeTooltipID
            )
            .frame(width: 16, height: 16)
        }
        .padding(.vertical, 2)
        .zIndex(activeTooltipID == tooltipID ? 100 : 0)
    }
}

private struct TooltipIconButton: View {
    let systemImage: String
    let tintColor: Color
    let backgroundColor: Color?
    let message: String
    let width: CGFloat
    var placement: TooltipPlacement = .top
    var distance: CGFloat = 6
    let tooltipID: String
    @Binding var activeTooltipID: String?

    var body: some View {
        Button {
            guard !message.isEmpty else {
                return
            }
            activeTooltipID = activeTooltipID == tooltipID ? nil : tooltipID
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tintColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(backgroundColor ?? Color.clear)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .zIndex(activeTooltipID == tooltipID ? 100 : 0)
        .background(
            TooltipPanelAnchorView(
                id: tooltipID,
                message: message,
                width: width,
                placement: placement,
                distance: distance,
                isPresented: activeTooltipID == tooltipID
            )
        )
    }
}

private enum TooltipPlacement {
    case top
    case leading
}

private struct TooltipPanelAnchorView: NSViewRepresentable {
    let id: String
    let message: String
    let width: CGFloat
    let placement: TooltipPlacement
    let distance: CGFloat
    let isPresented: Bool

    func makeNSView(context: Context) -> TooltipAnchorNSView {
        TooltipAnchorNSView()
    }

    func updateNSView(_ nsView: TooltipAnchorNSView, context: Context) {
        nsView.configuration = TooltipPanelConfiguration(
            id: id,
            message: message,
            width: width,
            placement: placement,
            distance: distance,
            isPresented: isPresented
        )
        nsView.schedulePanelUpdate()
    }
}

private struct TooltipPanelConfiguration: Equatable {
    let id: String
    let message: String
    let width: CGFloat
    let placement: TooltipPlacement
    let distance: CGFloat
    let isPresented: Bool
}

private final class TooltipAnchorNSView: NSView {
    var configuration: TooltipPanelConfiguration?
    private var isUpdateScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        schedulePanelUpdate()
    }

    override func layout() {
        super.layout()
        schedulePanelUpdate()
    }

    func schedulePanelUpdate() {
        guard !isUpdateScheduled else {
            return
        }

        isUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isUpdateScheduled = false
            self?.updatePanel()
        }
    }

    private func updatePanel() {
        guard let configuration else {
            TooltipPanelPresenter.shared.hide()
            return
        }

        guard configuration.isPresented,
              !configuration.message.isEmpty,
              let window else {
            TooltipPanelPresenter.shared.hide(id: configuration.id)
            return
        }

        TooltipPanelPresenter.shared.show(
            configuration: configuration,
            anchorRect: convert(bounds, to: nil),
            parentWindow: window
        )
    }
}

private final class TooltipPanelPresenter {
    static let shared = TooltipPanelPresenter()

    private var panel: NSPanel?
    private var currentID: String?
    private weak var parentWindow: NSWindow?

    func show(configuration: TooltipPanelConfiguration, anchorRect: CGRect, parentWindow: NSWindow) {
        let panel = panel ?? makePanel()
        self.panel = panel
        currentID = configuration.id
        attach(panel, to: parentWindow)

        let content = TooltipPanelContent(
            message: configuration.message,
            width: configuration.width,
            placement: configuration.placement,
            arrowPosition: 0
        )
        let hostingView = NSHostingView(rootView: content)
        panel.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        let fittingSize = hostingView.fittingSize
        let panelSize = NSSize(
            width: max(configuration.width, fittingSize.width),
            height: max(1, fittingSize.height)
        )
        let anchorScreenRect = parentWindow.convertToScreen(anchorRect)
        let frame = frame(
            for: panelSize,
            anchorScreenRect: anchorScreenRect,
            parentWindowFrame: parentWindow.frame,
            placement: configuration.placement,
            distance: configuration.distance
        )
        let arrowPosition = arrowPosition(
            for: configuration.placement,
            frame: frame,
            anchorScreenRect: anchorScreenRect
        )

        hostingView.rootView = TooltipPanelContent(
            message: configuration.message,
            width: configuration.width,
            placement: configuration.placement,
            arrowPosition: arrowPosition
        )
        panel.setFrame(frame, display: true)
        if !(parentWindow.childWindows?.contains(panel) ?? false) {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide(id: String? = nil) {
        guard id == nil || id == currentID else {
            return
        }

        if let panel,
           let parentWindow {
            parentWindow.removeChildWindow(panel)
        }
        panel?.orderOut(nil)
        currentID = nil
        parentWindow = nil
    }

    private func attach(_ panel: NSPanel, to parentWindow: NSWindow) {
        if self.parentWindow !== parentWindow {
            if let previousParent = self.parentWindow {
                previousParent.removeChildWindow(panel)
            }
            self.parentWindow = parentWindow
        }

        panel.level = NSWindow.Level(rawValue: parentWindow.level.rawValue + 1)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func frame(
        for size: NSSize,
        anchorScreenRect: CGRect,
        parentWindowFrame: CGRect,
        placement: TooltipPlacement,
        distance: CGFloat
    ) -> CGRect {
        let margin: CGFloat = 12
        let minX = parentWindowFrame.minX + margin
        let maxX = parentWindowFrame.maxX - margin
        let minY = parentWindowFrame.minY + margin
        let maxY = parentWindowFrame.maxY - margin

        switch placement {
        case .top:
            var x = anchorScreenRect.midX - size.width / 2
            x = min(max(x, minX), maxX - size.width)
            var y = anchorScreenRect.maxY + distance
            y = min(max(y, minY), maxY - size.height)
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        case .leading:
            var x = anchorScreenRect.minX - distance - size.width
            x = min(max(x, minX), maxX - size.width)
            var y = anchorScreenRect.midY - size.height / 2
            y = min(max(y, minY), maxY - size.height)
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }

    private func arrowPosition(
        for placement: TooltipPlacement,
        frame: CGRect,
        anchorScreenRect: CGRect
    ) -> CGFloat {
        let arrowWidth: CGFloat = 6
        let radius: CGFloat = 6
        let limit = radius + arrowWidth

        switch placement {
        case .top:
            return min(max(anchorScreenRect.midX - frame.minX, limit), frame.width - limit)
        case .leading:
            return min(max(frame.maxY - anchorScreenRect.midY, limit), frame.height - limit)
        }
    }
}

private struct TooltipPanelContent: View {
    let message: String
    let width: CGFloat
    let placement: TooltipPlacement
    let arrowPosition: CGFloat

    var body: some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(tooltipTextColor())
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: max(40, width - 20), alignment: .leading)
            .padding(.leading, 10)
            .padding(.trailing, placement == .leading ? 17 : 10)
            .padding(.top, 8)
            .padding(.bottom, placement == .top ? 15 : 8)
            .background(
                TooltipBubbleShape(placement: placement, arrowPosition: arrowPosition)
                    .fill(tooltipBackgroundColor())
            )
            .overlay(
                TooltipBubbleShape(placement: placement, arrowPosition: arrowPosition)
                    .stroke(tooltipBorderColor(), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
    }
}

private struct TooltipBubbleShape: Shape {
    let placement: TooltipPlacement
    let arrowPosition: CGFloat

    private let radius: CGFloat = 6
    private let arrowWidth: CGFloat = 6
    private let arrowHeight: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        switch placement {
        case .top:
            return topPath(in: rect)
        case .leading:
            return leadingPath(in: rect)
        }
    }

    private func topPath(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: 0, dy: 0).insetBy(dx: 0, dy: 0)
        let bodyMaxY = body.maxY - arrowHeight
        let arrowX = min(max(arrowPosition, radius + arrowWidth), rect.width - radius - arrowWidth)
        var path = Path()
        path.move(to: CGPoint(x: radius, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY + radius), control: CGPoint(x: body.maxX, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX, y: bodyMaxY - radius))
        path.addQuadCurve(to: CGPoint(x: body.maxX - radius, y: bodyMaxY), control: CGPoint(x: body.maxX, y: bodyMaxY))
        path.addLine(to: CGPoint(x: arrowX + arrowWidth, y: bodyMaxY))
        path.addLine(to: CGPoint(x: arrowX, y: rect.maxY))
        path.addLine(to: CGPoint(x: arrowX - arrowWidth, y: bodyMaxY))
        path.addLine(to: CGPoint(x: radius, y: bodyMaxY))
        path.addQuadCurve(to: CGPoint(x: body.minX, y: bodyMaxY - radius), control: CGPoint(x: body.minX, y: bodyMaxY))
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: body.minY), control: CGPoint(x: body.minX, y: body.minY))
        path.closeSubpath()
        return path
    }

    private func leadingPath(in rect: CGRect) -> Path {
        let bodyMaxX = rect.maxX - arrowHeight
        let arrowY = min(max(arrowPosition, radius + arrowWidth), rect.height - radius - arrowWidth)
        var path = Path()
        path.move(to: CGPoint(x: radius, y: rect.minY))
        path.addLine(to: CGPoint(x: bodyMaxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: bodyMaxX, y: rect.minY + radius), control: CGPoint(x: bodyMaxX, y: rect.minY))
        path.addLine(to: CGPoint(x: bodyMaxX, y: arrowY - arrowWidth))
        path.addLine(to: CGPoint(x: rect.maxX, y: arrowY))
        path.addLine(to: CGPoint(x: bodyMaxX, y: arrowY + arrowWidth))
        path.addLine(to: CGPoint(x: bodyMaxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: bodyMaxX - radius, y: rect.maxY), control: CGPoint(x: bodyMaxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct ResetCreditProgressView: View {
    let item: ResetCreditDisplayItem

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let progress = max(0, min(1, item.progress))
            let fillWidth = max(5, width * progress)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.24))

                Capsule()
                    .fill(resetCreditColor(item.tone).opacity(0.88))
                    .frame(width: fillWidth)
            }
        }
    }
}

private struct PrimaryUsageGroupView: View {
    let group: UsageGroup
    let providerTitle: String
    let hidesSingleGroupTitle: Bool

    private var shouldShowTitle: Bool {
        return !hidesSingleGroupTitle && group.title != providerTitle
    }

    var body: some View {
        if !group.items.isEmpty {
            VStack(alignment: .leading, spacing: shouldShowTitle ? 8 : 7) {
                if shouldShowTitle {
                    HStack(spacing: 6) {
                        Text(group.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let subtitle = group.subtitle {
                            Text(subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                }

                HStack(spacing: 10) {
                    ForEach(group.items, id: \.id) { metric in
                        PrimaryMetricRingCard(metric: metric)
                    }
                }
            }
        }
    }
}

private struct PrimaryMetricRingCard: View {
    let metric: UsageMetric

    var body: some View {
        HStack(spacing: 9) {
            MetricRingView(metric: metric)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(metric.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let detailText {
                    Text(detailText)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(isDarkAppearance ? 0.36 : 0.64))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(moduleBorderColor(strength: .medium), lineWidth: 1)
        )
    }

    private var detailText: String? {
        if let detail = metric.detail, !detail.isEmpty {
            return detail
        }

        return metric.resetText
    }
}

private struct MetricRingView: View {
    let metric: UsageMetric

    private var value: Double {
        max(0, min(1, (metric.remainingPercent ?? 0) / 100))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(nsColor: .separatorColor).opacity(isDarkAppearance ? 0.44 : 0.28), lineWidth: 7)

            Circle()
                .trim(from: 0, to: value)
                .stroke(
                    metricColor(metric),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Text(shortPercentText)
                .font(.system(size: ringTextFontSize, weight: .bold))
                .foregroundStyle(metricColor(metric))
                .monospacedDigit()
                .frame(width: 38)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
                .lineLimit(1)
        }
    }

    private var ringTextFontSize: CGFloat {
        shortPercentText.count >= 4 ? 12 : 13
    }

    private var shortPercentText: String {
        guard let remaining = metric.remainingPercent else {
            return "--"
        }

        return "\(Int(remaining.rounded()))%"
    }
}

private struct SecondaryUsageGroupsView: View {
    let groups: [UsageGroup]
    let providerTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(groups, id: \.id) { group in
                UsageGroupView(
                    group: group,
                    providerTitle: providerTitle,
                    hidesSingleGroupTitle: false,
                    isSecondary: true
                )
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(isDarkAppearance ? 0.40 : 0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(moduleBorderColor(strength: .medium), lineWidth: 1)
        )
    }
}

private struct ProviderIconView: View {
    let providerId: String

    private var image: NSImage? {
        providerIconImage(for: providerId)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(iconColor.opacity(0.14))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(iconColor)
                    .scaledToFit()
                    .frame(width: 15, height: 15)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }

    private var iconColor: Color {
        providerAccentColor(providerId)
    }
}

private struct UsageGroupView: View {
    let group: UsageGroup
    let providerTitle: String
    let hidesSingleGroupTitle: Bool
    var isSecondary = false

    private var shouldShowTitle: Bool {
        if isSecondary,
           group.items.count == 1,
           group.title == group.items[0].label {
            return false
        }

        return !hidesSingleGroupTitle && group.title != providerTitle
    }

    var body: some View {
        if !group.items.isEmpty {
            VStack(alignment: .leading, spacing: shouldShowTitle ? 7 : 6) {
                if shouldShowTitle {
                    HStack(spacing: 6) {
                        Text(group.title)
                            .font(.system(size: isSecondary ? 11 : 12, weight: isSecondary ? .regular : .medium))
                            .foregroundStyle(isSecondary ? .secondary : .primary)
                            .lineLimit(1)

                        if let subtitle = group.subtitle {
                            Text(subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                }

                VStack(spacing: 6) {
                    ForEach(group.items, id: \.id) { metric in
                        MetricRowView(metric: metric)
                    }
                }
            }
        }
    }
}

private struct MetricRowView: View {
    let metric: UsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(metric.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
                    .lineLimit(1)

                Text(percentText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(metricColor(metric))
                    .monospacedDigit()
                    .frame(width: 42, alignment: .leading)

                Spacer(minLength: 8)

                if let detailText {
                    Text(detailText)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                Color.clear
                    .frame(width: 28)

                QuotaMeterView(metric: metric)
                    .frame(height: 7)
            }
        }
        .padding(.vertical, 1)
    }

    private var percentText: String {
        guard let remaining = metric.remainingPercent else {
            return "--"
        }

        return "\(UsageFormatter.numberText(remaining))%"
    }

    private var detailText: String? {
        if let detail = metric.detail, !detail.isEmpty {
            return detail
        }

        return metric.resetText
    }
}

private struct QuotaMeterView: View {
    let metric: UsageMetric

    private var value: Double {
        (metric.remainingPercent ?? 0) / 100
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = max(6, width * max(0, min(1, value)))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.28))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                metricColor(metric).opacity(0.72),
                                metricColor(metric)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
            }
        }
    }
}

private struct StatusIconButton: View {
    let status: UsageStatus
    let message: String?
    let tooltipID: String
    @Binding var activeTooltipID: String?

    var body: some View {
        TooltipIconButton(
            systemImage: statusIconName(status),
            tintColor: statusColor(status),
            backgroundColor: statusColor(status).opacity(0.12),
            message: status == .ok ? "" : statusMessage,
            width: 196,
            placement: .top,
            tooltipID: tooltipID,
            activeTooltipID: $activeTooltipID
        )
        .frame(width: 18, height: 18)
        .accessibilityLabel(statusText(status))
    }

    private var statusMessage: String {
        message ?? ""
    }
}

private struct UnavailableLine: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)

            Text("暂无可用缓存")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.top, 2)
    }
}

private func tooltipBackgroundColor() -> Color {
    Color(nsColor: tooltipBackgroundNSColor())
}

private func tooltipBackgroundNSColor() -> NSColor {
    isDarkAppearance ? NSColor(calibratedWhite: 0.14, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)
}

private func tooltipTextColor() -> Color {
    Color(nsColor: isDarkAppearance ? NSColor(calibratedWhite: 0.94, alpha: 1) : NSColor(calibratedWhite: 0.12, alpha: 1))
}

private func tooltipBorderColor() -> Color {
    Color(nsColor: isDarkAppearance ? NSColor(calibratedWhite: 0.28, alpha: 1) : NSColor(calibratedWhite: 0.78, alpha: 1))
}

private enum ModuleBorderStrength {
    case medium
    case strong
}

private func moduleBorderColor(strength: ModuleBorderStrength) -> Color {
    let alpha: CGFloat
    switch (isDarkAppearance, strength) {
    case (true, .medium):
        alpha = 0.72
    case (true, .strong):
        alpha = 0.86
    case (false, .medium):
        alpha = 0.46
    case (false, .strong):
        alpha = 0.58
    }

    return Color(nsColor: .separatorColor).opacity(alpha)
}

private var isDarkAppearance: Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

private func metricColor(_ metric: UsageMetric?) -> Color {
    switch UsageMetricToneResolver.tone(for: metric) {
    case .ok:
        return .green
    case .warning:
        return .yellow
    case .bad:
        return .red
    case .muted:
        return Color(nsColor: .tertiaryLabelColor)
    }
}

private func resetCreditColor(_ tone: ResetCreditDisplayTone) -> Color {
    switch tone {
    case .ok:
        return .green
    case .warning:
        return .yellow
    case .bad:
        return .red
    }
}

private func providerIconImage(for providerId: String) -> NSImage? {
    guard let iconName = providerIconName(providerId),
          let url = Bundle.module.url(
              forResource: iconName,
              withExtension: "pdf"
          ),
          let image = NSImage(contentsOf: url) else {
        return nil
    }

    image.isTemplate = true
    return image
}

private func providerIconName(_ providerId: String) -> String? {
    switch providerId {
    case "codex":
        return "codex"
    case "claude-code":
        return "claude"
    case "zhipu", "zhipu-http":
        return "zai"
    default:
        return nil
    }
}

private func providerAccentColor(_ providerId: String) -> Color {
    switch providerId {
    case "codex":
        return .blue
    case "claude-code":
        return .orange
    case "zhipu", "zhipu-http":
        return .teal
    default:
        return Color(nsColor: .secondaryLabelColor)
    }
}

private func statusColor(_ status: UsageStatus) -> Color {
    Color(nsColor: statusNSColor(status))
}

private func statusNSColor(_ status: UsageStatus) -> NSColor {
    switch status {
    case .ok:
        return .systemGreen
    case .warning:
        return .systemOrange
    case .error:
        return .systemRed
    case .unknown:
        return .tertiaryLabelColor
    }
}

private func statusIconName(_ status: UsageStatus) -> String {
    switch status {
    case .ok:
        return "checkmark.seal.fill"
    case .warning:
        return "exclamationmark.circle.fill"
    case .error:
        return "xmark.circle.fill"
    case .unknown:
        return "questionmark.circle.fill"
    }
}

private func statusText(_ status: UsageStatus) -> String {
    switch status {
    case .ok:
        return "正常"
    case .warning:
        return "提醒"
    case .error:
        return "异常"
    case .unknown:
        return "未知"
    }
}

private func timeText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func beijingTimeText(_ date: Date?) -> String {
    guard let date else {
        return "--"
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

private func resetCreditDetailText(_ credit: ResetCredit) -> String {
    """
    发放：\(beijingTimeText(credit.issuedAt))
    过期：\(beijingTimeText(credit.expiresAt))
    """
}
