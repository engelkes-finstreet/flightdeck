import Foundation

/// Recognises a git worktree and points back at the repository it was cut
/// from.
///
/// A worktree is a directory of its own, so grouping agents by the last path
/// component of their `cwd` scatters every worktree of one repo into its own
/// project header — three feature worktrees of `fs-data-extraction` show up as
/// three unrelated projects. Git already records the relationship: inside a
/// worktree `.git` is a *file* reading
/// `gitdir: <repo>/.git/worktrees/<name>`, which names the repository outright.
/// One file read, no `git` subprocess on the refresh path.
enum WorktreeLocator {

    /// What a worktree knows about itself.
    struct Worktree: Equatable {
        /// Root of the repository the worktree belongs to, e.g.
        /// `/Users/me/workspace/fs-data-extraction`.
        let repoRoot: String
        /// The repository's own directory name — the project to group under.
        let repoName: String
        /// The branch checked out in this worktree, read live. The transcript
        /// records the branch as it was when the session opened, which for a
        /// worktree is routinely the branch it was cut from rather than the
        /// one it is on.
        let branch: String?
    }

    /// Resolves `cwd` when — and only when — it sits inside a linked worktree.
    ///
    /// Nil for an ordinary checkout, a bare directory, or a submodule, so
    /// every other path keeps grouping by its own directory name.
    static func resolve(cwd: String) -> Worktree? {
        guard let pointer = gitPointerFile(startingAt: cwd),
              let gitDir = gitDir(from: pointer),
              isWorktreeGitDir(gitDir)
        else { return nil }

        // .../<repo>/.git/worktrees/<name>  ->  .../<repo>
        let repoRoot = gitDir
            .deletingLastPathComponent()   // worktrees/
            .deletingLastPathComponent()   // .git/
            .deletingLastPathComponent()   // repo root
        return Worktree(repoRoot: repoRoot.path,
                        repoName: repoRoot.lastPathComponent,
                        branch: branch(inGitDir: gitDir))
    }

    /// The nearest enclosing `.git` that is a file rather than a directory.
    ///
    /// Stops at the first `.git` of either kind: a directory means an ordinary
    /// checkout, and walking past it would wrongly claim a repo nested inside
    /// another one for the outer repo's worktrees.
    private static func gitPointerFile(startingAt cwd: String) -> URL? {
        var directory = URL(fileURLWithPath: cwd).standardizedFileURL
        for _ in 0..<24 {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? nil : dotGit
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    private static func gitDir(from pointer: URL) -> URL? {
        guard let text = try? String(contentsOf: pointer, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        // `git worktree add --relative-paths` writes a path relative to the
        // worktree, so resolve against the pointer rather than our own cwd.
        let url = target.hasPrefix("/")
            ? URL(fileURLWithPath: target)
            : URL(fileURLWithPath: target, relativeTo: pointer.deletingLastPathComponent())
        return url.standardizedFileURL
    }

    /// A submodule's `.git` is a pointer file too, but it targets
    /// `.git/modules/<name>` — only `worktrees` means a worktree, and a
    /// submodule should stay its own project.
    private static func isWorktreeGitDir(_ gitDir: URL) -> Bool {
        let parts = gitDir.pathComponents
        return parts.count >= 3
            && parts[parts.count - 2] == "worktrees"
            && parts[parts.count - 3] == ".git"
    }

    /// `HEAD` in the worktree's git dir, e.g. `ref: refs/heads/feat/foo`.
    /// Detached, and there is no branch to name.
    private static func branch(inGitDir gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"),
                                     encoding: .utf8)
        else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref: refs/heads/") else { return nil }
        let name = String(trimmed.dropFirst("ref: refs/heads/".count))
        return name.isEmpty ? nil : name
    }
}
