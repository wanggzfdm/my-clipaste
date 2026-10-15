import Foundation

struct ClipboardTimestampPage {
    let offset: Int
    let count: Int
    let pageSize: Int
    var isComplete: Bool { count < pageSize }
    func next() -> ClipboardTimestampPage {
        ClipboardTimestampPage(offset: offset + count, count: pageSize, pageSize: pageSize)
    }
}

@main
enum ClipboardImportedTimestampMaintenanceSourceTests {
    static func main() throws {
        let bootstrap = try String(contentsOfFile: "clipaste/Managers/ClipboardRuntimeStore+Bootstrap.swift", encoding: .utf8)
        let maintenance = try String(contentsOfFile: "clipaste/Managers/ClipboardRuntimeStore+DataMaintenance.swift", encoding: .utf8)
        let actor = try String(contentsOfFile: "clipaste/Managers/ClipboardStoreActor+ContentMaintenance.swift", encoding: .utf8)
        let history = try String(contentsOfFile: "clipaste/Managers/StorageManager+HistoryQueries.swift", encoding: .utf8)
        precondition(bootstrap.contains("scheduleImportedMigrationTimestampRepair(using: currentRuntime.storage)"))
        precondition(bootstrap.contains("scheduleImportedMigrationTimestampRepair") && !bootstrap.contains("await currentRuntime.storage.repairImportedMigrationTimestampsIfNeeded()"))
        precondition(maintenance.contains("let runner = storage.repairImportedMigrationTimestampsInBackground()"))
        precondition(maintenance.contains("await runner.value"))
        precondition(maintenance.contains("importedMigrationTimestampRepairTask == nil"))
        precondition(maintenance.contains("Task.yield()"))
        precondition(actor.contains("repairImportedMigrationTimestampsPage(offset: Int)"))
        precondition(actor.contains("offset + records.count"))
        precondition(history.contains("await Task.yield()"))
        let first = ClipboardTimestampPage(offset: 0, count: 2, pageSize: 2)
        let second = first.next()
        precondition(second.offset == 2 && !second.isComplete)
        let final = ClipboardTimestampPage(offset: second.offset, count: 1, pageSize: 2)
        precondition(final.isComplete)
        print("ClipboardImportedTimestampMaintenanceSourceTests passed")
    }
}
