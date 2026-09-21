import Foundation

@main
struct StoreTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floating-todo-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskStore(directory: root)
        var settings = try store.settings()
        assert(settings.codexThreadID.isEmpty)
        assert(settings.reminderHour == 17)
        var state = try store.load(today: "2026-01-01")
        assert(state.tasks.isEmpty)
        state = try store.mutate(today: "2026-01-01") {
            $0.tasks = [Todo(id: "done", title: "Done", detail: "", done: true), Todo(id: "pending", title: "Pending", detail: "", done: false)]
            $0.reminderShown = true
        }
        state = try store.load(today: "2026-01-02")
        assert(state.date == "2026-01-02" && state.tasks.count == 1 && state.tasks[0].id == "pending")
        assert(!state.reminderShown)
        let archive = root.appendingPathComponent("history/2026-01-01.json")
        let archived = try JSONDecoder().decode(State.self, from: Data(contentsOf: archive))
        assert(archived.tasks.count == 2 && archived.tasks[0].done)
        let again = try store.load(today: "2026-01-02")
        assert(again == state)
        let original = try Data(contentsOf: store.file)
        do {
            _ = try store.mutate(today: "2026-01-02") { $0.tasks.append($0.tasks[0]) }
            fatalError("Duplicate ID accepted")
        } catch { let current = try Data(contentsOf: store.file); assert(current == original) }
        try Data("invalid json".utf8).write(to: store.file)
        do { _ = try store.load(today: "2026-01-02"); fatalError("Corruption silently replaced") }
        catch { let current = try Data(contentsOf: store.file); assert(current == Data("invalid json".utf8)) }
        settings.codexThreadID = "not-a-uuid"
        do { try store.saveSettings(settings); fatalError("Invalid settings accepted") } catch {}
        assert(DayClock.today(timeZone: "Asia/Shanghai", now: Date(timeIntervalSince1970: 0)) == "1970-01-01")
        print("PASS: first launch, defaults, daily archive, carryover, idempotency, validation, corrupt-file preservation")
    }
}
