import FTPKit
import SwiftUI

/// Edits the bookmarks of the current connection.
struct BookmarksView: View {
    @Environment(AppModel.self) private var app
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var list: [Bookmark] = []
    @State private var selection: Bookmark.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(list) { b in
                            Label(b.name.isEmpty ? String(localized: "Adsız") : b.name, systemImage: "bookmark")
                                .tag(b.id)
                        }
                        .onMove { list.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.sidebar)
                    Divider()
                    HStack(spacing: 2) {
                        Button {
                            let b = Bookmark(name: RemotePath.name(session.remote.path),
                                             localPath: session.local.path.path, remotePath: session.remote.path)
                            list.append(b)
                            selection = b.id
                        } label: { Image(systemName: "plus") }
                            .help("Şu anki klasörleri ekle")
                        Button {
                            list.removeAll { $0.id == selection }
                            selection = list.first?.id
                        } label: { Image(systemName: "minus") }
                            .disabled(selection == nil)
                            .help("Yer imini sil")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                }
                .frame(width: 220)
                Divider()
                if let i = list.firstIndex(where: { $0.id == selection }) {
                    Form {
                        TextField("Ad", text: $list[i].name)
                        TextField("Bu Mac'teki klasör", text: $list[i].localPath, prompt: Text("boş: değiştirme"))
                        TextField("Sunucudaki klasör", text: $list[i].remotePath, prompt: Text("boş: değiştirme"))
                        Text("Bir yer imini açmak her iki paneli de kayıtlı klasörlere götürür. Boş bırakılan taraf olduğu yerde kalır.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .formStyle(.grouped)
                } else {
                    ContentUnavailableView("Yer imi seçilmedi", systemImage: "bookmark",
                                           description: Text("Soldaki + düğmesi panellerde açık olan klasörleri ekler."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text("Yer imleri: \(session.title)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("İptal", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Kaydet") {
                    if let key = session.bookmarkKey { app.bookmarks.set(list, for: key) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 380)
        .onAppear {
            list = app.bookmarks.bookmarks(for: session.bookmarkKey)
            selection = list.first?.id
        }
    }
}
