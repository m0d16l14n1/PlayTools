//
//  AutomationCommands.swift
//  PlayTools
//

import Foundation
import UIKit

/// The commands of AutomationServer. Coordinates are points in the app's window, the same space as the frames
/// `tree` and `find` report. Every handler runs on the main thread and calls `reply` exactly once.
enum AutomationCommands {
    typealias Reply = ([String: Any]) -> Void

    private static let handlers: [String: ([String: Any], @escaping Reply) throws -> Void] = [
        "info": { _, reply in reply(info()) },
        "tree": { args, reply in reply(try tree(args)) },
        "find": { args, reply in reply(try find(args)) },
        "tap": { args, reply in try tap(args, reply: reply) },
        "longpress": { args, reply in try tap(args, hold: args["duration"] as? Double ?? 1, reply: reply) },
        "swipe": { args, reply in try swipe(args, reply: reply) },
        "type": { args, reply in reply(try typeText(args)) },
        "key": { args, reply in reply(try key(args)) },
        "screenshot": { args, reply in reply(try screenshot(args)) }
    ]

    static func run(_ command: String, args: [String: Any], reply: @escaping Reply) {
        guard let handler = handlers[command] else {
            reply(failure("Unknown command '\(command)'. Known: \(handlers.keys.sorted().joined(separator: ", "))"))
            return
        }
        do {
            try handler(args, reply)
        } catch {
            reply(failure("\(error)"))
        }
    }

    static func failure(_ message: String) -> [String: Any] {
        ["ok": false, "error": message]
    }

    // MARK: - Windows
    private static var windows: [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { !$0.isHidden }
    }

    private static func mainWindow() throws -> UIWindow {
        guard let window = PlayScreen.shared.keyWindow ?? windows.first else {
            throw AutomationError("The app has no window yet")
        }
        return window
    }

    private static func info() -> [String: Any] {
        let window = try? mainWindow()
        var result: [String: Any] = [
            "ok": true,
            "bundleIdentifier": Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? "",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "device": PlaySettings.shared.deviceModel as String,
            "windows": windows.count
        ]
        if let window = window {
            result["window"] = [
                "width": window.bounds.width, "height": window.bounds.height, "scale": window.screen.scale,
                "number": window.nsWindow?.value(forKey: "windowNumber") as? Int ?? 0
            ]
            if let focused = firstResponder(in: window) {
                result["focused"] = String(describing: type(of: focused))
            }
        }
        return result
    }

    // MARK: - Inspection
    private static func tree(_ args: [String: Any]) throws -> [String: Any] {
        let window = try mainWindow()
        let options = AutomationTree.Options(args)
        return ["ok": true, "root": AutomationTree.describe(window, in: window, path: "0", depth: 0,
                                                            options: options) ?? [:]]
    }

    private static func find(_ args: [String: Any]) throws -> [String: Any] {
        let window = try mainWindow()
        let query = ElementQuery(args)
        var matches: [[String: Any]] = []
        AutomationTree.walk(window, in: window, path: "0") { summary in
            if query.matches(summary) {
                matches.append(summary)
            }
        }
        return ["ok": true, "matches": matches]
    }

    // MARK: - Input
    private static func point(_ args: [String: Any], _ xKey: String = "x", _ yKey: String = "y") throws -> CGPoint {
        if let pointX = args[xKey] as? Double, let pointY = args[yKey] as? Double {
            return CGPoint(x: pointX, y: pointY)
        }
        // Or the center of the first visible element that matches, preferring ones that take touches
        let query = ElementQuery(args)
        guard !query.isEmpty else {
            throw AutomationError("Give \(xKey) and \(yKey), or text, label, identifier, class or path")
        }
        let window = try mainWindow()
        var matches: [[String: Any]] = []
        AutomationTree.walk(window, in: window, path: "0") { summary in
            if query.matches(summary) {
                matches.append(summary)
            }
        }
        guard let match = matches.first(where: { $0["interactive"] as? Bool == true }) ?? matches.first,
              let center = match["center"] as? [Double], center.count == 2 else {
            throw AutomationError("No visible element matches \(query)")
        }
        return CGPoint(x: center[0], y: center[1])
    }

    private static func tap(_ args: [String: Any], hold: Double = 0.05, reply: @escaping Reply) throws {
        let target = try point(args)
        let touch = try FakeTouch(at: target)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            touch.end(at: target)
            reply(["ok": true, "x": Double(target.x), "y": Double(target.y)])
        }
    }

    private static func swipe(_ args: [String: Any], reply: @escaping Reply) throws {
        let start = try point(args, "x1", "y1")
        let end = try point(args, "x2", "y2")
        let duration = max(args["duration"] as? Double ?? 0.3, 0.05)
        let steps = max(Int(duration * 60), 2)
        let touch = try FakeTouch(at: start)
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let current = CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * Double(progress)) {
                if step == steps {
                    touch.end(at: current)
                    reply(["ok": true])
                } else {
                    touch.move(to: current)
                }
            }
        }
    }

    private static func typeText(_ args: [String: Any]) throws -> [String: Any] {
        guard let text = args["text"] as? String else { throw AutomationError("Give text") }
        try keyInput().insertText(text)
        return ["ok": true]
    }

    private static func key(_ args: [String: Any]) throws -> [String: Any] {
        let input = try keyInput()
        switch args["key"] as? String ?? "" {
        case "return", "enter":
            // A text field reacts to the Return key, not to an inserted newline: do what the keyboard does
            if let field = input as? UITextField {
                if field.delegate?.textFieldShouldReturn?(field) ?? true {
                    field.sendActions(for: .editingDidEndOnExit)
                }
            } else {
                input.insertText("\n")
            }
        case "tab":
            input.insertText("\t")
        case "delete", "backspace":
            input.deleteBackward()
        default:
            throw AutomationError("Known keys: return, tab, delete")
        }
        return ["ok": true]
    }

    private static func keyInput() throws -> UIKeyInput {
        guard let input = windows.lazy.compactMap({ firstResponder(in: $0) as? UIKeyInput }).first else {
            throw AutomationError("No text field has focus; tap one first")
        }
        return input
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder {
            return view
        }
        return view.subviews.lazy.compactMap { firstResponder(in: $0) }.first
    }

    // MARK: - Screenshot
    private static func screenshot(_ args: [String: Any]) throws -> [String: Any] {
        let window = try mainWindow()
        let format = UIGraphicsImageRendererFormat()
        format.scale = args["scale"] as? Double ?? window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let png = image.pngData() else { throw AutomationError("The window could not be rendered") }
        return ["ok": true, "png": png.base64EncodedString(),
                "width": Double(image.size.width * format.scale), "height": Double(image.size.height * format.scale)]
    }
}

/// One finger on the screen, through PlayTools' touch injection (the same path keymapping uses)
private final class FakeTouch {
    private var touchID: Int?
    private let window: UIWindow
    private let view: UIView?

    init(at point: CGPoint) throws {
        guard let window = PlayScreen.shared.keyWindow ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first(where: { !$0.isHidden }) else {
            throw AutomationError("The app has no window yet")
        }
        self.window = window
        view = window.hitTest(point, with: nil)
        send(point, .began)
    }

    func move(to point: CGPoint) {
        send(point, .moved)
    }

    func end(at point: CGPoint) {
        send(point, .ended)
    }

    private func send(_ point: CGPoint, _ phase: UITouch.Phase) {
        let result = PTFakeMetaTouch.fakeTouchId(touchID ?? -1, at: point, with: phase, in: window, on: view)
        touchID = result < 0 ? nil : result
    }
}

struct AutomationError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
