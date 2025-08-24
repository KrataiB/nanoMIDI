import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Memo.createdAt, order: .reverse) private var memos: [Memo]

    // ใช้ PersistentIdentifier แทน Memo โดยตรง
    @State private var selectionID: PersistentIdentifier?
    @State private var searchText: String = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selectionID) {
                ForEach(filteredMemos) { memo in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(for: memo))
                            .font(.headline)
                            .lineLimit(1)
                        Text(memo.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    // สำคัญ: ให้แถวรู้ว่า tag/selection คือ memo ตัวไหน
                    .tag(memo.persistentModelID)
                    // (ไม่จำเป็น แต่ช่วย UX) คลิกตรงไหนของแถวก็เลือกได้
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectionID = memo.persistentModelID
                    }
                }
                .onDelete(perform: deleteMemos)
            }
            .searchable(text: $searchText)
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        let new = Memo(text: "")
                        modelContext.insert(new)
                        // เลือกโน้ตใหม่ทันที
                        selectionID = new.persistentModelID
                        try? modelContext.save()
                    } label: {
                        Label("New", systemImage: "plus")
                    }

                    if let selID = selectionID, let memo = memo(for: selID) {
                        Button(role: .destructive) {
                            modelContext.delete(memo)
                            try? modelContext.save()
                            // จัด selection ใหม่หลังลบ
                            selectionID = filteredMemos.first?.persistentModelID
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .onAppear {
                // เปิดแอปให้เลือกโน้ตแรกอัตโนมัติถ้ายังไม่ได้เลือก
                if selectionID == nil { selectionID = filteredMemos.first?.persistentModelID }
            }
        } detail: {
            if let selID = selectionID, let memo = memo(for: selID) {
                MemoEditor(memo: memo)
                    .navigationTitle("Edit")
            } else {
                ContentPlaceholder()
            }
        }
    }

    // MARK: - Helpers

    private var filteredMemos: [Memo] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return memos }
        return memos.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    private func title(for memo: Memo) -> String {
        let first = memo.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return first.isEmpty ? "Untitled" : first
    }

    private func memo(for id: PersistentIdentifier) -> Memo? {
        memos.first { $0.persistentModelID == id }
    }

    private func deleteMemos(at offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(filteredMemos[index])
            }
            try? modelContext.save()
            // ถ้า selection เดิมหายไป ให้เลื่อนไปอันแรกที่เหลือ
            if let sel = selectionID, memo(for: sel) == nil {
                selectionID = filteredMemos.first?.persistentModelID
            }
        }
    }
}

struct ContentPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "note.text")
                .font(.system(size: 46))
                .symbolRenderingMode(.hierarchical)
            Text("Select or create a note")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Memo.self, inMemory: true)
}
