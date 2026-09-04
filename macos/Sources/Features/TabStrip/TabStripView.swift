import SwiftUI

/// The compact tab strip drawn above the terminal in place of the native tab bar.
struct TabStripView: View {
    @ObservedObject var model: TabStripModel
    @ObservedObject var chrome: WindowChromeModel

    /// How wide the bar to our left is, so the strip knows how far the traffic lights reach into it.
    let leadingBarWidth: CGFloat

    @ObservedObject private var appearance = AppAppearance.shared
    private var palette: AppPalette { AppPalette.resolve(appearance.colorScheme) }
    @State private var editingID: TabStripModel.Item.ID?
    @State private var draggingID: TabStripModel.Item.ID?

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(model.items) { item in
                        TabStripItemView(
                            item: item,
                            isEditing: editingID == item.id,
                            select: { model.select(item.id) },
                            close: { model.close(item.id) },
                            beginRename: { editingID = item.id },
                            commitRename: { title in
                                editingID = nil
                                model.rename(item.id, to: title)
                            },
                            cancelRename: { editingID = nil },
                            currentTitle: { model.currentTitle(item.id) })
                            .contextMenu { contextMenu(for: item) }
                            .onDrag {
                                draggingID = item.id
                                return NSItemProvider(object: String(describing: item.id) as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabDropDelegate(
                                target: item.id,
                                dragging: $draggingID,
                                items: model.items,
                                move: { id, index in model.move(id, to: index) }))
                    }

                    Button { model.newTab() } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(AppIconButtonStyle())
                    .help("New Tab")
                }
                .padding(.vertical, 6)
            }

            Spacer(minLength: 0)

            if model.isZoomed {
                Button { model.resetZoom() } label: {
                    Image("ResetZoom")
                }
                .buttonStyle(AppIconButtonStyle(isActive: true))
                .help("Reset Split Zoom")
            }
        }
        .padding(.leading, 6 + chrome.windowButtonsInset(barWidth: leadingBarWidth))
        .padding(.trailing, 6)
        .frame(height: AppMetrics.topBarHeight)
        .frame(maxWidth: .infinity)
        .background(WindowDragRegion())
        .background(palette.background)
        .environment(\.colorScheme, appearance.colorScheme)
    }

    @ViewBuilder
    private func contextMenu(for item: TabStripModel.Item) -> some View {
        Button("Rename Tab…") { editingID = item.id }
        Divider()
        Button("Close Tab") { model.close(item.id) }
        Button("Close Other Tabs") { model.closeOthers(item.id) }
            .disabled(model.items.count < 2)
        Button("Close Tabs to the Right") { model.closeToTheRight(item.id) }
            .disabled(model.items.last?.id == item.id)
        Button("Move Tab to New Window") { model.moveToNewWindow(item.id) }
            .disabled(model.items.count < 2)
        Divider()
        TabColorMenuView(selectedColor: item.tabColor) { color in
            model.setColor(item.id, color)
        }
    }
}

/// One tab: color dot, Claude activity, title (or its inline editor), and a close button on hover.
private struct TabStripItemView: View {
    let item: TabStripModel.Item
    let isEditing: Bool
    let select: () -> Void
    let close: () -> Void
    let beginRename: () -> Void
    let commitRename: (String) -> Void
    let cancelRename: () -> Void
    let currentTitle: () -> String

    @ObservedObject private var appearance = AppAppearance.shared
    private var palette: AppPalette { AppPalette.resolve(appearance.colorScheme) }
    @State private var isHovering = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let color = item.tabColor.displayColor {
                Circle()
                    .fill(Color(color))
                    .frame(width: 6, height: 6)
            }

            ClaudeActivityIndicatorView(activity: item.claudeActivity, small: true)

            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppMetrics.headerFontSize))
                    .foregroundStyle(palette.textPrimary)
                    .frame(minWidth: 80, maxWidth: 200)
                    .focused($editorFocused)
                    .onSubmit { commitRename(draft) }
                    .onExitCommand { cancelRename() }
                    .onAppear {
                        draft = currentTitle()
                        editorFocused = true
                    }
                    .onChange(of: editorFocused) { focused in
                        if !focused { commitRename(draft) }
                    }
            } else {
                Text(item.title)
                    .font(.system(size: AppMetrics.headerFontSize, weight: item.isSelected ? .medium : .regular))
                    .foregroundStyle(item.isSelected ? palette.textPrimary : palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180)
            }

            if let key = item.keyEquivalent, !isHovering, !isEditing {
                Text(key)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textFaint)
            }

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(AppIconButtonStyle(size: 9, frame: 16))
            .opacity(isHovering && !isEditing ? 1 : 0)
            .allowsHitTesting(isHovering && !isEditing)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: AppMetrics.rowRadius, style: .continuous)
                .fill(item.isSelected ? palette.selection : (isHovering ? palette.hover : Color.clear)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture(count: 1) { select() }
        .help(item.title)
    }
}

/// Reorders tabs while a drag hovers over another tab; the drop itself only clears state.
private struct TabDropDelegate: DropDelegate {
    let target: TabStripModel.Item.ID
    @Binding var dragging: TabStripModel.Item.ID?
    let items: [TabStripModel.Item]
    let move: (TabStripModel.Item.ID, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        move(dragging, to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
