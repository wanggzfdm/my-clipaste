import Foundation

// Executable source-contract checks for scheduling semantics that cannot be
// exercised without the app's SwiftData model container.
@main
enum ImportedTimestampMaintenanceTests {
    static func main() throws {
        let rootPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let storage = try String(contentsOf: root.appendingPathComponent("Managers/StorageManager+HistoryQueries.swift"), encoding: .utf8)
        let runtime = try String(contentsOf: root.appendingPathComponent("Managers/ClipboardRuntimeStore+DataMaintenance.swift"), encoding: .utf8)
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fatalError(message) }
        }
        require(storage.contains("nonisolated\n    func repairImportedMigrationTimestampsInBackground()"), "runner must be nonisolated")
        require(storage.contains("Task.detached(priority: .utility)"), "runner must detach")
        require(storage.contains("ClipboardStoreActor(modelContainer: container)"), "detached task must create its own store actor")
        require(storage.contains("repairImportedMigrationTimestampsPage(offset: offset)"), "runner must fetch pages")
        require(storage.contains("await Task.yield()"), "runner must yield between pages")
        require(storage.contains("try await Task.sleep(for: .milliseconds(100))"), "runner must throttle between pages for 100ms")
        require(storage.contains("guard Task.isCancelled == false else { break }"), "runner must check cancellation before sleeping")
        require(storage.contains("catch is CancellationError") && storage.contains("catch {"), "runner must exit on cancellation or sleep error")
        require(runtime.contains("storage.repairImportedMigrationTimestampsInBackground()"), "runtime must schedule background runner")
        require(runtime.contains("Task { [weak self] in") && runtime.contains("await Task.yield()"), "bootstrap scheduling must be asynchronous and weakly capture runtime")
        print("Imported timestamp maintenance scheduling checks passed")
    }
}
