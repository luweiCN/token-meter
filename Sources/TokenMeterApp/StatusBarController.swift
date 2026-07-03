import AppKit
import Combine
import SwiftUI
import TokenMeterCore

@MainActor
final class StatusBarController: NSObject {
    private let store: ProviderStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellables: Set<AnyCancellable> = []

    init(store: ProviderStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()

        super.init()

        configureStatusItem()
        configurePopover()
        bindStore()
    }

    func updateTitle(_ title: String) {
        statusItem.button?.title = title
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.title = "TokenMeter"
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        updatePopoverContent(relativeTo: statusItem.button)
    }

    private func bindStore() {
        Publishers.CombineLatest(store.$providerSnapshots, store.$settingsSnapshot)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshots, settingsSnapshot in
                guard let self else {
                    return
                }

                let primaryProviderId = settingsSnapshot?.menuBarPrimaryProviderId
                    ?? self.store.config.menuBar.primaryProviderId
                let title = UsageFormatter.menuBarTitle(
                    for: snapshots,
                    primaryProviderId: primaryProviderId
                )
                self.updateTitle(title)
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            updatePopoverContent(relativeTo: button)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updatePopoverContent(relativeTo button: NSStatusBarButton?) {
        let size = preferredPopoverSize(relativeTo: button)
        popover.contentSize = NSSize(width: size.width, height: size.initialHeight)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                store: store,
                initialPanelHeight: size.initialHeight,
                maxPanelHeight: size.maxHeight
            ) { [weak self] height in
                self?.updatePopoverHeight(height)
            }
        )
    }

    private func preferredPopoverSize(relativeTo button: NSStatusBarButton?) -> (width: CGFloat, initialHeight: CGFloat, maxHeight: CGFloat) {
        let screenHeight = button?.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 820
        let maxHeight = min(760, max(360, screenHeight - 96))
        let estimatedHeight = estimatedCollapsedContentHeight()
        return (width: 320, initialHeight: min(maxHeight, estimatedHeight), maxHeight: maxHeight)
    }

    private func updatePopoverHeight(_ height: CGFloat) {
        let currentSize = popover.contentSize
        guard abs(currentSize.height - height) > 0.5 else {
            return
        }

        popover.contentSize = NSSize(width: currentSize.width, height: height)
    }

    private func estimatedCollapsedContentHeight() -> CGFloat {
        let snapshots = store.providerSnapshots
        guard !snapshots.isEmpty else {
            return 220
        }

        let headerAndDivider: CGFloat = 62
        let listPadding: CGFloat = 24
        let cardSpacing = CGFloat(max(0, snapshots.count - 1)) * 10
        let cardHeights = snapshots.reduce(CGFloat(0)) { total, snapshot in
            total + estimatedCardHeight(snapshot)
        }

        return headerAndDivider + listPadding + cardSpacing + cardHeights
    }

    private func estimatedCardHeight(_ snapshot: ProviderUsageSnapshot) -> CGFloat {
        var height: CGFloat = 24 + 26

        if snapshot.groups.isEmpty {
            height += 12 + 22
        } else {
            height += 12
            height += estimatedGroupHeight(
                snapshot.groups[0],
                providerTitle: snapshot.displayName,
                hidesSingleGroupTitle: snapshot.groups.count == 1
            )

            let secondaryGroups = Array(snapshot.groups.dropFirst())
            if !secondaryGroups.isEmpty {
                height += 10 + 16
                height += secondaryGroups.reduce(CGFloat(0)) { total, group in
                    total + estimatedGroupHeight(group, providerTitle: snapshot.displayName, hidesSingleGroupTitle: false)
                }
                height += CGFloat(max(0, secondaryGroups.count - 1)) * 9
            }
        }

        if snapshot.resetCredits != nil {
            height += 12 + 22
        }

        return height
    }

    private func estimatedGroupHeight(
        _ group: UsageGroup,
        providerTitle: String,
        hidesSingleGroupTitle: Bool
    ) -> CGFloat {
        var height: CGFloat = 0
        if !hidesSingleGroupTitle && group.title != providerTitle {
            height += 20
        }

        let itemCount = group.items.count
        if itemCount > 0 {
            height += CGFloat(itemCount) * 32
            height += CGFloat(max(0, itemCount - 1)) * 6
        }
        return height
    }
}
