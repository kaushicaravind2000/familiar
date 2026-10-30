import AppKit
import FamiliarCore
import SwiftUI

/// Search inside the main window: the same search as the panel (⌥Space by default), with room to look through results.
/// Double-click opens a file; right-click shows it in Finder, copies it, or starts a chat about it.
struct SearchPage: View {
    @ObservedObject var app: AppState
    @StateObject private var model = PanelModel()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                TextField("Describe what you're looking for", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 20))
                    .focused($fieldFocused)
                    .onSubmit { if let result = model.selected { ResultActions.open(result, query: model.query) } }
                if model.searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 10)
            HStack(spacing: 6) {
                ForEach(KindFilter.allCases, id: \.self) { filter in
                    Button { model.filter = filter } label: {
                        Text(filter.rawValue).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(model.filter == filter ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.07)))
                            .foregroundStyle(model.filter == filter ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(app.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 22).padding(.bottom, 12)
            Divider()
            results
            Divider()
            HStack(spacing: 14) {
                Text("Double-click to open · Right-click for more · ↩ opens the selected file")
                Spacer()
                Text("From any app: \(GlobalShortcut.search.display)")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 7)
        }
        // A moment later: the sidebar list takes the keyboard first when the window opens, and typing went to it.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { fieldFocused = true } }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchPage)) { _ in fieldFocused = true }
    }

    @ViewBuilder private var results: some View {
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            hint("sparkle.magnifyingglass", "Search by what's inside",
                 "Try “the clause about pets in the lease”, “dog on the beach” or “where they talk about sleep”.")
        } else if let error = model.error {
            hint("exclamationmark.triangle", "Search didn't work", error)
        } else if model.results.isEmpty && !model.searching {
            hint("questionmark.folder", "Nothing close", "Try other words, or check that the folder is in Sources.")
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        ResultRow(result: result, selected: index == model.selection)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { ResultActions.open(result, query: model.query) }
                            .simultaneousGesture(TapGesture().onEnded { model.selection = index })
                            .contextMenu {
                                Button("Open") { ResultActions.open(result, query: model.query) }
                                Button("Show in Finder") { ResultActions.reveal(result) }
                                Button("Copy File") { ResultActions.copy(result) }
                                Divider()
                                Button("Ask About This File") {
                                    let chats = MainWindowController.shared.chats
                                    chats.newChat()
                                    chats.scope = result.path
                                    MainWindowController.shared.navigation.page = .chat
                                }
                            }
                    }
                }
                .padding(8)
            }
        }
    }

    private func hint(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

extension Notification.Name {
    static let focusSearchPage = Notification.Name("FamiliarFocusSearchPage")
}
