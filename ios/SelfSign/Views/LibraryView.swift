import SwiftUI

struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @State private var showingImport = false

    var body: some View {
        Group {
            if store.apps.isEmpty {
                ContentUnavailableView {
                    Label("还没有应用", systemImage: "app.dashed")
                } description: {
                    Text("导入一个 IPA，用你的 Apple ID 签名并安装。")
                } actions: {
                    Button("导入 IPA") { showingImport = true }
                        .buttonStyle(.glassProminent)
                }
            } else {
                List {
                    ForEach(store.apps) { app in
                        AppRow(app: app)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    store.deleteApp(app)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { await store.refresh(app) }
                                } label: {
                                    Label("刷新", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .tint(.blue)
                            }
                    }
                    .onDelete { indexSet in
                        for i in indexSet { store.deleteApp(store.apps[i]) }
                    }
                }
            }
        }
        .navigationTitle("应用库")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingImport = true
                } label: {
                    Label("导入", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
            }
        }
        .fileImporter(
            isPresented: $showingImport,
            allowedContentTypes: [.init(filenameExtension: "ipa")!],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if url.startAccessingSecurityScopedResource() {
                    Task {
                        await store.importAndInstall(url)
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            case .failure(let error):
                store.lastError = error.localizedDescription
                store.phase = .failed(error.localizedDescription)
            }
        }
    }
}

private struct AppRow: View {
    @Environment(AppStore.self) private var store
    let app: SignedApp

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.regularMaterial)
                if let data = app.iconData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    Image(systemName: "app.fill")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 52)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.headline)
                Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("v\(app.version)")
                    Text("·")
                    Text(app.isExpiringSoon
                         ? "剩余 \(app.daysRemaining) 天"
                         : "剩余 \(app.daysRemaining) 天")
                        .foregroundStyle(app.isExpiringSoon ? .orange : .secondary)
                }
                .font(.caption2)
            }
            Spacer()
            Button {
                Task { await store.refresh(app) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.glass)
        }
        .padding(.vertical, 6)
    }
}
