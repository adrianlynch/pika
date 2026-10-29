import Cocoa
import Defaults

struct ColorName: Codable {
    public var name: String
    public var hex: String
    public var color: NSColor {
        NSColor(hex: hex)
    }
}

struct ResponseData: Codable {
    var colors: [ColorName]
}

/// A named colour list published by the color.pizza API (`/v1/lists/`).
struct ColorListInfo: Identifiable, Hashable {
    let key: String
    let title: String
    var id: String { key }
}

/// The key of the list selected out of the box, and the one we fall back to when the chosen
/// list is no longer offered by the API.
let defaultColorListKey = "default"

/// Loads the colour list bundled with the app (`ColorNames.json`), used as the offline
/// fallback until (and if) a network refresh caches a newer copy. It's a snapshot of
/// color-name-list's best-of list; refresh it with `scripts/update-color-names` before
/// each release.
func loadColors() -> [ColorName]? {
    if let url = Bundle.main.url(forResource: "ColorNames", withExtension: "json") {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let jsonData = try decoder.decode(ResponseData.self, from: data)
            return jsonData.colors
        } catch {
            print("error:\(error)")
        }
    }
    return nil
}

/// Owns colour-name data from color.pizza or an imported custom file/URL.
///
/// - A snapshot list is bundled with the app (refreshed before each release), so names
///   always work offline.
/// - On launch the currently-selected list is refreshed from the network and cached on disk.
/// - Settings and the splash let the user pick any list from `/v1/lists/`; if the chosen
///   list is no longer offered by the API, we fall back to `default`.
/// - Custom names use a separate snapshot; API catalogue changes never replace it.
///
/// Reloads are broadcast via `.colorNamesUpdated` so the eyedroppers rebuild their lookup.
final class ColorNamesManager: ObservableObject {
    static let shared = ColorNamesManager()

    /// Lists offered by the API, for the picker UI. Empty until fetched from the network.
    @Published private(set) var availableLists: [ColorListInfo] = []

    /// True while a catalogue or colour fetch is in flight. Drives the picker's spinner.
    @Published private(set) var isFetching = false

    /// When the active list's cached colours were last refreshed from the network (the
    /// cache file's modification date), or nil if only the bundled default is in use.
    @Published private(set) var lastUpdated: Date?

    /// A friendly description of the most recent refresh failure, cleared on success. Shown
    /// in the picker's tooltip so an offline / API problem is visible rather than silent.
    @Published private(set) var lastErrorMessage: String?

    @Published private(set) var customList: CustomColorNameList?
    @Published private(set) var isLoadingCustom = false

    private let customStore: CustomColorNamesStore
    private let customColorsLock = NSLock()
    private var customColors: [ColorName] = []
    private let session: URLSession
    private var customLoadID: UUID?
    private var customTask: URLSessionDataTask?
    private let apiBase = "https://api.color.pizza/v1"

    /// How often to re-check the API while the app keeps running.
    private let refreshInterval: TimeInterval = 6 * 60 * 60
    /// Skip a foreground-triggered refresh if one was attempted within this window.
    private let foregroundThrottle: TimeInterval = 30 * 60
    private var refreshTimer: Timer?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var lastRefreshAttempt: Date?
    /// Count of in-flight requests, so overlapping fetches keep `isFetching` accurate.
    private var inFlight = 0

    init(session: URLSession = .shared, customStore: CustomColorNamesStore = .standard) {
        self.session = session
        self.customStore = customStore
        customList = customStore.load()
        customColors = customList?.colors ?? []
    }

    /// A human-readable summary of the current refresh state, for the picker's tooltip.
    var statusDescription: String {
        if isFetching || isLoadingCustom { return PikaText.textColorListStatusChecking }
        if let lastErrorMessage { return lastErrorMessage }
        if let lastUpdated {
            return String(format: PikaText.textColorListStatusUpdatedFormat,
                          Self.statusDateFormatter.string(from: lastUpdated))
        }
        return PikaText.textColorListStatusBuiltIn
    }

    // MARK: - Loading names for the current list

    /// The colour names for the currently-selected list: the on-disk cache if present,
    /// otherwise the bundled `default` list.
    func currentColorNames() -> [ColorName] {
        // Eyedroppers call this on background queues while imports publish on the main queue.
        if Defaults[.useCustomColorNames] {
            customColorsLock.lock()
            defer { customColorsLock.unlock() }
            return customColors
        }
        let key = Defaults[.colorNameList]
        if let url = Self.cacheURL(for: key),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ResponseData.self, from: data),
           !decoded.colors.isEmpty
        {
            return decoded.colors
        }
        return loadColors() ?? []
    }

    // MARK: - Launch & periodic update

    /// Kicks off the first refresh, then keeps the data current: a repeating timer re-checks
    /// the API every few hours, and re-activating the app triggers a (throttled) refresh.
    /// Safe to call once on launch; any failure leaves the cached / bundled data untouched.
    func updateOnLaunch() {
        refreshLastUpdated()
        refreshAll()
        schedulePeriodicRefresh()
        observeAppActivation()
    }

    /// Refreshes the catalogue and the selected list's colours. Falls the selection back to
    /// `default` if the chosen list is no longer offered. Safe to call repeatedly.
    func refreshAll() {
        lastRefreshAttempt = Date()
        if Defaults[.useCustomColorNames] {
            refreshCustomList()
            return
        }
        let selectedKey = Defaults[.colorNameList]
        fetchLists { [weak self] infos, availableKeys in
            guard let self else { return }
            if !infos.isEmpty { self.availableLists = infos }
            guard !Defaults[.useCustomColorNames], Defaults[.colorNameList] == selectedKey else { return }

            // Fall back to `default` if the chosen list is no longer available.
            var key = Defaults[.colorNameList]
            if !availableKeys.isEmpty, !availableKeys.contains(key) {
                key = defaultColorListKey
                Defaults[.colorNameList] = key
                self.refreshLastUpdated()
                NotificationCenter.default.post(name: .colorNamesUpdated, object: nil)
            }
            self.refreshColors(for: key)
        }
    }

    private func schedulePeriodicRefresh() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func observeAppActivation() {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Don't hammer the API every time focus returns — refresh at most twice an hour.
            if let last = self.lastRefreshAttempt,
               Date().timeIntervalSince(last) < self.foregroundThrottle { return }
            self.refreshAll()
        }
    }

    /// Ensures the picker has a catalogue to show; used when Settings / the splash appear.
    func loadAvailableListsIfNeeded() {
        guard availableLists.isEmpty else { return }
        fetchLists { [weak self] infos, _ in
            if !infos.isEmpty { self?.availableLists = infos }
        }
    }

    /// Switches the active list: reflects the change immediately from cache / bundle, then
    /// fetches the latest colours for the newly-chosen list in the background.
    func selectList(_ key: String) {
        guard key != Defaults[.colorNameList] || Defaults[.useCustomColorNames] || isLoadingCustom else { return }
        cancelCustomLoad()
        Defaults[.useCustomColorNames] = false
        Defaults[.colorNameList] = key
        lastErrorMessage = nil
        refreshLastUpdated()
        NotificationCenter.default.post(name: .colorNamesUpdated, object: nil)
        refreshColors(for: key)
    }

    private func refreshColors(for key: String) {
        fetchColors(for: key) { [weak self] result in
            guard let self else { return }
            guard !Defaults[.useCustomColorNames], Defaults[.colorNameList] == key else { return }
            switch result {
            case .success:
                self.lastErrorMessage = nil
                // Only signal a reload if this is still the active list when the fetch lands.
                guard Defaults[.colorNameList] == key else { return }
                self.refreshLastUpdated()
                NotificationCenter.default.post(name: .colorNamesUpdated, object: nil)
            case let .failure(message):
                self.lastErrorMessage = message
            }
        }
    }

    /// Recomputes `lastUpdated` from the active list's cache file modification date.
    private func refreshLastUpdated() {
        lastUpdated = Defaults[.useCustomColorNames]
            ? customList?.updatedAt : Self.cacheModificationDate(for: Defaults[.colorNameList])
    }

    // MARK: - Custom files and URLs

    func selectCustomList() {
        guard customList != nil else { return }
        cancelCustomLoad()
        Defaults[.useCustomColorNames] = true
        lastErrorMessage = nil
        refreshLastUpdated()
        NotificationCenter.default.post(name: .colorNamesUpdated, object: nil)
        refreshCustomList()
    }

    func importCustomFile(_ url: URL) {
        let loadID = beginCustomLoad()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CustomColorNamesStore.importFile(url) }
            DispatchQueue.main.async { self?.finishCustomLoad(result, id: loadID) }
        }
    }

    func loadCustomURL(_ value: String) {
        let loadID = beginCustomLoad()
        do {
            let url = try CustomColorNamesStore.remoteURL(value)
            customTask = CustomColorNamesStore.download(url, session: session) { [weak self] result in
                self?.finishCustomLoad(result, id: loadID)
            }
        } catch {
            finishCustomLoad(.failure(error), id: loadID)
        }
    }

    private func refreshCustomList() {
        guard !isLoadingCustom else { return }
        guard let customList else {
            lastErrorMessage = String(localized: "Your custom colour list is unavailable. Import it again or choose a color.pizza list.")
            return
        }
        if let url = customList.sourceURL { loadCustomURL(url.absoluteString) }
    }

    private func beginCustomLoad() -> UUID {
        cancelCustomLoad()
        let id = UUID()
        customLoadID = id
        isLoadingCustom = true
        lastErrorMessage = nil
        return id
    }

    private func cancelCustomLoad() {
        customLoadID = nil
        customTask?.cancel()
        customTask = nil
        isLoadingCustom = false
    }

    private func finishCustomLoad(_ result: Result<CustomColorNameList, Error>, id: UUID) {
        // A late URL/file result must not undo a newer selection or overwrite its snapshot.
        guard customLoadID == id else { return }
        defer { cancelCustomLoad() }
        do {
            let list = try result.get()
            try customStore.save(list)
            customColorsLock.lock()
            customColors = list.colors
            customColorsLock.unlock()
            customList = list
            Defaults[.useCustomColorNames] = true
            lastErrorMessage = nil
            refreshLastUpdated()
            NotificationCenter.default.post(name: .colorNamesUpdated, object: nil)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Fetch-state tracking

    private func beginFetch() {
        inFlight += 1
        isFetching = true
    }

    private func endFetch() {
        inFlight = max(0, inFlight - 1)
        if inFlight == 0 { isFetching = false }
    }

    // MARK: - Networking

    private enum FetchResult {
        case success
        case failure(String)
    }

    private func fetchLists(completion: @escaping ([ColorListInfo], Set<String>) -> Void) {
        guard let url = URL(string: "\(apiBase)/lists/") else { completion([], []); return }
        beginFetch()
        session.dataTask(with: url) { [weak self] data, _, _ in
            let parsed = data.flatMap { Self.parseLists($0) }
            DispatchQueue.main.async {
                self?.endFetch()
                completion(parsed?.0 ?? [], parsed?.1 ?? [])
            }
        }.resume()
    }

    private func fetchColors(for key: String, completion: @escaping (FetchResult) -> Void) {
        guard let escaped = key.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed),
              let url = URL(string: "\(apiBase)/?list=\(escaped)")
        else { completion(.failure(PikaText.textColorListStatusOffline)); return }
        beginFetch()
        session.dataTask(with: url) { [weak self] data, _, error in
            let result: FetchResult
            if error != nil {
                result = .failure(PikaText.textColorListStatusOffline)
            } else if let data,
                      let decoded = try? JSONDecoder().decode(ResponseData.self, from: data),
                      !decoded.colors.isEmpty,
                      let cacheURL = Self.cacheURL(for: key),
                      (try? data.write(to: cacheURL, options: .atomic)) != nil
            {
                result = .success
            } else {
                result = .failure(PikaText.textColorListStatusOffline)
            }
            DispatchQueue.main.async {
                self?.endFetch()
                completion(result)
            }
        }.resume()
    }

    // MARK: - Parsing

    private struct ListsResponse: Decodable {
        let availableColorNameLists: [String]?
        let listDescriptions: [String: ListDescription]?
    }

    private struct ListDescription: Decodable {
        let title: String?
    }

    /// Parses `/v1/lists/` into `(orderedInfos, availableKeys)`, tolerating either the
    /// `availableColorNameLists` array or the `listDescriptions` map being absent, and
    /// guaranteeing that `default` is always present and listed first.
    private static func parseLists(_ data: Data) -> ([ColorListInfo], Set<String>)? {
        guard let response = try? JSONDecoder().decode(ListsResponse.self, from: data) else { return nil }

        let descriptions = response.listDescriptions ?? [:]
        // Prefer the authoritative `availableColorNameLists` ordering; otherwise use the described keys.
        var keys = response.availableColorNameLists ?? Array(descriptions.keys).sorted()
        guard !keys.isEmpty else { return nil }

        // Ensure the bundled default is always offered and appears first.
        keys.removeAll { $0 == defaultColorListKey }
        keys.insert(defaultColorListKey, at: 0)

        let infos = keys.map { key -> ColorListInfo in
            // Keep `default` recognisable regardless of how the API labels it.
            let title = key == defaultColorListKey
                ? Self.prettify(key)
                : (descriptions[key]?.title ?? Self.prettify(key))
            return ColorListInfo(key: key, title: title)
        }
        return (infos, Set(keys))
    }

    /// A readable title for a list key the API didn't describe: `sanzoWadaI` -> `Sanzo Wada I`.
    private static func prettify(_ key: String) -> String {
        if key == defaultColorListKey { return PikaText.textColorListDefault }
        var result = ""
        for (index, character) in key.enumerated() {
            if index == 0 {
                result.append(Character(String(character).uppercased()))
            } else if character.isUppercase {
                result.append(" ")
                result.append(character)
            } else {
                result.append(character)
            }
        }
        return result
    }

    // MARK: - Cache location

    private static func cacheDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("Pika/ColorLists", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(for key: String) -> URL? {
        // Guard against odd list keys resolving to unexpected paths.
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory()?.appendingPathComponent("\(safeKey).json")
    }

    private static func cacheModificationDate(for key: String) -> Date? {
        guard let url = cacheURL(for: key),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    // MARK: - Formatting

    private static let statusDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension CharacterSet {
    /// Query-value-safe set: the query set minus the sub-delims that break `?list=` values.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?+/")
        return set
    }()
}
