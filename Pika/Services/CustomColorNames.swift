import Foundation

/// A validated snapshot. Files are imported once; URLs can refresh the same snapshot.
struct CustomColorNameList: Codable {
    let id: UUID
    let title: String
    let sourceURL: URL?
    let updatedAt: Date
    let colors: [ColorName]
}

enum CustomColorNamesError: LocalizedError {
    case invalidURL, invalidJSON, emptyList, invalidColor, tooLarge, httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Enter a complete HTTPS URL for your JSON colour list.")
        case .invalidJSON:
            return String(localized: "The JSON must contain a colors array with name and hex strings.")
        case .emptyList:
            return String(localized: "The colour list must contain at least one colour.")
        case .invalidColor:
            return String(localized: "Each colour needs a non-empty name and an sRGB hex value in #RRGGBB format.")
        case .tooLarge:
            return String(localized: "Colour lists must be no larger than 5 MB and contain at most 50,000 colours.")
        case let .httpStatus(status):
            return String(format: String(localized: "The server returned HTTP %d. Your saved colours have not changed."), status)
        }
    }
}

/// Kept separate from color.pizza's caches so catalogue refreshes cannot overwrite imports.
struct CustomColorNamesStore {
    let fileURL: URL
    static let maximumBytes = 5 * 1024 * 1024

    static var standard: CustomColorNamesStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(fileURL: base.appendingPathComponent("Pika/CustomColorNames.json"))
    }

    func load() -> CustomColorNameList? {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode(CustomColorNameList.self, from: data),
              !list.colors.isEmpty else { return nil }
        return list
    }

    func save(_ list: CustomColorNameList) throws {
        let data = try JSONEncoder().encode(list)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    static func remoteURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { throw CustomColorNamesError.invalidURL }
        return url
    }

    static func decode(_ data: Data) throws -> [ColorName] {
        guard data.count <= maximumBytes else { throw CustomColorNamesError.tooLarge }
        guard let response = try? JSONDecoder().decode(ResponseData.self, from: data) else {
            throw CustomColorNamesError.invalidJSON
        }
        guard !response.colors.isEmpty else { throw CustomColorNamesError.emptyList }
        guard response.colors.count <= 50000 else { throw CustomColorNamesError.tooLarge }
        return try response.colors.map { color in
            let name = color.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, color.hex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
                throw CustomColorNamesError.invalidColor
            }
            return ColorName(name: name, hex: color.hex.uppercased())
        }
    }

    static func importFile(_ url: URL) throws -> CustomColorNameList {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw CustomColorNamesError.tooLarge }
        let colors = try decode(Data(contentsOf: url))
        return CustomColorNameList(id: UUID(), title: url.lastPathComponent, sourceURL: nil, updatedAt: Date(), colors: colors)
    }

    static func download(
        _ url: URL,
        session: URLSession,
        completion: @escaping (Result<CustomColorNameList, Error>) -> Void
    ) -> URLSessionDataTask {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request) { data, response, error in
            let result = Result { () -> CustomColorNameList in
                if let error { throw error }
                guard let response = response as? HTTPURLResponse else { throw CustomColorNamesError.invalidJSON }
                guard (200 ..< 300).contains(response.statusCode) else {
                    throw CustomColorNamesError.httpStatus(response.statusCode)
                }
                guard let data else { throw CustomColorNamesError.invalidJSON }
                let colors = try decode(data)
                return CustomColorNameList(
                    id: UUID(), title: url.host ?? url.absoluteString, sourceURL: url, updatedAt: Date(), colors: colors
                )
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }
}
