import SwiftUI
import UIKit

/// Identifiable wrapper for share items so we can use .sheet(item:)
/// which is more reliable than .sheet(isPresented:) for multiple sheets.
private struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Lists all recorded flight files and waypoint files, with options to
/// share individual files, share everything at once, or delete.
struct FilesListView: View {
    @ObservedObject var recorder: FlightRecorder
    @Binding var isPresented: Bool
    @ObservedObject private var language = LanguagePreference.shared

    @State private var files: [URL] = []
    @State private var shareItems: ShareItems? = nil

    var body: some View {
        let _ = language.code   // re-render on language change
        NavigationView {
            List {
                if files.isEmpty {
                    Section {
                        Text(L10n.string("files_empty"))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section {
                        Button {
                            shareItems = ShareItems(urls: files)
                        } label: {
                            Label(L10n.string("share_all"), systemImage: "square.and.arrow.up")
                                .fontWeight(.semibold)
                        }
                    }

                    Section(header: Text(L10n.string("files"))) {
                        ForEach(files, id: \.self) { url in
                            FileRow(url: url,
                                    onShare: {
                                        shareItems = ShareItems(urls: [url])
                                    })
                        }
                        .onDelete { indexSet in
                            for i in indexSet {
                                recorder.deleteFile(files[i])
                            }
                            reload()
                        }
                    }
                }
            }
            .navigationTitle(L10n.string("flight_records"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("close")) { isPresented = false }
                }
            }
            .onAppear { reload() }
            .sheet(item: $shareItems) { items in
                ShareSheet(items: items.urls)
            }
        }
    }

    private func reload() {
        files = recorder.listStoredFiles()
    }
}

private struct FileRow: View {
    let url: URL
    let onShare: () -> Void

    var isSimulated: Bool {
        url.lastPathComponent.contains("_SIM")
    }

    var isIGC: Bool {
        url.pathExtension.lowercased() == "igc"
    }

    var iconName: String {
        isIGC ? "airplane" : "mappin.circle.fill"
    }

    var iconColor: Color {
        if isSimulated { return .orange }
        return isIGC ? .cyan : Color(red: 0.35, green: 0.85, blue: 1.0)
    }

    var sizeText: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size)/1024) }
        return String(format: "%.1f MB", Double(size)/(1024*1024))
    }

    var dateText: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let date = attrs?[.modificationDate] as? Date {
            let df = DateFormatter()
            df.dateFormat = "dd.MM.yyyy HH:mm"
            return df.string(from: date)
        }
        return "—"
    }

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .font(.system(size: 22))
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if isSimulated {
                        Text("SIM")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange))
                    }
                }
                HStack(spacing: 8) {
                    Text(dateText)
                    Text("•")
                    Text(sizeText)
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                onShare()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
