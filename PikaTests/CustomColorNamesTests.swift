import Combine
import Defaults
@testable import Pika
import XCTest

final class CustomColorNamesTests: XCTestCase {
    private var directory: URL!
    private var store: CustomColorNamesStore!
    private var session: URLSession!
    private var savedDefaults: [String: Any] = [:]
    private let keys = ["useCustomColorNames", "colorNameList"]
    private let json = Data(##"{"colors":[{"name":" Canvas ","hex":"#aBcDeF"}],"version":1}"##.utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = CustomColorNamesStore(fileURL: directory.appendingPathComponent("saved.json"))
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        for key in keys {
            savedDefaults[key] = domain[key]
        }
        Defaults[.useCustomColorNames] = false
        Defaults[.colorNameList] = defaultColorListKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ColorNamesURLProtocol.self]
        session = URLSession(configuration: configuration)
        ColorNamesURLProtocol.handler = { request in
            if request.url?.path == "/lists/" {
                return (200, Data(##"{"availableColorNameLists":["default"]}"##.utf8), 0)
            }
            return (200, Data(##"{"colors":[{"name":"Remote","hex":"#123456"}]}"##.utf8), 0)
        }
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        for key in keys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try FileManager.default.removeItem(at: directory)
    }

    func test_decodeNormalizesNamesAndHexAndIgnoresMetadata() throws {
        let colors = try CustomColorNamesStore.decode(json)
        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors[0].name, "Canvas")
        XCTAssertEqual(colors[0].hex, "#ABCDEF")
    }

    func test_rejectsMalformedEmptyOrInvalidLists() {
        let invalid = [
            "{}", "[]", ##"{"colors":[]}"##,
            ##"{"colors":[{"name":" ","hex":"#FFFFFF"}]}"##,
            ##"{"colors":[{"name":"Ink","hex":"#FFF"}]}"##,
            ##"{"colors":[{"name":"Ink","hex":"#FFFFFF80"}]}"##,
            ##"{"colors":[{"name":"Ink","hex":"#GGGGGG"}]}"##,
            ##"{"colors":[{"name":"Ink","hex":123456}]}"##,
        ]
        for value in invalid {
            XCTAssertThrowsError(try CustomColorNamesStore.decode(Data(value.utf8)), value)
        }
        XCTAssertThrowsError(try CustomColorNamesStore.decode(Data(repeating: 0, count: CustomColorNamesStore.maximumBytes + 1)))
    }

    func test_rejectsTooManyColors() throws {
        let colors = Array(repeating: ColorName(name: "Ink", hex: "#123456"), count: 50001)
        let data = try JSONEncoder().encode(ResponseData(colors: colors))
        XCTAssertThrowsError(try CustomColorNamesStore.decode(data))
    }

    func test_duplicateColorsPreserveFirstNameForMatching() throws {
        let data = Data(##"{"colors":[{"name":"Ink","hex":"#123456"},{"name":"Text","hex":"#123456"}]}"##.utf8)
        let colors = try CustomColorNamesStore.decode(data)
        let matcher = ClosestVector(colors.map { $0.color.toRGB8BitArray() })
        XCTAssertEqual(colors[matcher.compare(colors[0].color)].name, "Ink")
    }

    func test_remoteURLRequiresHTTPSWithoutCredentials() throws {
        XCTAssertEqual(try CustomColorNamesStore.remoteURL(" https://example.com/colors.json?version=1 \n").host, "example.com")
        for value in ["http://example.com/colors.json", "file:///tmp/colors.json", "example.com", "https://", "https://user:pass@example.com"] {
            XCTAssertThrowsError(try CustomColorNamesStore.remoteURL(value))
        }
    }

    @MainActor
    func test_importSurvivesOriginalFileRemovalAndManagerRestart() async throws {
        let url = directory.appendingPathComponent("design-system.json")
        try json.write(to: url)
        let manager = ColorNamesManager(session: session, customStore: store)
        manager.importCustomFile(url)
        await waitForLoad(manager)
        XCTAssertNil(manager.lastErrorMessage)
        XCTAssertTrue(Defaults[.useCustomColorNames])
        XCTAssertEqual(manager.customList?.title, "design-system.json")
        XCTAssertNil(manager.customList?.sourceURL)
        try FileManager.default.removeItem(at: url)
        let restarted = ColorNamesManager(session: session, customStore: store)
        XCTAssertEqual(restarted.currentColorNames().first?.name, "Canvas")
        restarted.refreshAll()
        XCTAssertFalse(restarted.isLoadingCustom, "Imported files are not watched or downloaded")
    }

    @MainActor
    func test_invalidReplacementLeavesActiveListAndSavedCopyUntouched() async throws {
        let manager = try makeImportedManager()
        let before = try Data(contentsOf: store.fileURL)
        let invalid = directory.appendingPathComponent("invalid.json")
        try Data(##"{"colors":[{"name":"bad","hex":"invalid"}]}"##.utf8).write(to: invalid)
        manager.importCustomFile(invalid)
        await waitForLoad(manager)
        XCTAssertNotNil(manager.lastErrorMessage)
        XCTAssertEqual(manager.currentColorNames().first?.name, "Canvas")
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    @MainActor
    func test_remoteRefreshKeepsSavedNamesAfterHTTPErrorOrInvalidJSON() async throws {
        let manager = ColorNamesManager(session: session, customStore: store)
        manager.loadCustomURL("https://example.com/colors.json")
        await waitForLoad(manager)
        XCTAssertNil(manager.lastErrorMessage)
        XCTAssertEqual(manager.currentColorNames().first?.name, "Remote")
        XCTAssertEqual(manager.customList?.sourceURL?.absoluteString, "https://example.com/colors.json")
        let before = try Data(contentsOf: store.fileURL)

        ColorNamesURLProtocol.handler = { _ in (503, self.json, 0) }
        manager.refreshAll()
        await waitForLoad(manager)
        XCTAssertTrue(manager.lastErrorMessage?.contains("503") == true)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)

        ColorNamesURLProtocol.handler = { _ in (200, Data("not json".utf8), 0) }
        manager.refreshAll()
        await waitForLoad(manager)
        XCTAssertNotNil(manager.lastErrorMessage)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(manager.currentColorNames().first?.name, "Remote")
    }

    @MainActor
    func test_failedFirstURLDoesNotActivateCustomNames() async {
        let manager = ColorNamesManager(session: session, customStore: store)
        ColorNamesURLProtocol.handler = { _ in (404, self.json, 0) }
        manager.loadCustomURL("https://example.com/missing.json")
        await waitForLoad(manager)
        XCTAssertFalse(Defaults[.useCustomColorNames])
        XCTAssertNil(manager.customList)
        XCTAssertNil(store.load())
    }

    @MainActor
    func test_switchingToCatalogueDiscardsPendingCustomDownload() async throws {
        let manager = try makeImportedManager()
        let before = try Data(contentsOf: store.fileURL)
        ColorNamesURLProtocol.handler = { request in
            (200, self.json, request.url?.host == "example.com" ? 0.2 : 0)
        }
        manager.loadCustomURL("https://example.com/colors.json")
        manager.selectList(defaultColorListKey)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(Defaults[.useCustomColorNames])
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertNil(manager.customList?.sourceURL)
        manager.selectCustomList()
        XCTAssertTrue(Defaults[.useCustomColorNames])
        XCTAssertEqual(manager.currentColorNames().first?.name, "Canvas")
    }

    @MainActor
    func test_newFileSelectionWinsOverPendingURL() async throws {
        let manager = try makeImportedManager()
        ColorNamesURLProtocol.handler = { _ in (200, self.json, 0.2) }
        manager.loadCustomURL("https://example.com/colors.json")
        let url = directory.appendingPathComponent("new.json")
        try Data(##"{"colors":[{"name":"New","hex":"#000000"}]}"##.utf8).write(to: url)
        manager.importCustomFile(url)
        await waitForLoad(manager)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(manager.currentColorNames().first?.name, "New")
        XCTAssertEqual(store.load()?.colors.first?.name, "New")
        XCTAssertNil(manager.customList?.sourceURL)
    }

    @MainActor
    func test_writeFailureDoesNotReplaceWorkingNames() async throws {
        let manager = try makeImportedManager()
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        manager.loadCustomURL("https://example.com/colors.json")
        await waitForLoad(manager)
        XCTAssertNotNil(manager.lastErrorMessage)
        XCTAssertEqual(manager.currentColorNames().first?.name, "Canvas")
    }

    private func makeImportedManager() throws -> ColorNamesManager {
        let colors = try CustomColorNamesStore.decode(json)
        try store.save(CustomColorNameList(id: UUID(), title: "Saved", sourceURL: nil, updatedAt: Date(), colors: colors))
        Defaults[.useCustomColorNames] = true
        return ColorNamesManager(session: session, customStore: store)
    }

    @MainActor
    private func waitForLoad(_ manager: ColorNamesManager, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0 ..< 200 {
            if !manager.isLoadingCustom { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Colour-name load timed out", file: file, line: line)
    }
}

private final class ColorNamesURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data, TimeInterval))?
    private var work: DispatchWorkItem?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else { return }
        let (status, data, delay) = handler(request)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.work?.isCancelled == false else { return }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    override func stopLoading() { work?.cancel() }
}
