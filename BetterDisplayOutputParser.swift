import Foundation

func parseDisplayNames(from output: String) -> [String] {
    let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedOutput.isEmpty else {
        return []
    }

    if let names = parseDisplayNames(fromSinglePayload: trimmedOutput) {
        return names
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

    return extractDisplayNames(from: dictionaries)
}

private struct JSONObjectScan {
    let objects: [Substring]
    let hasUnterminatedObject: Bool
}

private func parseDisplayNames(fromSinglePayload payload: String) -> [String]? {
    guard let data = payload.data(using: .utf8) else {
        return nil
    }

    if let dictionaries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        return extractDisplayNames(from: dictionaries)
    }

    if let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return extractDisplayNames(from: [dictionary])
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
    let candidates = dictionaries.compactMap { dictionary -> String? in
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

    var seenNames = Set<String>()
    var uniqueNames: [String] = []
    for name in candidates where seenNames.insert(name).inserted {
        uniqueNames.append(name)
    }

    return uniqueNames.sorted { lhs, rhs in
        let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
        if comparison == .orderedSame {
            return lhs < rhs
        }
        return comparison == .orderedAscending
    }
}
