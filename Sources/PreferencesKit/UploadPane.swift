import AppKit
import SwiftUI
import ShotcraftCore

struct UploadPane: View {
    @Default(.uploadDestination) private var destination
    @Default(.uploadCopyLinkWhenStarts) private var copyLinkWhenStarts
    @Default(.uploadMaxImageWidth) private var maxImageWidth
    @Default(.s3Endpoint) private var s3Endpoint
    @Default(.s3Region) private var s3Region
    @Default(.s3Bucket) private var s3Bucket
    @Default(.s3AccessKeyID) private var s3AccessKeyID
    @Default(.s3PublicURLPrefix) private var s3PublicURLPrefix
    @Default(.s3PathPrefix) private var s3PathPrefix
    @Default(.customHTTPEndpoint) private var httpEndpoint
    @Default(.customHTTPFieldName) private var httpFieldName
    @Default(.customHTTPHeaders) private var httpHeaders
    @Default(.customHTTPResponseURLPath) private var httpResponsePath
    @Default(.uploadFolderPath) private var folderPath
    @Default(.uploadFolderURLPrefix) private var folderURLPrefix

    @State private var secretKey = ""
    @State private var storedSecretKey = ""
    @State private var headerRows: [HeaderRow] = []
    @State private var testState: TestState = .idle
    @State private var recent: [UploadRecord] = []

    enum TestState: Equatable { case idle, running, success(URL), failure(String) }

    private static let widthChoices = [0, 800, 1280, 1600, 1920, 2560, 3840]

    var body: some View {
        PaneForm(pane: .upload) {
            Section {
                Picker("Destination", selection: $destination) {
                    ForEach(UploadDestinationKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } footer: {
                HelpText(destinationHelp)
            }

            switch destination {
            case .none: EmptyView()
            case .s3: s3Section
            case .customHTTP: httpSection
            case .folder: folderSection
            }

            if destination != .none {
                Section {
                    HStack(spacing: 10) {
                        Button("Test Connection") { runTest() }
                            .disabled(testState == .running || Services.upload == nil)
                        testStatus
                        Spacer(minLength: 0)
                    }
                } footer: {
                    HelpText("Uploads a tiny test file with the settings above and removes it again where possible.")
                }
            }

            Section("Options") {
                Toggle("Copy link when upload starts", isOn: $copyLinkWhenStarts)
                Picker(selection: $maxImageWidth) {
                    ForEach(maxWidthChoices, id: \.self) { Text($0 == 0 ? "Original size" : "\($0) px").tag($0) }
                } label: {
                    Text("Maximum image width")
                    Text("Larger screenshots are scaled down before uploading.")
                }
            }

            Section("Recent uploads") {
                if recent.isEmpty {
                    Text("Nothing uploaded yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(recent.prefix(10), id: \.self) { RecentUploadRow(record: $0) }
                }
            }
        }
        .onAppear(perform: load)
    }

    // MARK: Sections

    private var s3Section: some View {
        Section("S3-compatible storage") {
            TextField("Endpoint", text: $s3Endpoint, prompt: Text("https://s3.us-east-1.amazonaws.com"))
            TextField("Region", text: $s3Region, prompt: Text("us-east-1"))
            TextField("Bucket", text: $s3Bucket, prompt: Text("my-screenshots"))
            TextField("Access key ID", text: $s3AccessKeyID)
                .autocorrectionDisabled()
            SecureField("Secret access key", text: $secretKey)
                .onChange(of: secretKey) { _, new in
                    guard new != storedSecretKey else { return }
                    Keychain.set(new, for: Keychain.s3SecretKeyAccount)
                    storedSecretKey = new
                }
            TextField(text: $s3PathPrefix, prompt: Text("shotcraft/")) {
                Text("Path prefix")
                Text("Folder inside the bucket.")
            }
            TextField(text: $s3PublicURLPrefix, prompt: Text("https://cdn.example.com/")) {
                Text("Public URL prefix")
                Text("Used to build the shared link; leave empty to use the bucket URL.")
            }
        }
    }

    private var httpSection: some View {
        Section("Custom HTTP endpoint") {
            TextField("Endpoint URL", text: $httpEndpoint, prompt: Text("https://example.com/upload"))
            TextField(text: $httpFieldName, prompt: Text("file")) {
                Text("File field name")
                Text("Name of the multipart form field carrying the file.")
            }
            TextField(text: $httpResponsePath, prompt: Text("url")) {
                Text("Link path in JSON response")
                Text("Dot-separated, e.g. data.link. Leave empty if the response body is the link itself.")
            }
            LabeledContent("Headers") {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach($headerRows) { $row in
                        HStack {
                            TextField("Name", text: $row.name, prompt: Text("Authorization")).frame(minWidth: 110)
                            TextField("Value", text: $row.value, prompt: Text("Bearer …"))
                            Button { headerRows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Remove header")
                        }
                        .labelsHidden()
                    }
                    Button { headerRows.append(HeaderRow(name: "", value: "")) } label: {
                        Label("Add Header", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onChange(of: headerRows) { _, rows in
                let dict = HeaderRow.dictionary(from: rows)
                if dict != httpHeaders { httpHeaders = dict }
            }
        }
    }

    private var folderSection: some View {
        Section("Synced folder") {
            FolderRow(title: "Folder", path: $folderPath, placeholder: "Choose a Dropbox, iCloud Drive or web-served folder")
            TextField(text: $folderURLPrefix, prompt: Text("https://files.example.com/shots/")) {
                Text("URL prefix")
                Text("The file name is appended to build the shared link.")
            }
        }
    }

    // MARK: Helpers

    private var destinationHelp: String {
        switch destination {
        case .none: "Choose where uploaded screenshots and recordings go. Nothing is uploaded until you set this up."
        case .s3: "Works with Amazon S3, Cloudflare R2, Backblaze B2, MinIO and other S3-compatible services."
        case .customHTTP: "Sends the file as multipart/form-data and reads the link from the response."
        case .folder: "Copies the file into a folder and builds a link from your URL prefix."
        }
    }

    private var maxWidthChoices: [Int] {
        Self.widthChoices.contains(maxImageWidth) ? Self.widthChoices : (Self.widthChoices + [maxImageWidth]).sorted()
    }

    @ViewBuilder private var testStatus: some View {
        switch testState {
        case .idle: EmptyView()
        case .running:
            ProgressView().controlSize(.small)
            Text("Testing…").foregroundStyle(.secondary)
        case .success(let url):
            Label("Connection works", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Link(url.absoluteString, destination: url).lineLimit(1).truncationMode(.middle).font(.callout)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                .lineLimit(3).textSelection(.enabled)
        }
    }

    private func load() {
        storedSecretKey = Keychain.get(Keychain.s3SecretKeyAccount) ?? ""
        secretKey = storedSecretKey
        headerRows = HeaderRow.rows(from: httpHeaders)
        recent = Services.upload?.recentUploads ?? []
    }

    private func runTest() {
        guard let upload = Services.upload else { return }
        // Commit any field still being edited before testing.
        NSApp.keyWindow?.makeFirstResponder(nil)
        testState = .running
        upload.testConnection { result in
            switch result {
            case .success(let url): testState = .success(url)
            case .failure(let error): testState = .failure(error.localizedDescription)
            }
            recent = upload.recentUploads
        }
    }
}

private struct RecentUploadRow: View {
    let record: UploadRecord

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Button { Clipboard.copy(url: record.url); HUD.show("Link has been copied", symbol: "link") } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy Link")
                Button { NSWorkspace.shared.open(record.url) } label: { Image(systemName: "safari") }
                    .help("Open in Browser")
            }
            .buttonStyle(.borderless)
        } label: {
            Text(record.fileName).lineLimit(1).truncationMode(.middle)
            Text("\(record.url.absoluteString) · \(record.date.formatted(.relative(presentation: .named)))")
                .lineLimit(1).truncationMode(.middle)
        }
    }
}
