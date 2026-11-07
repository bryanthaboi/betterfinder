import AppKit
import FSCore
import Remote
import SwiftUI

@MainActor
final class ConnectToServerModel: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case sftp = "SFTP"
        case s3 = "S3"
        var id: String { rawValue }
    }

    @Published var kind: Kind = .sftp
    @Published var name = ""
    @Published var sftpAddress = ""
    @Published var keyFile = ""
    @Published var endpoint = ""
    @Published var region = "us-east-1"
    @Published var bucket = ""
    @Published var prefix = ""
    @Published var accessKey = ""
    @Published var secretKey = ""
    @Published var allowHTTP = false
    @Published var isConnecting = false
    @Published var errorMessage: String?

    var onDone: ((ProvidedLocation?) -> Void)?
    var integration: RemoteIntegration = .shared
    private var task: Task<Void, Never>?

    var canConnect: Bool {
        guard !isConnecting else { return false }
        switch kind {
        case .sftp: return SFTPConfiguration.parse(sftpAddress) != nil
        case .s3: return !bucket.trimmingCharacters(in: .whitespaces).isEmpty && !accessKey.isEmpty && !secretKey.isEmpty
        }
    }

    func makeServer() throws -> (RemoteServer, Data?) {
        let label = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .sftp:
            guard let c = SFTPConfiguration.parse(sftpAddress, identityFile: keyFile.isEmpty ? nil : keyFile) else {
                throw ResourceError.invalidName(sftpAddress)
            }
            try c.validate()
            return (RemoteServer(name: label, kind: .sftp(c)), nil)
        case .s3:
            let c = S3Configuration(endpoint: endpoint, region: region, bucket: bucket, prefix: prefix, allowInsecureHTTP: allowHTTP)
            try c.validate()
            let creds = AWSCredentials(accessKeyID: accessKey.trimmingCharacters(in: .whitespaces), secretAccessKey: secretKey)
            return (RemoteServer(name: label, kind: .s3(c)), try creds.encoded())
        }
    }

    func connect() {
        errorMessage = nil
        let server: RemoteServer
        let secret: Data?
        do { (server, secret) = try makeServer() } catch {
            errorMessage = error.localizedDescription
            return
        }
        isConnecting = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let loc = try await self.integration.add(server, secret: secret)
                self.isConnecting = false
                self.secretKey = ""
                self.onDone?(loc)
            } catch {
                self.isConnecting = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        isConnecting = false
        onDone?(nil)
    }

    func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.prompt = "Use Key"
        if panel.runModal() == .OK, let u = panel.url { keyFile = u.path }
    }
}

struct ConnectToServerView: View {
    @ObservedObject var model: ConnectToServerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Server").font(.headline)
            Picker("Type", selection: $model.kind) {
                ForEach(ConnectToServerModel.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Server type")
            Form {
                TextField("Name", text: $model.name, prompt: Text("Optional"))
                if model.kind == .sftp {
                    TextField("Address", text: $model.sftpAddress, prompt: Text("user@host:22/path"))
                    HStack {
                        TextField("Key file", text: $model.keyFile, prompt: Text("ssh-agent / Keychain"))
                        Button("Choose…") { model.chooseKey() }
                    }
                    Text("Uses your SSH keys and agent. Passwords aren’t supported. Unknown hosts ask you to confirm their fingerprint first.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField("Endpoint", text: $model.endpoint, prompt: Text("Amazon S3, or https://… for R2/MinIO"))
                    TextField("Region", text: $model.region, prompt: Text("us-east-1 (use auto for R2)"))
                    TextField("Bucket", text: $model.bucket)
                    TextField("Folder", text: $model.prefix, prompt: Text("Optional prefix"))
                    TextField("Access key ID", text: $model.accessKey)
                    SecureField("Secret access key", text: $model.secretKey)
                    Toggle("Allow plain HTTP to this endpoint", isOn: $model.allowHTTP)
                    Text("Keys are stored in your login Keychain and are only ever sent to this endpoint and bucket.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let e = model.errorMessage {
                Text(e).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(e)")
            }
            HStack {
                if model.isConnecting { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("Connect") { model.connect() }.keyboardShortcut(.defaultAction).disabled(!model.canConnect)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

@MainActor
enum ConnectToServerSheet {
    private static var active: [ObjectIdentifier: NSWindow] = [:]

    static func present(for parent: NSWindow?, integration: RemoteIntegration? = nil, completion: @escaping (ProvidedLocation) -> Void) {
        let model = ConnectToServerModel()
        model.integration = integration ?? .shared
        let host = NSHostingController(rootView: ConnectToServerView(model: model))
        let sheet = NSWindow(contentViewController: host)
        sheet.title = "Connect to Server"
        let key = ObjectIdentifier(sheet)
        active[key] = sheet
        model.onDone = { [weak sheet] loc in
            if let sheet {
                if let p = sheet.sheetParent { p.endSheet(sheet) } else { sheet.close() }
            }
            active[key] = nil
            if let loc { completion(loc) }
        }
        if let parent { parent.beginSheet(sheet) } else { sheet.center(); sheet.makeKeyAndOrderFront(nil) }
    }
}
