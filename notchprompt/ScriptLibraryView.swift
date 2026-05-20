//
//  ScriptLibraryView.swift
//  notchprompt
//
//  Sidebar list of saved scripts + editor for the selected one.
//  Load button hands the script body to PrompterModel.
//

import SwiftUI

struct ScriptLibraryView: View {
    @ObservedObject private var store = ScriptStore.shared
    @ObservedObject private var prompter = PrompterModel.shared

    @State private var selectedId: UUID?
    @State private var draftTitle: String = ""
    @State private var draftBody: String = ""
    @State private var deleteCandidateId: UUID?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear(perform: bootstrapSelection)
        .onChange(of: selectedId) { _, newId in
            loadDraft(for: newId)
        }
        .alert(
            "Delete this script?",
            isPresented: Binding(
                get: { deleteCandidateId != nil },
                set: { if !$0 { deleteCandidateId = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let id = deleteCandidateId {
                    store.delete(id: id)
                    if selectedId == id {
                        selectedId = store.scripts.first?.id
                    }
                }
                deleteCandidateId = nil
            }
            Button("Cancel", role: .cancel) {
                deleteCandidateId = nil
            }
        } message: {
            Text("This action can't be undone.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedId) {
                if store.scripts.isEmpty {
                    Text("No saved scripts yet")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(store.scripts) { script in
                        sidebarRow(for: script)
                            .tag(script.id)
                            .contextMenu {
                                Button("Load to Teleprompter") {
                                    store.setActive(id: script.id)
                                }
                                Button("Duplicate") {
                                    let copy = store.create(title: "\(script.title) Copy", body: script.body)
                                    selectedId = copy.id
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    deleteCandidateId = script.id
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 6) {
                Button {
                    let new = store.create(title: "Untitled", body: "")
                    selectedId = new.id
                } label: {
                    Image(systemName: "plus")
                }
                .help("New script")
                .buttonStyle(.borderless)

                Button {
                    if let id = selectedId { deleteCandidateId = id }
                } label: {
                    Image(systemName: "minus")
                }
                .help("Delete selected")
                .buttonStyle(.borderless)
                .disabled(selectedId == nil)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func sidebarRow(for script: StoredScript) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(script.title.isEmpty ? "Untitled" : script.title)
                    .font(.body)
                    .lineLimit(1)
                if store.activeId == script.id {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(Self.relativeDateFormatter.localizedString(for: script.updatedAt, relativeTo: Date()))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedId, let _ = store.scripts.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Title", text: $draftTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 400)
                        .onChange(of: draftTitle) { _, _ in persistDraft() }

                    Spacer()

                    Button("Load to Teleprompter") {
                        persistDraft()
                        store.setActive(id: id)
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("Load this script into the teleprompter overlay (⌘↩)")

                    if store.activeId == id {
                        Text("Active")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }

                Divider()

                TextEditor(text: $draftBody)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.textBackgroundColor))
                    .border(Color.secondary.opacity(0.18), width: 1)
                    .onChange(of: draftBody) { _, _ in persistDraft() }

                HStack {
                    Text("\(wordCount(draftBody)) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Saved automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("Select a script or create a new one")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func bootstrapSelection() {
        if selectedId == nil {
            selectedId = store.activeId ?? store.scripts.first?.id
        }
        loadDraft(for: selectedId)
    }

    private func loadDraft(for id: UUID?) {
        guard let id, let script = store.scripts.first(where: { $0.id == id }) else {
            draftTitle = ""
            draftBody = ""
            return
        }
        draftTitle = script.title
        draftBody = script.body
    }

    private func persistDraft() {
        guard let id = selectedId, var script = store.scripts.first(where: { $0.id == id }) else { return }
        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        script.title = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
        script.body = draftBody
        store.save(script)
        // Live-update the teleprompter if the user is editing the currently active script.
        if store.activeId == id {
            PrompterModel.shared.script = script.body
        }
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
