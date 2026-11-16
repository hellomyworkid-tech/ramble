import Foundation
import SwiftData
import Testing
@testable import Ramble

/// A library that won't open used to crash the app at every launch.
@MainActor
struct LibraryRecoveryTests {
    private let folder = URL.temporaryDirectory.appending(path: "library-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// A store with its journal and photos, beside things that aren't the library's.
    private func makeFiles() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder.appending(path: ".default_SUPPORT/_EXTERNAL_DATA", directoryHint: .isDirectory),
                                    withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appending(path: "OpenModels", directoryHint: .isDirectory), withIntermediateDirectories: true)
        for name in ["default.store", "default.store-wal", "default.store-shm", ".default_SUPPORT/_EXTERNAL_DATA/photo",
                     "OpenModels/weights", "ask-conversations.json"] {
            try Data("这不是数据库".utf8).write(to: folder.appending(path: name))
        }
    }

    @Test func aDamagedStoreThrowsRatherThanCrashing() throws {
        try makeFiles()
        #expect(throws: (any Error).self) {
            try AppSchema.openLibrary(sync: false, at: folder.appending(path: "default.store"))
        }
    }

    @Test func movingAsideTakesOnlyTheLibrarysFiles() throws {
        try makeFiles()
        let documents = folder.appending(path: "Documents", directoryHint: .isDirectory)
        let moved = try #require(try LibraryFiles.moveAside(from: folder, to: documents))

        let manager = FileManager.default
        #expect(manager.fileExists(atPath: moved.appending(path: "default.store").path))
        #expect(manager.fileExists(atPath: moved.appending(path: "default.store-wal").path))
        #expect(manager.fileExists(atPath: moved.appending(path: ".default_SUPPORT/_EXTERNAL_DATA/photo").path))
        #expect(LibraryFiles.items(in: folder).isEmpty)
        // What else is in the folder stays where it is.
        #expect(manager.fileExists(atPath: folder.appending(path: "OpenModels/weights").path))
        #expect(manager.fileExists(atPath: folder.appending(path: "ask-conversations.json").path))
    }

    @Test func aNewLibraryOpensOnceTheDamagedFilesAreAside() throws {
        try makeFiles()
        try LibraryFiles.moveAside(from: folder, to: folder.appending(path: "Documents", directoryHint: .isDirectory))

        let container = try AppSchema.openLibrary(sync: false, at: folder.appending(path: "default.store"))
        container.mainContext.insert(TaskItem(title: "还能记"))
        try container.mainContext.save()
        #expect(try container.mainContext.fetchCount(FetchDescriptor<TaskItem>()) == 1)
    }

    @Test func nothingToMoveIsNotAnError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(try LibraryFiles.moveAside(from: folder, to: folder) == nil)
    }

    @Test func theExportHoldsEveryFileOfTheLibraryAndNothingElse() async throws {
        try makeFiles()
        let zip = try #require(try await LibraryFiles.archive(from: folder))
        let names = try ZipArchive(Data(contentsOf: zip)).names

        #expect(names.contains { $0.hasSuffix("default.store") })
        #expect(names.contains { $0.hasSuffix("default.store-wal") })
        #expect(names.contains { $0.hasSuffix(".default_SUPPORT/_EXTERNAL_DATA/photo") })
        #expect(!names.contains { $0.contains("OpenModels") || $0.contains("ask-conversations") })
        // The originals stay.
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "default.store").path))
    }

    @Test func aNewLibrarysSeedsCountAsThisDevicesOwn() throws {
        let defaults = try #require(UserDefaults(suiteName: "library-\(UUID().uuidString)"))
        let container = AppSchema.inMemoryContainer()
        SeedData.seedDefaultsIfNeeded(container.mainContext)
        SyncDeduper.recordOwnSeeds(in: container.mainContext, defaults: defaults)
        let first = defaults.stringArray(forKey: "sync.ownedSeeds") ?? []
        #expect(!first.isEmpty)

        SyncDeduper.forgetOwnSeeds(defaults: defaults)
        let fresh = AppSchema.inMemoryContainer()
        SeedData.seedDefaultsIfNeeded(fresh.mainContext)
        SyncDeduper.recordOwnSeeds(in: fresh.mainContext, defaults: defaults)
        #expect(defaults.stringArray(forKey: "sync.ownedSeeds")?.count == first.count)
        #expect(defaults.stringArray(forKey: "sync.ownedSeeds") != first)
    }
}
