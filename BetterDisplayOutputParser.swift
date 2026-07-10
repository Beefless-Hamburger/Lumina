import Foundation

func parseDisplayNames(from output: String) -> [String] {
    parseDisplayDictionaries(from: output).compactMap(displayName).uniquedAndSorted()
}

func parseDisplayTargets(from output: String) -> [DisplayTarget] {
    let records = parseDisplayDictionaries(from: output).compactMap { dictionary -> (identifier: String, name: String)? in
        guard let identifier = dictionary["UUID"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let name = displayName(from: dictionary) else { return nil }
        return (identifier.trimmingCharacters(in: .whitespacesAndNewlines), name)
    }
    let nameCounts = Dictionary(grouping: records, by: \.name).mapValues(\.count)
    var nameIndexes: [String: Int] = [:]

    return records.map { record in
        nameIndexes[record.name, default: 0] += 1
        let label = nameCounts[record.name, default: 0] > 1
            ? "\(record.name) (\(nameIndexes[record.name, default: 1]))"
            : record.name
        return DisplayTarget(identifier: record.identifier, name: record.name, selectionLabel: label)
    }.sorted { $0.selectionLabel.localizedCaseInsensitiveCompare($1.selectionLabel) == .orderedAscending }
}

private func parseDisplayDictionaries(from output: String) -> [[String: Any]] {
    let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedOutput.isEmpty else {
        return []
    }

    if let dictionaries = parseDictionaries(fromSinglePayload: trimmedOutput) {
        return dictionaries
    }

    let scan = scanJSONObjectPayloads(in: trimmedOutput)
    var dictionaries = scan.objects.compactMap(parseDictionary)

    // Recover valid one-line records after an unterminated malformed object.
    if scan.hasUnterminatedObject {
        dictionaries.append(contentsOf: trimmedOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> [String: Any]? in
                let cleanedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ","))
                return parseDictionary(cleanedLine[...])
            })
    }

    return dictionaries
}

private struct JSONObjectScan {
    let objects: [Substring]
    let hasUnterminatedObject: Bool
}

private func parseDictionaries(fromSinglePayload payload: String) -> [[String: Any]]? {
    guard let data = payload.data(using: .utf8) else {
        return nil
    }

    if let dictionaries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        return dictionaries
    }

    if let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return [dictionary]
    }

    return nil
}

private func parseDictionary(_ payload: Substring) -> [String: Any]? {
    guard !payload.isEmpty, let data = String(payload).data(using: .utf8) else {
        return nil
    }

    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func scanJSONObjectPayloads(in payload: String) -> JSONObjectScan {
    var objects: [Substring] = []
    var objectStart: String.Index?
    var depth = 0
    var isInsideString = false
    var isEscaping = false

    for index in payload.indices {
        let character = payload[index]

        guard objectStart != nil else {
            if character == "{" {
                objectStart = index
                depth = 1
                isInsideString = false
                isEscaping = false
            }
            continue
        }

        if isInsideString {
            if isEscaping {
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else if character == "\"" {
                isInsideString = false
            }
            continue
        }

        switch character {
        case "\"":
            isInsideString = true
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0, let start = objectStart {
                objects.append(payload[start...index])
                objectStart = nil
                isInsideString = false
                isEscaping = false
            }
        default:
            break
        }
    }

    return JSONObjectScan(objects: objects, hasUnterminatedObject: objectStart != nil)
}

private func extractDisplayNames(from dictionaries: [[String: Any]]) -> [String] {
    dictionaries.compactMap(displayName).uniquedAndSorted()
}

private func displayName(from dictionary: [String: Any]) -> String? {
        if let rawDeviceType = dictionary["deviceType"] {
            guard let deviceType = rawDeviceType as? String,
                  deviceType.localizedCaseInsensitiveCompare("Display") == .orderedSame else {
                return nil
            }
        }

        guard let rawName = dictionary["name"] as? String else {
            return nil
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.localizedCaseInsensitiveCompare("Default Group") != .orderedSame else {
            return nil
        }

        return name
}

private extension Array where Element == String {
    func uniquedAndSorted() -> [String] {
        var seenNames = Set<String>()
        return filter { seenNames.insert($0).inserted }.sorted { lhs, rhs in
        let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
        if comparison == .orderedSame {
            return lhs < rhs
        }
        return comparison == .orderedAscending
        }
    }
}
