//
//  PlayInformation.swift
//  PlayTools
//

import Foundation

class PlayInfo: NSObject {
    static var isLauncherInstalled: Bool {
        return AKInterface.shared!
            .urlForApplicationWithBundleIdentifier("io.playcover.PlayCover") != nil
    }

    /// PlayCover's library, where this app's settings, keymaps and PlayChain live. PlayCover moved it out of
    /// ~/Library/Containers/io.playcover.PlayCover, a protected app container that made macOS ask whether the app may
    /// "access data from other apps". An older PlayCover still uses the container. The real home folder is spelled
    /// out because NSHomeDirectory() is the app's own sandbox container.
    static let playCoverLibrary: URL = {
        let home = URL(fileURLWithPath: "/Users/\(NSUserName())")
        let library = home.appendingPathComponent("Library/Application Support/io.playcover.PlayCover")
        let legacy = home.appendingPathComponent("Library/Containers/io.playcover.PlayCover")
        return FileManager.default.fileExists(atPath: library.appendingPathComponent("App Settings").path)
            ? library : legacy
    }()

    @objc static var isUnrealEngine: Bool {
        let appFolder = Bundle.main.bundleURL
        let ueFiles: [URL] = [
            appFolder.appendingPathComponent("ue4commandline.txt"),
            appFolder.appendingPathComponent("uecommandline.txt")
        ]

        for ueFile in ueFiles where FileManager.default.fileExists(atPath: ueFile.path) {
            return true
        }
        return false
    }
}

extension ProcessInfo {
    @objc open var isMacCatalystApp: Bool {
        return false
    }
    @objc open var isiOSAppOnMac: Bool {
        return true
    }
    @objc open var thermalState: ProcessInfo.ThermalState {
        return ProcessInfo.ThermalState.nominal
    }
    @objc open var isLowPowerModeEnabled: Bool {
        return false
    }
}
