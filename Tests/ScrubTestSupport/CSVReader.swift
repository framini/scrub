import Foundation

/// A CSV reader for test oracles, independent of ScrubCore's.
public enum CSVReader {
    public static func rows(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            if quoted {
                if character == "\"" {
                    if characters.first == "\"" { field.append("\""); characters.removeFirst() } else { quoted = false }
                } else { field.append(character) }
            } else if character == "\"" { quoted = true }
            else if character == "," { row.append(field); field = "" }
            else if character == "\n" || character == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else if character != "\r" { field.append(character) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
