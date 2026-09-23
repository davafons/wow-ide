import AppKit
import CoreGraphics
import Foundation

struct TrackedTargetWindow: @unchecked Sendable {
    let id: Int
    let cgBounds: CGRect
    let workspace: String?
    let workspaceVisible: Bool
}

/// Read-only window lookup. AeroSpace supplies workspace membership while
/// CoreGraphics supplies the actual window frame. Runs off the AppKit thread.
enum TargetWindowTracker {
    private static let aerospacePaths = [
        "/opt/homebrew/bin/aerospace",
        "/usr/local/bin/aerospace"
    ]

    static func snapshot(processID: pid_t, preferredWindowID: Int?) -> TrackedTargetWindow? {
        let aerospace = aerospacePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        var workspaceByWindow: [Int: String] = [:]
        var visibleWorkspaces = Set<String>()
        var workspaceVisibilityKnown = false
        if let aerospace {
            let rows = command(aerospace, ["list-windows", "--all", "--format",
                                           "%{window-id}|%{app-pid}|%{workspace}"])
            for row in rows?.split(whereSeparator: \.isNewline) ?? [] {
                let parts = row.split(separator: "|", omittingEmptySubsequences: false)
                guard parts.count == 3, let id = Int(parts[0]),
                      let pid = Int32(parts[1]), pid == processID else { continue }
                workspaceByWindow[id] = String(parts[2])
            }
            let visible = command(aerospace, ["list-workspaces", "--monitor", "all",
                                              "--visible", "--format", "%{workspace}"])
            if let visible {
                workspaceVisibilityKnown = true
                visibleWorkspaces = Set(visible.split(whereSeparator: \.isNewline).map(String.init))
            }
        }

        let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
        let windows = raw as? [[String: Any]] ?? []
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let onScreenIDs = Set(onScreen.compactMap { $0[kCGWindowNumber as String] as? Int })
        var candidates: [(id: Int, bounds: CGRect, workspace: String?)] = []
        for info in windows {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owner == processID,
                  let id = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let values = info[kCGWindowBounds as String] as? [String: NSNumber],
                  let x = values["X"]?.doubleValue, let y = values["Y"]?.doubleValue,
                  let width = values["Width"]?.doubleValue,
                  let height = values["Height"]?.doubleValue,
                  width >= 300, height >= 200 else { continue }
            let bounds = CGRect(x: x, y: y, width: width, height: height)
            candidates.append((id, bounds, workspaceByWindow[id]))
        }
        guard !candidates.isEmpty else { return nil }
        let selected = candidates.first { $0.id == preferredWindowID }
            ?? candidates.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }!
        let mappedWorkspace = workspaceVisibilityKnown ? selected.workspace : nil
        return TrackedTargetWindow(
            id: selected.id,
            cgBounds: selected.bounds,
            workspace: mappedWorkspace,
            workspaceVisible: mappedWorkspace.map { visibleWorkspaces.contains($0) }
                ?? onScreenIDs.contains(selected.id)
        )
    }

    private static func command(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
