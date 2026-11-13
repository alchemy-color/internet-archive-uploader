import XCTest
@testable import ArchiveUploader

/// End-to-end test against the real archive.org, using the signed-in
/// account. Creates a throwaway item in `test_collection` (archive.org
/// deletes those automatically after about 30 days).
///
/// Skipped unless run with IA_LIVE_TEST=1, e.g.:
///   TEST_RUNNER_IA_LIVE_TEST=1 xcodebuild … test -only-testing:IAUploaderTests/LiveArchiveTests
@MainActor
final class LiveArchiveTests: XCTestCase {
    func testUploadFoldersSkipMoveDelete() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IA_LIVE_TEST"] == "1", "Live test disabled")
        let credentials = try XCTUnwrap(CredentialStore.load(), "Sign in to the app first")
        // The hidden test host must not be auto-terminated during long network waits.
        let keepAlive = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .automaticTerminationDisabled, .suddenTerminationDisabled], reason: "Live archive.org test")
        defer { ProcessInfo.processInfo.endActivity(keepAlive) }

        // Local folder: Root/{c.txt, sub/a.txt, sub/deeper/b.txt, big.bin}
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("Root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let stamp = String(Int(Date().timeIntervalSince1970))
        try Data("c \(stamp)".utf8).write(to: root.appendingPathComponent("c.txt"))
        try Data("a \(stamp)".utf8).write(to: root.appendingPathComponent("sub/a.txt"))
        try Data("b \(stamp)".utf8).write(to: root.appendingPathComponent("sub/deeper/b.txt"))
        var big = Data(count: 8 * 1024 * 1024)
        big.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try big.write(to: root.appendingPathComponent("big.bin"))

        let queue = UploadQueue(restore: false)  // in memory only
        let model = AppModel(queue: queue)
        model.credentials = credentials
        queue.credentials = credentials
        model.settings.keepTopFolder = true

        let identifier = "iauploader-selftest-\(stamp)"
        var metadata = ItemMetadata()
        metadata.title = "IA Uploader self-test \(stamp)"
        metadata.identifier = identifier
        metadata.descriptionText = "Automated test of folder uploads. Safe to delete."
        metadata.subjects = ["test"]
        metadata.mediatype = .data
        metadata.isTestItem = true

        let scanned = FileScanner.scan(urls: [root], includeHidden: false).files
        let picked = scanned.map { PickedFile(url: $0.url, rootName: $0.rootName, rawRelativePath: $0.relativePath, byteSize: $0.byteSize) }
        XCTAssertEqual(Set(picked.map(\.rawRelativePath)), ["Root/c.txt", "Root/sub/a.txt", "Root/sub/deeper/b.txt", "Root/big.bin"])

        // 1. Create the item with its folders.
        let report = await model.enqueue(files: picked, identifier: identifier, destinationFolder: "", newItemMetadata: metadata, allowExisting: false, title: metadata.title)
        XCTAssertNil(report.error, report.error ?? "")
        XCTAssertEqual(report.queued, 4)
        XCTAssertEqual(queue.jobs.filter(\.createsItem).count, 1)
        print("LIVE: queued → \(report.summary)")

        // 2. Pause the big file mid-upload, then resume it.
        let bigID = try XCTUnwrap(queue.jobs.first { $0.remotePath == "Root/big.bin" }?.id)
        try await waitUntil("big.bin sending", timeout: 240) { (queue.job(bigID)?.sent ?? 0) > 0 || queue.job(bigID)?.status == .done }
        if queue.job(bigID)?.status != .done {
            queue.pause([bigID])
            try await waitUntil("big.bin paused", timeout: 30) { queue.job(bigID)?.status == .paused }
            print("LIVE: paused big.bin OK")
            queue.resume([bigID])
        }
        try await waitUntil("all uploads done", timeout: 600) { queue.unfinishedCount == 0 || queue.failedCount > 0 }
        XCTAssertEqual(queue.failedCount, 0, queue.jobs.compactMap(\.error).joined(separator: "; "))
        print("LIVE: uploads finished: \(queue.jobs.map { "\($0.remotePath)=\($0.status.rawValue)" })")

        // 3. Re-queue the same files: all must be skipped (overlay knows them even if the API lags).
        let again = await model.enqueue(files: picked, identifier: identifier, destinationFolder: "", newItemMetadata: nil, allowExisting: true, title: metadata.title)
        XCTAssertNil(again.error)
        XCTAssertEqual(again.queued, 0, again.summary)
        XCTAssertEqual(again.skippedIdentical.count, 4, again.summary)
        print("LIVE: re-queue → \(again.summary)")

        // 4. archive.org shows the folder structure.
        let client = ArchiveClient.shared
        var serverFiles: [RemoteFile] = []
        try await waitUntil("server lists folders", timeout: 900, interval: 15) {
            serverFiles = ((try? await client.fetchItemFiles(identifier)) ?? []).filter(\.isOriginal)
            return Set(["Root/c.txt", "Root/sub/a.txt", "Root/sub/deeper/b.txt", "Root/big.bin"]).isSubset(of: Set(serverFiles.map(\.name)))
        }
        print("LIVE: server originals: \(serverFiles.map(\.name).sorted())")

        // 5. Re-queue again now that the server has MD5s: still skipped, now verified by checksum.
        let verified = await model.enqueue(files: picked, identifier: identifier, destinationFolder: "", newItemMetadata: nil, allowExisting: true, title: metadata.title)
        XCTAssertEqual(verified.skippedIdentical.count, 4, verified.summary)

        // 6. Reorganise the Finder folder, then sync: Finder is the reference.
        let fm = FileManager.default
        try fm.moveItem(at: root.appendingPathComponent("c.txt"), to: root.appendingPathComponent("sub/c.txt"))           // move
        try fm.moveItem(at: root.appendingPathComponent("sub/deeper"), to: root.appendingPathComponent("sub/renamed"))     // rename folder
        try fm.removeItem(at: root.appendingPathComponent("big.bin"))                                                       // delete
        try Data("new \(stamp)".utf8).write(to: root.appendingPathComponent("new.txt"))                                    // add
        try Data("a changed \(stamp)".utf8).write(to: root.appendingPathComponent("sub/a.txt"))                             // modify
        try fm.createDirectory(at: root.appendingPathComponent("empty folder"), withIntermediateDirectories: true)

        model.managedIdentifier = identifier
        model.route = .item(identifier)
        await model.loadManagedItem()
        model.linkedFolders[identifier] = LinkedFolder(localPath: root.path, remoteFolder: "Root")
        await model.checkSync()
        let plan = try XCTUnwrap(model.syncPlan, model.syncMessage ?? "no plan")
        print("LIVE: plan moves=\(plan.moves.map { "\($0.from)>\($0.to)" }) uploads=\(plan.uploads.map(\.remotePath)) updates=\(plan.updates.map(\.remotePath)) removals=\(plan.removals.map(\.remotePath)) empty=\(plan.emptyLocalFolders)")
        XCTAssertEqual(Set(plan.moves.map(\.to)), ["Root/sub/c.txt", "Root/sub/renamed/b.txt"])
        XCTAssertEqual(plan.uploads.map(\.remotePath), ["Root/new.txt"])
        XCTAssertEqual(plan.updates.map(\.remotePath), ["Root/sub/a.txt"])
        XCTAssertEqual(plan.removals.map(\.remotePath), ["Root/big.bin"])
        XCTAssertEqual(plan.emptyLocalFolders, ["empty folder"])

        await model.applySync(includeRemovals: true)
        XCTAssertNil(model.managedItemError, model.managedItemError ?? "")
        try await waitUntil("sync uploads done", timeout: 600) { queue.unfinishedCount == 0 || queue.failedCount > 0 }
        XCTAssertEqual(queue.failedCount, 0)
        await model.checkSync()
        XCTAssertEqual(model.syncPlan?.isInSync, true, "after sync: \(String(describing: model.syncPlan))")

        // 7. archive.org converges on exactly the Finder layout.
        let expected: Set<String> = ["Root/sub/a.txt", "Root/sub/c.txt", "Root/sub/renamed/b.txt", "Root/new.txt"]
        try await waitUntil("server matches Finder", timeout: 900, interval: 15) {
            serverFiles = ((try? await client.fetchItemFiles(identifier)) ?? []).filter(\.isOriginal)
            return Set(serverFiles.map(\.name)) == expected
        }
        print("LIVE: final server originals: \(serverFiles.map(\.name).sorted())")
    }

    private func waitUntil(_ what: String, timeout: TimeInterval, interval: TimeInterval = 0.5, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        XCTFail("Timed out waiting for: \(what)")
        throw CancellationError()
    }
}

/// Read-only preview of a folder sync against a real item. Nothing is changed.
///   IA_SYNC_PREVIEW_FOLDER=/path IA_SYNC_PREVIEW_ITEM=identifier
@MainActor
final class SyncPreviewTests: XCTestCase {
    func testPreview() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["IA_SYNC_PREVIEW_FOLDER"], let item = env["IA_SYNC_PREVIEW_ITEM"] else { throw XCTSkip("No preview requested") }
        let keepAlive = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .automaticTerminationDisabled, .suddenTerminationDisabled], reason: "Preview")
        defer { ProcessInfo.processInfo.endActivity(keepAlive) }
        let remote = try await ArchiveClient.shared.fetchItemFiles(item)
        let scan = SyncPlanner.scanLocal(URL(fileURLWithPath: folder), includeHidden: false)
        var hashed = 0
        let plan = SyncPlanner.plan(local: scan.files, remote: remote, remoteFolder: "", sanitize: true, deepCompare: true) { entry in
            hashed += 1
            return MD5Cache.shared.md5(for: entry.url, size: entry.byteSize)
        }
        MD5Cache.shared.save()
        print("PREVIEW: local=\(scan.files.count) hashed=\(hashed) unchanged=\(plan.unchanged) moves=\(plan.moves.count) uploads=\(plan.uploads.count) (\(ByteCountFormatter.shortString(plan.uploads.reduce(0) { $0 + $1.byteSize }))) updates=\(plan.updates.count) removals=\(plan.removals.count)")
        for move in plan.moves { print("PREVIEW move: \(move.from)  ->  \(move.to)") }
        for upload in plan.uploads { print("PREVIEW upload: \(upload.remotePath)") }
        for update in plan.updates { print("PREVIEW update: \(update.remotePath)") }
        for removal in plan.removals { print("PREVIEW remove: \(removal.remotePath)") }
    }
}
