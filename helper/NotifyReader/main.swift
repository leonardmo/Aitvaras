// notify-reader — Aitvaras's notification-database helper.
//
// SECURITY CONTRACT (the reason this binary exists, see D21):
// The user grants Full Disk Access to THIS binary only, never to Aitvaras
// itself. Before doing anything else, it locks itself into a kernel
// sandbox (seatbelt): no network, no file writes, no reads inside the
// home directory except the Notification Center database. Even a fully
// compromised notify-reader cannot exfiltrate (no network) or touch
// other files (kernel-denied). It opens the database read-only and
// immutable — it cannot take locks or modify it.
//
// Usage: notify-reader --since <unix-epoch-seconds>
// Output: one JSON object per notification on stdout.

import Foundation
import SQLite3

// MARK: Kernel sandbox — MUST run before anything else touches the system.

typealias SandboxInitFn = @convention(c) (
    UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

func enterSandbox() {
    let home = NSHomeDirectory()
    let notificationDB = "\(home)/Library/Group Containers/group.com.apple.usernoted"
    // SBPL: later rules win. Deny writes + network everywhere, deny the
    // whole home directory, then re-allow only the notification store.
    let profile = """
    (version 1)
    (allow default)
    (deny network*)
    (deny file-write*)
    (deny file-read* (subpath "\(home)"))
    (allow file-read* (subpath "\(notificationDB)"))
    """

    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "sandbox_init") else {
        FileHandle.standardError.write(Data("sandbox_init unavailable — refusing to run\n".utf8))
        exit(3)
    }
    let sandboxInit = unsafeBitCast(symbol, to: SandboxInitFn.self)
    var errorBuffer: UnsafeMutablePointer<CChar>?
    guard sandboxInit(profile, 0, &errorBuffer) == 0 else {
        let message = errorBuffer.map { String(cString: $0) } ?? "unknown"
        FileHandle.standardError.write(Data("sandbox_init failed: \(message) — refusing to run\n".utf8))
        exit(3)
    }
}

enterSandbox()

// MARK: Arguments

var since: Double = Date().timeIntervalSince1970 - 3600
if let index = CommandLine.arguments.firstIndex(of: "--since"),
   CommandLine.arguments.count > index + 1,
   let value = Double(CommandLine.arguments[index + 1]) {
    since = value
}

// MARK: Read the database (immutable snapshot, read-only)

let dbPath = "\(NSHomeDirectory())/Library/Group Containers/group.com.apple.usernoted/db2/db"
var db: OpaquePointer?
let uri = "file:\(dbPath)?immutable=1"
guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
    FileHandle.standardError.write(Data("cannot open notification db (Full Disk Access missing for notify-reader?)\n".utf8))
    exit(2)
}
defer { sqlite3_close(db) }

// delivered_date uses the Core Data epoch (2001-01-01).
let coreDataEpochOffset = 978_307_200.0
let sinceCoreData = since - coreDataEpochOffset

let sql = """
SELECT (SELECT identifier FROM app WHERE app.app_id = record.app_id) AS app,
       record.delivered_date, record.data
FROM record
WHERE record.delivered_date > ?
ORDER BY record.delivered_date ASC
LIMIT 200
"""
var statement: OpaquePointer?
guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
    FileHandle.standardError.write(Data("unexpected schema in notification db\n".utf8))
    exit(2)
}
defer { sqlite3_finalize(statement) }
sqlite3_bind_double(statement, 1, sinceCoreData)

func jsonEscape(_ value: String) -> String {
    var out = ""
    for char in value.unicodeScalars {
        switch char {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if char.value < 0x20 { out += String(format: "\\u%04x", char.value) }
            else { out.unicodeScalars.append(char) }
        }
    }
    return out
}

while sqlite3_step(statement) == SQLITE_ROW {
    let app = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "unknown"
    let delivered = sqlite3_column_double(statement, 1) + coreDataEpochOffset

    var title = "", subtitle = "", body = ""
    if let blob = sqlite3_column_blob(statement, 2) {
        let length = Int(sqlite3_column_bytes(statement, 2))
        let data = Data(bytes: blob, count: length)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let request = plist["req"] as? [String: Any] {
            title = request["titl"] as? String ?? ""
            subtitle = request["subt"] as? String ?? ""
            body = request["body"] as? String ?? ""
        }
    }
    guard !(title.isEmpty && body.isEmpty) else { continue }
    print(#"{"app": "\#(jsonEscape(app))", "deliveredAt": \#(delivered), "title": "\#(jsonEscape(title))", "subtitle": "\#(jsonEscape(subtitle))", "body": "\#(jsonEscape(body))"}"#)
}
