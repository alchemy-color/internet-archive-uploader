import XCTest
@testable import ArchiveUploader

final class SyncPlannerTests: XCTestCase {
    private func remote(_ name: String, _ size: Int64?, md5: String? = nil, source: String = "original") -> RemoteFile {
        RemoteFile(name: name, size: size, md5: md5, source: source)
    }

    func testMatchesByFullPathNotFileName() {
        // Regression: "B/cover.jpg" used to be skipped because "A/cover.jpg" existed.
        let decisions = SyncPlanner.decide(
            [.init(remotePath: "B/cover.jpg", byteSize: 10, localMD5: nil)],
            remote: [remote("A/cover.jpg", 10)],
            policy: .replace
        )
        XCTAssertEqual(decisions, [.upload])
    }

    func testIdenticalIsSkippedAndDifferentFollowsPolicy() {
        let candidates: [SyncPlanner.Candidate] = [
            .init(remotePath: "a.txt", byteSize: 5, localMD5: "abc"),
            .init(remotePath: "b.txt", byteSize: 5, localMD5: "zzz"),
            .init(remotePath: "c.txt", byteSize: 9, localMD5: nil),
        ]
        let files = [remote("a.txt", 5, md5: "ABC"), remote("b.txt", 5, md5: "abc"), remote("c.txt", 3)]
        XCTAssertEqual(SyncPlanner.decide(candidates, remote: files, policy: .replace), [.skipIdentical, .replace, .replace])
        XCTAssertEqual(SyncPlanner.decide(candidates, remote: files, policy: .skip), [.skipIdentical, .skipDifferent, .skipDifferent])
        XCTAssertEqual(SyncPlanner.decide(candidates, remote: files, policy: .keepBoth), [.skipIdentical, .rename("b-2.txt"), .rename("c-2.txt")])
    }

    func testAlreadyQueuedPathsAreNotQueuedTwice() {
        let decisions = SyncPlanner.decide(
            [.init(remotePath: "x/y.mov", byteSize: 1, localMD5: nil)],
            remote: [],
            queuedPaths: ["x/y.mov"],
            policy: .replace
        )
        XCTAssertEqual(decisions, [.alreadyQueued])
    }

    func testPathsAreCaseSensitive() {
        let decisions = SyncPlanner.decide([.init(remotePath: "Photo.JPG", byteSize: 1, localMD5: nil)], remote: [remote("photo.jpg", 1)], policy: .replace)
        XCTAssertEqual(decisions, [.upload])
    }

    func testDiffMapsLocalFolderOntoRemoteFolderAndIgnoresDerivatives() {
        let local = [
            SyncPlanner.LocalEntry(url: URL(fileURLWithPath: "/l/a.txt"), relativePath: "a.txt", byteSize: 1),
            SyncPlanner.LocalEntry(url: URL(fileURLWithPath: "/l/sub/b.txt"), relativePath: "sub/b.txt", byteSize: 2),
            SyncPlanner.LocalEntry(url: URL(fileURLWithPath: "/l/c.txt"), relativePath: "c.txt", byteSize: 3),
        ]
        let files = [
            remote("Music/a.txt", 1),
            remote("Music/sub/b.txt", 99),
            remote("Music/old.txt", 4),
            remote("Music/a_thumb.jpg", 4, source: "derivative"),
            remote("Other/a.txt", 1),
            remote("item_meta.xml", 1, source: "metadata"),
        ]
        let diff = SyncPlanner.diff(local: local, remote: files, remoteFolder: "Music", sanitize: false)
        let byPath = Dictionary(uniqueKeysWithValues: diff.map { ($0.remotePath, $0.status) })
        XCTAssertEqual(byPath, [
            "Music/a.txt": .identical,
            "Music/sub/b.txt": .changed,
            "Music/c.txt": .new,
            "Music/old.txt": .remoteOnly,
        ])
    }

    func testSystemFilesAreRecognised() {
        XCTAssertTrue(remote("x_meta.xml", 1).isSystemFile)
        XCTAssertTrue(remote("__ia_thumb.jpg", 1).isSystemFile)
        XCTAssertTrue(remote("a.mp4", 1, source: "derivative").isSystemFile)
        XCTAssertFalse(remote("folder/a.mp4", 1).isSystemFile)
    }

    func testMD5() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(SyncPlanner.md5(of: url), "5d41402abc4b2a76b9719d911017c592")
    }
}

final class RemoteOverlayTests: XCTestCase {
    func testRecentUploadsShowUntilServerCatchesUp() {
        var overlay = RemoteOverlay()
        overlay.recordAdded(identifier: "item", path: "a/new.txt", size: 5)
        overlay.recordRemoved(identifier: "item", path: "a/old.txt")

        let server = [RemoteFile(name: "a/old.txt", size: 1, md5: nil, source: "original")]
        let first = overlay.merge(identifier: "item", server: server)
        XCTAssertEqual(first.files.map(\.name), ["a/new.txt"])
        XCTAssertEqual(first.pending, ["a/new.txt", "a/old.txt"])

        let caughtUp = [RemoteFile(name: "a/new.txt", size: 5, md5: nil, source: "original")]
        let second = overlay.merge(identifier: "item", server: caughtUp)
        XCTAssertEqual(second.files.map(\.name), ["a/new.txt"])
        XCTAssertTrue(second.pending.isEmpty)
        XCTAssertTrue(overlay.entries.isEmpty)
    }
}

final class PathAndTreeTests: XCTestCase {
    func testPathHelpers() {
        XCTAssertEqual(RemotePath.join("", "/a/", "b//c.txt"), "a/b/c.txt")
        XCTAssertEqual(RemotePath.parent(of: "a/b/c.txt"), "a/b")
        XCTAssertEqual(RemotePath.parent(of: "c.txt"), "")
        XCTAssertTrue(RemotePath.isInside("a/b/c", folder: "a/b"))
        XCTAssertFalse(RemotePath.isInside("a/bc/d", folder: "a/b"))
        XCTAssertEqual(RemotePath.reparent("a/b/c.txt", from: "a/b", to: "x"), "x/c.txt")
        XCTAssertEqual(RemotePath.reparent("a/b/c.txt", from: "a", to: ""), "b/c.txt")
        XCTAssertEqual(UploadPlanBuilder.normalizedFolder(" /Season 1//Extras/ ", sanitize: true), "Season_1/Extras")
    }

    func testDestinationFolderIsPrepended() {
        let file = PickedFile(url: URL(fileURLWithPath: "/tmp/x.txt"), rootName: "Root", rawRelativePath: "Root/sub/x.txt", byteSize: 1)
        let plan = UploadPlanBuilder.build(identifier: "id", metadata: ItemMetadata(), files: [file], sanitizeNames: true, destinationFolder: "Extras", options: .default)
        XCTAssertEqual(plan.files.first?.remotePath, "Extras/Root/sub/x.txt")
    }

    func testPickedFileRoundTripKeepsFolders() throws {
        // Regression: state restore used to rescan bare file URLs and lose folders.
        let file = PickedFile(url: URL(fileURLWithPath: "/tmp/x.txt"), rootName: "Root", rawRelativePath: "Root/sub/x.txt", byteSize: 7)
        let decoded = try JSONDecoder().decode(PickedFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(decoded.rawRelativePath, "Root/sub/x.txt")
        XCTAssertEqual(decoded.id, file.id)
    }

    func testTreeHasStableIDsAndEmptyFolders() {
        let tree = FileTreeBuilder.build(
            [TreeEntry(key: "a/1.txt", path: "a/1.txt", size: 1), TreeEntry(key: "a/b/2.txt", path: "a/b/2.txt", size: 2), TreeEntry(key: "3.txt", path: "3.txt", size: 3)],
            extraFolders: ["a/empty", "z"]
        )
        XCTAssertEqual(tree.map(\.id), ["d:a", "d:z", "f:3.txt"])
        XCTAssertEqual(tree[0].fileCount, 2)
        XCTAssertEqual(tree[0].totalBytes, 3)
        XCTAssertEqual(FileTreeBuilder.folderPaths(tree), ["a", "a/b", "a/empty", "z"])
        XCTAssertEqual(FileTreeBuilder.find("d:a/empty", in: tree)?.badge, .emptyFolder)
    }
}

@MainActor
final class UploadQueueTests: XCTestCase {
    private func makeJobs(_ count: Int, batch: UploadBatch) -> [UploadJob] {
        (0..<count).map { UploadJob(batchID: batch.id, identifier: batch.identifier, localPath: "/tmp/\($0)", remotePath: "f/\($0).txt", byteSize: 10) }
    }

    func testControlsWithoutNetwork() {
        let queue = UploadQueue(restore: false)   // no credentials: nothing starts
        let batch = UploadBatch(identifier: "item", title: "Item", isNewItem: false)
        let jobs = makeJobs(3, batch: batch)
        queue.enqueue(jobs, batch: batch)
        XCTAssertEqual(queue.waitingCount, 3)
        XCTAssertEqual(queue.pendingPaths(for: "item"), ["f/0.txt", "f/1.txt", "f/2.txt"])

        queue.pause([jobs[0].id])
        XCTAssertEqual(queue.job(jobs[0].id)?.status, .paused)

        queue.pauseAll()
        XCTAssertTrue(queue.isPaused)
        XCTAssertTrue(queue.jobs.allSatisfy { $0.status == .paused })

        queue.resumeAll()
        XCTAssertFalse(queue.isPaused)
        XCTAssertTrue(queue.jobs.allSatisfy { $0.status == .queued })

        queue.stopAll()
        XCTAssertTrue(queue.jobs.allSatisfy { $0.status == .cancelled })
        queue.forceRestart([jobs[1].id])
        XCTAssertEqual(queue.job(jobs[1].id)?.status, .queued)

        XCTAssertTrue(queue.editRemotePath(jobs[2].id, to: "/new//path/x.txt"))
        XCTAssertEqual(queue.job(jobs[2].id)?.remotePath, "new/path/x.txt")

        queue.editFolder(identifier: "item", from: "f", to: "g")
        XCTAssertEqual(queue.job(jobs[0].id)?.remotePath, "g/0.txt")

        queue.moveToTop([jobs[2].id])
        XCTAssertEqual(queue.jobs.first?.id, jobs[2].id)

        queue.remove([jobs[0].id])
        XCTAssertEqual(queue.jobs.count, 2)
        queue.removeBatch(batch.id)
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertTrue(queue.batches.isEmpty)
    }

    func testHeadersOnlyCarryMetadataForCreatingJob() {
        var job = UploadJob(batchID: UUID(), identifier: "i", localPath: "/tmp/a", remotePath: "a", byteSize: 3, contentType: "text/plain")
        job.metadataHeaders = [HeaderPair(name: "x-archive-meta-title", value: "T")]
        let credentials = ArchiveCredentials(accessKey: "a", secretKey: "b")
        let headers = UploadQueue.headers(for: job, credentials: credentials, options: .default)
        XCTAssertEqual(headers["x-archive-meta-title"], "T")
        XCTAssertEqual(headers["Authorization"], "LOW a:b")
        XCTAssertEqual(headers["x-archive-size-hint"], "3")
    }
}

final class FolderSyncPlanTests: XCTestCase {
    private func local(_ path: String, _ size: Int64, md5: String? = nil) -> SyncPlanner.LocalEntry {
        SyncPlanner.LocalEntry(url: URL(fileURLWithPath: "/l/" + path), relativePath: path, byteSize: size, md5: md5)
    }
    private func remote(_ name: String, _ size: Int64, md5: String? = nil) -> RemoteFile {
        RemoteFile(name: name, size: size, md5: md5, source: "original")
    }

    func testFinderIsTheReference() {
        // Finder: reorganised into Season 1/, one file edited, one new, one deleted.
        let localFiles = [
            local("Season 1/E1.mp4", 100, md5: "e1"),
            local("Season 1/E2.mp4", 200, md5: "e2"),
            local("cover.jpg", 5, md5: "cover-new"),
            local("notes.txt", 7, md5: "notes"),
        ]
        let remoteFiles = [
            remote("E1.mp4", 100, md5: "e1"),            // moved into Season 1
            remote("E2.mp4", 200, md5: "e2"),            // moved into Season 1
            remote("cover.jpg", 5, md5: "cover-old"),    // same size, different content
            remote("old.txt", 3, md5: "old"),            // deleted in Finder
            remote("item_meta.xml", 1),                  // ignored (system file)
        ]
        let plan = SyncPlanner.plan(local: localFiles, remote: remoteFiles, remoteFolder: "", sanitize: false, deepCompare: true) { $0.md5 }
        XCTAssertEqual(plan.moves.map { "\($0.from)>\($0.to)" }, ["E1.mp4>Season 1/E1.mp4", "E2.mp4>Season 1/E2.mp4"])
        XCTAssertEqual(plan.updates.map(\.remotePath), ["cover.jpg"])
        XCTAssertEqual(plan.uploads.map(\.remotePath), ["notes.txt"])
        XCTAssertEqual(plan.removals.map(\.remotePath), ["old.txt"])
        XCTAssertEqual(plan.unchanged, 0)
    }

    func testInSyncAndScopedToRemoteFolder() {
        let plan = SyncPlanner.plan(
            local: [local("a.txt", 1, md5: "a"), local("sub/b.txt", 2, md5: "b")],
            remote: [remote("Music/a.txt", 1, md5: "a"), remote("Music/sub/b.txt", 2, md5: "b"), remote("Other/x.txt", 9)],
            remoteFolder: "Music", sanitize: false, deepCompare: true
        ) { $0.md5 }
        XCTAssertTrue(plan.isInSync)
        XCTAssertEqual(plan.unchanged, 2)
    }

    func testRenamedFolderBecomesMovesNotUploads() {
        let plan = SyncPlanner.plan(
            local: [local("Disc 2/a.mp4", 10, md5: "a"), local("Disc 2/b.mp4", 20, md5: "b")],
            remote: [remote("Disc_2_old/a.mp4", 10, md5: "a"), remote("Disc_2_old/b.mp4", 20, md5: "b")],
            remoteFolder: "", sanitize: true, deepCompare: false
        ) { $0.md5 }
        XCTAssertEqual(plan.moves.map(\.to), ["Disc_2/a.mp4", "Disc_2/b.mp4"])
        XCTAssertTrue(plan.uploads.isEmpty && plan.removals.isEmpty)
    }

    func testMoveFallsBackToNameAndSizeWithoutChecksum() {
        let plan = SyncPlanner.plan(
            local: [local("new/clip.mov", 50)],
            remote: [remote("clip.mov", 50)],   // still processing: no md5 yet
            remoteFolder: "", sanitize: false, deepCompare: false
        ) { _ in nil }
        XCTAssertEqual(plan.moves.first?.from, "clip.mov")
    }

    func testScanLocalFindsEmptyFolders() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty/inner"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("full"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("full/x.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let scan = SyncPlanner.scanLocal(root, includeHidden: false)
        XCTAssertEqual(scan.files.map(\.relativePath), ["full/x.txt"])
        XCTAssertEqual(scan.emptyFolders, ["empty/inner"])
    }
}

final class ArchiveHostsTests: XCTestCase {
    func testOnlyArchiveOrgOverHTTPSIsTrusted() {
        XCTAssertTrue(ArchiveHosts.isTrusted(URL(string: "https://s3.us.archive.org/item/file")))
        XCTAssertTrue(ArchiveHosts.isTrusted(URL(string: "https://archive.org/metadata/item")))
        XCTAssertTrue(ArchiveHosts.isTrusted(URL(string: "https://ia800.us.archive.org/x")))
        XCTAssertFalse(ArchiveHosts.isTrusted(URL(string: "http://s3.us.archive.org/item")))
        XCTAssertFalse(ArchiveHosts.isTrusted(URL(string: "https://evil.com/archive.org")))
        XCTAssertFalse(ArchiveHosts.isTrusted(URL(string: "https://notarchive.org/x")))
        XCTAssertFalse(ArchiveHosts.isTrusted(URL(string: "https://archive.org.evil.com/x")))
    }
}
