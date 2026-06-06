import Foundation

func parseDisplayNames(from output: String) -> [String] {
    let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedOutput.isEmpty else {
        return []
    }

    if let names = parseDisplayNames(fromSinglePayload: trimmedOutput) {
        return names
    }

    if let names = parseDisplayNames(fromWrappedPayload: trimmedOutput) {
        return names
    }

    let dictionaries = trimmedOutput
        .split(whereSeparator: \.isNewline)
        .compactMap { line -> [String: Any]? in
            let cleanedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ","))

            guard !cleanedLine.isEmpty, let data = cleanedLine.data(using: .utf8) else {
                return nil
            }

            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

    return extractDisplayNames(from: dictionaries)
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

private func parseDisplayNames(fromWrappedPayload payload: String) -> [String]? {
    let cleanedPayload = payload
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: ","))

    guard !cleanedPayload.isEmpty else {
        return nil
    }

    let wrappedPayload = "[\(cleanedPayload)]"
    guard let data = wrappedPayload.data(using: .utf8) else {
        return nil
    }

    guard let dictionaries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return nil
    }

    return extractDisplayNames(from: dictionaries)
}

private func extractDisplayNames(from dictionaries: [[String: Any]]) -> [String] {
    let candidates = dictionaries.compactMap { dictionary -> String? in
        if let deviceType = dictionary["deviceType"] as? String,
           deviceType.localizedCaseInsensitiveCompare("Display") != .orderedSame {
            return nil
        }

        guard let rawName = dictionary["name"] as? String else {
            return nil
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "Default Group" else {
            return nil
        }

        return name
    }

    var seenNames = Set<String>()
    var uniqueNames: [String] = []
    for name in candidates where seenNames.insert(name).inserted {
        uniqueNames.append(name)
    }

    return uniqueNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}
