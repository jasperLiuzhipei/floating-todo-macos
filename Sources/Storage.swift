import Foundation
import Darwin

struct Todo: Codable, Equatable {
    var id: String
    var title: String
    var detail: String
    var done: Bool
    var completedAt: String?
}
struct State: Codable, Equatable {
    var date: String
    var tasks: [Todo]
    var reminderShown: Bool
    var opacity: Double
}
struct Settings: Codable {
    var reminderEnabled = true
    var reminderHour = 17
    var reminderMinute = 0
    var timeZone = TimeZone.current.identifier
    var codexThreadID = ""
    var codexCLIPath = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reminderEnabled = try c.decodeIfPresent(Bool.self, forKey: .reminderEnabled) ?? true
        reminderHour = try c.decodeIfPresent(Int.self, forKey: .reminderHour) ?? 17
        reminderMinute = try c.decodeIfPresent(Int.self, forKey: .reminderMinute) ?? 0
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone) ?? TimeZone.current.identifier
        codexThreadID = try c.decodeIfPresent(String.self, forKey: .codexThreadID) ?? ""
        codexCLIPath = try c.decodeIfPresent(String.self, forKey: .codexCLIPath) ?? ""
    }
    func validate() throws {
        guard (0...23).contains(reminderHour), (0...59).contains(reminderMinute),
              TimeZone(identifier: timeZone) != nil,
              codexThreadID.isEmpty || UUID(uuidString: codexThreadID) != nil else {
            throw StoreError.invalid("检查提醒时间、时区与 Codex 对话 ID。")
        }
    }
    var reminderLabel: String {
        reminderEnabled ? String(format: "%02d:%02d 提醒", reminderHour, reminderMinute) : "提醒已关闭"
    }
}
enum StoreError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
enum DayClock {
    static func today(timeZone: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZone)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }
}
final class TaskStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("tasks.json") }
    var settingsFile: URL { directory.appendingPathComponent("settings.json") }
    init(directory: URL) { self.directory = directory }
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloatingTodo", isDirectory: true)
    }
    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try prepare()
        let descriptor = Darwin.open(directory.appendingPathComponent(".todo.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StoreError.invalid("无法创建数据锁。") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw StoreError.invalid("无法锁定任务数据。") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
    static func validate(_ state: State) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let day = formatter.date(from: state.date), formatter.string(from: day) == state.date,
              state.opacity.isFinite, (0.55...1).contains(state.opacity),
              Set(state.tasks.map { $0.id }).count == state.tasks.count,
              state.tasks.allSatisfy({ !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw StoreError.invalid("任务文件格式无效；原文件已保留，请检查日期、任务 ID 和标题。")
        }
    }
    private func write<T: Encodable>(_ value: T, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    func settings() throws -> Settings {
        try prepare()
        guard FileManager.default.fileExists(atPath: settingsFile.path) else {
            let defaults = Settings()
            try saveSettings(defaults)
            return defaults
        }
        let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsFile))
        try settings.validate()
        return settings
    }
    func saveSettings(_ settings: Settings) throws {
        try settings.validate()
        try prepare()
        try write(settings, to: settingsFile)
    }
    private func loadUnlocked(today: String) throws -> State {
        guard FileManager.default.fileExists(atPath: file.path) else {
            let initial = State(date: today, tasks: [], reminderShown: false, opacity: 0.92)
            try write(initial, to: file)
            return initial
        }
        var state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        try Self.validate(state)
        if state.date < today {
            let history = directory.appendingPathComponent("history", isDirectory: true)
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var archive = history.appendingPathComponent(state.date + ".json")
            if FileManager.default.fileExists(atPath: archive.path) {
                let prior = try? JSONDecoder().decode(State.self, from: Data(contentsOf: archive))
                if prior != state { archive = history.appendingPathComponent(state.date + "-" + UUID().uuidString + ".json") }
            }
            if !FileManager.default.fileExists(atPath: archive.path) { try write(state, to: archive) }
            state.date = today
            state.tasks = state.tasks.filter { !$0.done }
            state.reminderShown = false
            try write(state, to: file)
        }
        return state
    }
    func load(today: String) throws -> State { try locked { try loadUnlocked(today: today) } }
    func mutate(today: String, _ edit: (inout State) -> Void) throws -> State {
        try locked {
            var state = try loadUnlocked(today: today)
            edit(&state)
            try Self.validate(state)
            try write(state, to: file)
            return state
        }
    }
}
