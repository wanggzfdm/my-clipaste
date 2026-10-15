import Foundation
import SwiftData

// Both schema versions model the same persisted entity; V2 adds uniqueness only.
enum MigrationFixtureV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Record.self] }

    @Model final class Record {
        var id: UUID = UUID()
        var contentHash: String = ""
        var timestamp: Date = Date()
        var plainText: String?
        init(id: UUID = UUID(), contentHash: String, timestamp: Date, plainText: String?) {
            self.id = id; self.contentHash = contentHash; self.timestamp = timestamp; self.plainText = plainText
        }
    }
}

enum MigrationFixtureV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Record.self] }

    @Model final class Record {
        var id: UUID = UUID()
        @Attribute(.unique) var contentHash: String = ""
        var timestamp: Date = Date()
        var plainText: String?
        init(id: UUID = UUID(), contentHash: String, timestamp: Date = Date(), plainText: String? = nil) {
            self.id = id; self.contentHash = contentHash; self.timestamp = timestamp; self.plainText = plainText
        }
    }
}

enum MigrationFixturePlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MigrationFixtureV1.self, MigrationFixtureV2.self] }
    static var stages: [MigrationStage] {
        [MigrationStage.custom(fromVersion: MigrationFixtureV1.self, toVersion: MigrationFixtureV2.self, willMigrate: { context in
            let rows = try context.fetch(FetchDescriptor<MigrationFixtureV1.Record>())
            var winner: [String: MigrationFixtureV1.Record] = [:]
            for row in rows {
                let hash = row.contentHash.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !hash.isEmpty else { row.contentHash = "legacy-empty-\(row.id.uuidString)"; continue }
                if let prior = winner[hash] {
                    if row.timestamp > prior.timestamp
                        || (row.timestamp == prior.timestamp && row.id.uuidString < prior.id.uuidString) {
                        context.delete(prior); winner[hash] = row; row.contentHash = hash
                    } else { context.delete(row) }
                } else { winner[hash] = row; row.contentHash = hash }
            }
            try context.save()
        }, didMigrate: nil)]
    }
}

@main struct ClipboardContentHashMigrationTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.store"); let v1 = Schema(versionedSchema: MigrationFixtureV1.self)
        do {
            let c = try ModelContainer(for: v1, configurations: [ModelConfiguration("Fixture", schema: v1, url: url, cloudKitDatabase: .none)])
            let ctx = ModelContext(c)
            ctx.insert(MigrationFixtureV1.Record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, contentHash: " duplicate ", timestamp: Date(timeIntervalSince1970: 1), plainText: "old"))
            ctx.insert(MigrationFixtureV1.Record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, contentHash: "duplicate", timestamp: Date(timeIntervalSince1970: 2), plainText: "new"))
            ctx.insert(MigrationFixtureV1.Record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, contentHash: "duplicate", timestamp: Date(timeIntervalSince1970: 2), plainText: "tie-winner"))
            ctx.insert(MigrationFixtureV1.Record(contentHash: "  ", timestamp: Date(), plainText: nil)); try ctx.save()
        }
        let v2 = Schema(versionedSchema: MigrationFixtureV2.self)
        let c = try ModelContainer(for: v2, migrationPlan: MigrationFixturePlan.self, configurations: [ModelConfiguration("Fixture", schema: v2, url: url, cloudKitDatabase: .none)])
        let ctx = ModelContext(c)
        let rows = try ctx.fetch(FetchDescriptor<MigrationFixtureV2.Record>())
        precondition(rows.count == 2 && rows.contains { $0.contentHash == "duplicate" && $0.plainText == "tie-winner" && $0.id.uuidString == "00000000-0000-0000-0000-000000000001" })
        precondition(rows.filter { $0.contentHash.hasPrefix("legacy-empty-") }.count == 1)
        print("migrated rows: \(rows.map { ($0.contentHash, $0.plainText ?? "nil") })")
        for text in ["first", "second"] { ctx.insert(MigrationFixtureV2.Record(contentHash: "same", plainText: text)); try ctx.save() }
        let repeated = try ctx.fetch(FetchDescriptor<MigrationFixtureV2.Record>(predicate: #Predicate { $0.contentHash == "same" })); precondition(repeated.count == 1)
        let group = DispatchGroup(); let lock = NSLock(); var outcomes: [String] = []
        for _ in 0..<2 {
            group.enter(); DispatchQueue.global().async {
                defer { group.leave() }
                do { let context = ModelContext(c); context.insert(MigrationFixtureV2.Record(contentHash: "race", plainText: "concurrent")); try context.save(); lock.lock(); outcomes.append("saved"); lock.unlock() }
                catch { lock.lock(); outcomes.append("conflict: \(error)"); lock.unlock() }
            }
        }
        group.wait()
        let raced = try ctx.fetch(FetchDescriptor<MigrationFixtureV2.Record>(predicate: #Predicate { $0.contentHash == "race" }))
        precondition(raced.count == 1 && outcomes.count == 2)
        print("migration/uniqueness passed; concurrent outcomes: \(outcomes)")
    }
}
