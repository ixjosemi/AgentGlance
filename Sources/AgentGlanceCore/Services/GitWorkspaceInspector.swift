import Foundation

/// Resolves the git branch a session works on by reading `.git`/`HEAD`
/// directly — no `git` subprocess, so the menu can call it per row.
public enum GitWorkspaceInspector {
    private static let referencePrefix = "ref: refs/heads/"
    private static let worktreePointerPrefix = "gitdir: "

    public static func branchName(forWorkingDirectory path: String) -> String? {
        var directory = URL(fileURLWithPath: path)
        // Bounded walk toward the filesystem root; PATH_MAX-deep repos are
        // not a thing worth supporting.
        for _ in 0..<64 {
            if let head = headContents(gitEntry: directory.appendingPathComponent(".git")) {
                return branch(fromHead: head)
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
        return nil
    }

    private static func headContents(gitEntry: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitEntry.path, isDirectory: &isDirectory)
        else { return nil }
        let headURL: URL
        if isDirectory.boolValue {
            headURL = gitEntry.appendingPathComponent("HEAD")
        } else {
            // A linked worktree's `.git` is a one-line file pointing at the
            // repository's `.git/worktrees/<name>` metadata directory.
            guard let pointer = try? String(contentsOf: gitEntry, encoding: .utf8),
                  let firstLine = pointer.split(separator: "\n").first,
                  firstLine.hasPrefix(worktreePointerPrefix)
            else { return nil }
            let metadataPath = String(firstLine.dropFirst(worktreePointerPrefix.count))
            headURL = URL(fileURLWithPath: metadataPath).appendingPathComponent("HEAD")
        }
        return try? String(contentsOf: headURL, encoding: .utf8)
    }

    private static func branch(fromHead head: String) -> String? {
        guard let firstLine = head.split(separator: "\n").first else { return nil }
        if firstLine.hasPrefix(referencePrefix) {
            return String(firstLine.dropFirst(referencePrefix.count))
        }
        // Detached HEAD stores a raw commit hash; show the short form.
        return String(firstLine.prefix(7))
    }
}
