//
//  AutomationServer.swift
//  PlayTools
//

import Foundation
import Network

/// Lets `playcover automate` inspect and drive the app: a loopback-only TCP server, started when the app's
/// "automation" setting is on. Every request carries a random token that is only written to a file in PlayCover's
/// library, next to the app's settings.
///
/// Protocol: one JSON object per line in each direction.
/// Request `{"token": "...", "command": "tap", "args": {...}}`, response `{"ok": true, ...}` or
/// `{"ok": false, "error": "..."}`. The commands are in AutomationCommands.
class AutomationServer {
    static let shared = AutomationServer()

    private let queue = DispatchQueue(label: "io.playcover.PlayTools.automation")
    private var listener: NWListener?
    private let token = UUID().uuidString
    private let bundleIdentifier = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""

    /// `<PlayCover library>/Automation/<bundle id>.json`; NSHomeDirectory() is the app's own sandbox container
    private var endpointURL: URL {
        URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("Automation")
            .appendingPathComponent("\(bundleIdentifier).json")
    }

    /// Read on its own rather than through PlaySettings: a key the settings struct does not know would make the
    /// whole settings file fail to decode when an older PlayCover wrote it
    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["PLAYTOOLS_AUTOMATION"] == "1" {
            return true
        }
        struct Flag: Decodable { var automation: Bool? }
        guard let data = try? Data(contentsOf: PlaySettings.shared.settingsUrl),
              let flag = try? PropertyListDecoder().decode(Flag.self, from: data) else { return false }
        return flag.automation ?? false
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.writeEndpoint(port: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    print("[PlayTools] Automation server failed: \(error)")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("[PlayTools] Automation server could not start: \(error)")
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSApplicationWillTerminateNotification"),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.stop()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: endpointURL)
    }

    private func writeEndpoint(port: UInt16) {
        let endpoint: [String: Any] = [
            "bundleIdentifier": bundleIdentifier,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "port": Int(port),
            "token": token,
            "protocol": 1
        ]
        do {
            try FileManager.default.createDirectory(at: endpointURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: endpoint, options: [.sortedKeys])
            try data.write(to: endpointURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpointURL.path)
        } catch {
            print("[PlayTools] Automation endpoint could not be written: \(error)")
        }
    }

    // MARK: - Connections
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isDone, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data {
                buffer.append(data)
            }
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                self.handle(Data(line), on: connection)
            }
            if isDone || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(_ line: Data, on connection: NWConnection) {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            send(["ok": false, "error": "Malformed request"], on: connection)
            return
        }
        guard request["token"] as? String == token else {
            send(["ok": false, "error": "Invalid token"], on: connection)
            return
        }
        let command = request["command"] as? String ?? ""
        let args = request["args"] as? [String: Any] ?? [:]
        // UIKit is main-thread only; commands that take time (touches) answer when they are done
        DispatchQueue.main.async {
            AutomationCommands.run(command, args: args) { [weak self] response in
                self?.send(response, on: connection)
            }
        }
    }

    private func send(_ response: [String: Any], on connection: NWConnection) {
        var data = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]))
            ?? Data("{\"ok\":false,\"error\":\"Response could not be encoded\"}".utf8)
        data.append(UInt8(ascii: "\n"))
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
