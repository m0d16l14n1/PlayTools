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
            result["focused"] = firstResponder(in: window).map { String(describing: type(of: $0)) } ?? NSNull()
        }
        return result
    }

    // MARK: - Inspection
    private static func tree(_ args: [String: Any]) throws -> [String: Any] {
        let window = try mainWindow()
        let options = TreeOptions(args)
        return ["ok": true, "root": describe(window, in: window, path: "0", depth: 0, options: options) ?? [:]]
    }

    private static func find(_ args: [String: Any]) throws -> [String: Any] {
        let window = try mainWindow()
        let query = ElementQuery(args)
        var matches: [[String: Any]] = []
        walk(window, in: window, path: "0") { view, path in
            if query.matches(view, in: window, path: path) {
                var element = summary(of: view, in: window)
                element["path"] = path
                matches.append(element)
            }
        }
        return ["ok": true, "matches": matches]
    }

    struct TreeOptions {
        let maxDepth: Int
        let visibleOnly: Bool

        init(_ args: [String: Any]) {
            maxDepth = args["depth"] as? Int ?? 64
            visibleOnly = args["all"] as? Bool != true
        }
    }

    private static func describe(_ view: UIView, in window: UIWindow, path: String, depth: Int,
                                 options: TreeOptions) -> [String: Any]? {
        if options.visibleOnly && !isVisible(view, in: window) {
            return nil
        }
        var node = summary(of: view, in: window)
        node["path"] = path
        if depth < options.maxDepth {
            let children = view.subviews.enumerated().compactMap { index, child in
                describe(child, in: window, path: "\(path).\(index)", depth: depth + 1, options: options)
            }
            if !children.isEmpty {
                node["children"] = children
            }
        }
        return node
    }

    private static func walk(_ view: UIView, in window: UIWindow, path: String,
                             _ visit: (UIView, String) -> Void) {
        guard isVisible(view, in: window) else { return }
        visit(view, path)
        for (index, child) in view.subviews.enumerated() {
            walk(child, in: window, path: "\(path).\(index)", visit)
        }
    }

    static func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        !view.isHidden && view.alpha > 0.01 && window.bounds.intersects(view.convert(view.bounds, to: window))
    }

    static func summary(of view: UIView, in window: UIWindow) -> [String: Any] {
        let frame = view.convert(view.bounds, to: window)
        var element: [String: Any] = [
            "class": String(describing: type(of: view)),
            "frame": [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) },
            "center": [frame.midX, frame.midY].map { Double($0) },
            "interactive": view.isUserInteractionEnabled
        ]
        if let text = text(of: view), !text.isEmpty {
            element["text"] = text
        }
        if let label = view.accessibilityLabel, !label.isEmpty {
            element["label"] = label
        }
        if let identifier = view.accessibilityIdentifier, !identifier.isEmpty {
            element["identifier"] = identifier
        }
        if let control = view as? UIControl {
            element["enabled"] = control.isEnabled
            element["selected"] = control.isSelected
        }
        if view.isFirstResponder {
            element["focused"] = true
        }
        return element
    }

    static func text(of view: UIView) -> String? {
        switch view {
        case let label as UILabel:
            return label.text
        case let button as UIButton:
            return button.currentTitle ?? button.titleLabel?.text
        case let field as UITextField:
            return field.text?.isEmpty == false ? field.text : field.placeholder
        case let textView as UITextView:
            return textView.text
        default:
            return nil
        }
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
        var matches: [UIView] = []
        walk(window, in: window, path: "0") { view, path in
            if query.matches(view, in: window, path: path) {
                matches.append(view)
            }
        }
        guard let view = matches.first(where: { $0.isUserInteractionEnabled }) ?? matches.first else {
            throw AutomationError("No visible element matches \(query)")
        }
        let frame = view.convert(view.bounds, to: window)
        return CGPoint(x: frame.midX, y: frame.midY)
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
            input.insertText("\n")
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

/// Matches elements by any of text, label, identifier (case-insensitive substrings, or whole when exact) and class
struct ElementQuery: CustomStringConvertible {
    let text: String?
    let label: String?
    let identifier: String?
    let className: String?
    let path: String?
    let exact: Bool

    init(_ args: [String: Any]) {
        text = args["text"] as? String
        label = args["label"] as? String
        identifier = args["identifier"] as? String
        className = args["class"] as? String
        path = args["path"] as? String
        exact = args["exact"] as? Bool ?? false
    }

    var isEmpty: Bool {
        [text, label, identifier, className, path].allSatisfy { $0 == nil }
    }

    var description: String {
        [("text", text), ("label", label), ("identifier", identifier), ("class", className), ("path", path)]
            .compactMap { name, value in value.map { "\(name) '\($0)'" } }
            .joined(separator: ", ")
    }

    func matches(_ view: UIView, in window: UIWindow, path viewPath: String? = nil) -> Bool {
        guard !isEmpty else { return false }
        if let path = path, path != viewPath {
            return false
        }
        if let className = className, !compare(String(describing: type(of: view)), className) {
            return false
        }
        if let identifier = identifier, !compare(view.accessibilityIdentifier, identifier) {
            return false
        }
        if let label = label, !compare(view.accessibilityLabel, label) {
            return false
        }
        if let text = text,
           !compare(AutomationCommands.text(of: view), text), !compare(view.accessibilityLabel, text) {
            return false
        }
        return true
    }

    private func compare(_ value: String?, _ wanted: String) -> Bool {
        guard let value = value else { return false }
        return exact ? value == wanted : value.localizedCaseInsensitiveContains(wanted)
    }
}

struct AutomationError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
