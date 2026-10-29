//
//  AutomationTree.swift
//  PlayTools
//

import Foundation
import UIKit

/// The UI as `tree` and `find` report it: the window's views, plus the accessibility elements apps expose without
/// views of their own (SwiftUI, web content, many custom-drawn controls), which carry the visible text and
/// whether something is a button. Frames are in window points.
enum AutomationTree {
    struct Options {
        let maxDepth: Int
        let visibleOnly: Bool

        init(_ args: [String: Any]) {
            maxDepth = args["depth"] as? Int ?? 64
            visibleOnly = args["all"] as? Bool != true
        }
    }

    static func describe(_ object: NSObject, in window: UIWindow, path: String, depth: Int,
                         options: Options) -> [String: Any]? {
        if options.visibleOnly && !isVisible(object, in: window) {
            return nil
        }
        var node = summary(of: object, in: window, path: path)
        if depth < options.maxDepth {
            let children = children(of: object, path: path).compactMap { child, childPath in
                describe(child, in: window, path: childPath, depth: depth + 1, options: options)
            }
            if !children.isEmpty {
                node["children"] = children
            }
        }
        return node
    }

    /// Visits every visible node, parents before children
    static func walk(_ object: NSObject, in window: UIWindow, path: String, _ visit: ([String: Any]) -> Void) {
        guard isVisible(object, in: window) else { return }
        visit(summary(of: object, in: window, path: path))
        for (child, childPath) in children(of: object, path: path) {
            walk(child, in: window, path: childPath, visit)
        }
    }

    /// Subviews (paths 0.1.2) and accessibility elements that are not views themselves (paths 0.1.a2)
    private static func children(of object: NSObject, path: String) -> [(NSObject, String)] {
        var result: [(NSObject, String)] = []
        if let view = object as? UIView {
            result += view.subviews.enumerated().map { ($1, "\(path).\($0)") }
        }
        result += accessibilityChildren(of: object).enumerated().map { ($1, "\(path).a\($0)") }
        return result
    }

    private static func accessibilityChildren(of object: NSObject) -> [NSObject] {
        var elements = object.accessibilityElements as? [NSObject] ?? []
        if elements.isEmpty {
            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                elements = (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
        }
        // Views are reached through subviews already
        return elements.filter { !($0 is UIView) }
    }

    static func frame(of object: NSObject, in window: UIWindow) -> CGRect {
        if let view = object as? UIView {
            return view.convert(view.bounds, to: window)
        }
        return window.convert(object.accessibilityFrame, from: window.screen.coordinateSpace)
    }

    static func isVisible(_ object: NSObject, in window: UIWindow) -> Bool {
        if let view = object as? UIView, view.isHidden || view.alpha <= 0.01 {
            return false
        }
        let frame = frame(of: object, in: window)
        return !frame.isEmpty && window.bounds.intersects(frame)
    }

    static func summary(of object: NSObject, in window: UIWindow, path: String) -> [String: Any] {
        let frame = frame(of: object, in: window)
        var node: [String: Any] = [
            "path": path,
            "class": String(describing: type(of: object)),
            "frame": [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) },
            "center": [frame.midX, frame.midY].map { Double($0) }
        ]
        let traits = traitNames(object.accessibilityTraits)
        if !traits.isEmpty {
            node["traits"] = traits
        }
        if let view = object as? UIView {
            node["interactive"] = view.isUserInteractionEnabled && (view is UIControl || !traits.isEmpty)
            if let text = text(of: view), !text.isEmpty {
                node["text"] = text
            }
            if let control = view as? UIControl {
                node["enabled"] = control.isEnabled
                node["selected"] = control.isSelected
            }
            if view.isFirstResponder {
                node["focused"] = true
            }
        } else {
            node["interactive"] = traits.contains(where: ["button", "link", "adjustable", "keyboardKey"].contains)
        }
        if let label = object.accessibilityLabel, !label.isEmpty {
            node["label"] = label
        }
        if let value = object.accessibilityValue, !value.isEmpty {
            node["value"] = value
        }
        if let identifier = identifier(of: object), !identifier.isEmpty {
            node["identifier"] = identifier
        }
        return node
    }

    /// accessibilityIdentifier, which a cast to UIAccessibilityIdentification does not reach for every object
    private static func identifier(of object: NSObject) -> String? {
        if let view = object as? UIView {
            return view.accessibilityIdentifier
        }
        guard object.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return object.value(forKey: "accessibilityIdentifier") as? String
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

    private static let traitList: [(UIAccessibilityTraits, String)] = [
        (.button, "button"), (.link, "link"), (.header, "header"), (.searchField, "searchField"),
        (.image, "image"), (.selected, "selected"), (.staticText, "staticText"), (.notEnabled, "notEnabled"),
        (.adjustable, "adjustable"), (.keyboardKey, "keyboardKey"), (.tabBar, "tabBar"),
        (.updatesFrequently, "updatesFrequently")
    ]

    private static func traitNames(_ traits: UIAccessibilityTraits) -> [String] {
        traitList.filter { traits.contains($0.0) }.map { $0.1 }
    }
}

/// Matches nodes by any of text, label, value, identifier (case-insensitive substrings, or whole when exact),
/// class and path
struct ElementQuery: CustomStringConvertible {
    private let fields: [(name: String, wanted: String)]
    let exact: Bool

    init(_ args: [String: Any]) {
        fields = ["text", "label", "identifier", "class", "path"].compactMap { name in
            (args[name] as? String).map { (name, $0) }
        }
        exact = args["exact"] as? Bool ?? false
    }

    var isEmpty: Bool {
        fields.isEmpty
    }

    var description: String {
        fields.map { "\($0.name) '\($0.wanted)'" }.joined(separator: ", ")
    }

    func matches(_ node: [String: Any]) -> Bool {
        !fields.isEmpty && fields.allSatisfy { name, wanted in
            switch name {
            case "path":
                return node["path"] as? String == wanted
            case "text":
                // What the user reads: a view's text, or an accessibility label or value
                return ["text", "label", "value"].contains { compare(node[$0] as? String, wanted) }
            default:
                return compare(node[name] as? String, wanted)
            }
        }
    }

    private func compare(_ value: String?, _ wanted: String) -> Bool {
        guard let value = value else { return false }
        return exact ? value == wanted : value.localizedCaseInsensitiveContains(wanted)
    }
}
