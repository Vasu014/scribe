import TranscribeKit
import XCTest

/// The regression that cost the most: transcription was silently disabled for
/// months of real use because the model folder was handed to WhisperKit
/// percent-ENCODED.
///
/// `URL.path()` (macOS 13+) escapes the space in "Application Support" — which
/// is where `ModelDownloadManager.defaultModelRoot` lives — so WhisperKit was
/// asked to open a directory called `Application%20Support`, no such directory
/// existed, every load failed with `modelsUnavailable`, and the app fell back
/// to recording meetings with no transcript. Nothing on screen said so.
///
/// These tests run against a REAL fixture tree whose path contains a space, and
/// the load-bearing assertion is that the string the locator produces can
/// actually be opened by `FileManager` — not that it equals some expected
/// literal, which is the check that would have passed with the bug in place.
final class WhisperModelLocatorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The space is the whole point — it reproduces "Application Support".
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Scribe Model Tests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// Lays out the Hub cache shape the locator's heuristic expects:
    /// `…/models/argmaxinc/whisperkit-coreml/snapshots/<hash>/openai_whisper-<variant>/X.mlmodelc`.
    @discardableResult
    private func makeVariant(_ variant: String) throws -> URL {
        let folder = root
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/snapshots/abc123", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(variant)", isDirectory: true)
        let bundle = folder.appendingPathComponent("MelSpectrogram.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data().write(to: bundle.appendingPathComponent("coremldata.bin"))
        return folder
    }

    // MARK: The percent-encoding regression

    /// THE test. The path handed to WhisperKit must be openable.
    func testModelFolderArgumentIsAFilesystemPathNotAPercentEncodedURLPath() throws {
        let folder = try makeVariant("large-v3")

        let argument = WhisperModelLocator.modelFolderArgument(folder)

        // The bug in one line: `folder.path()` would produce
        // "…/Scribe%20Model%20Tests%20…/…", which no POSIX API can open.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: argument),
            "WhisperKit is handed \(argument), which does not exist on disk"
        )
        XCTAssertTrue(argument.contains(" "), "the space in the fixture path was escaped away")
        XCTAssertFalse(argument.contains("%20"), "the path is percent-encoded — this is the shipped defect")
        XCTAssertFalse(argument.contains("file://"), "a URL string was passed where a path was expected")
    }

    /// End to end: locate, then spell. This is the exact pair of calls
    /// `Resolver.buildEngine` makes, over a root with a space in it.
    func testLocatedFolderResolvesToAnExistingDirectoryUnderASpacedRoot() throws {
        let expected = try makeVariant("large-v3")

        let located = try XCTUnwrap(WhisperModelLocator.locateModelFolder(root: root, variant: "large-v3"))
        XCTAssertEqual(located.standardizedFileURL, expected.standardizedFileURL)

        let path = WhisperModelLocator.modelFolderArgument(located)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        // And the folder really is the variant folder, not the .mlmodelc inside it.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: path),
            ["MelSpectrogram.mlmodelc"]
        )
    }

    /// The default root is the one that contains "Application Support" — the
    /// exact ingredient that made the encoding bug bite. Guard that the
    /// default argument still resolves through the decoding spelling.
    func testDefaultModelRootSpellsApplicationSupportUnescaped() {
        let argument = WhisperModelLocator.modelFolderArgument(ModelDownloadManager.defaultModelRoot)
        XCTAssertFalse(argument.contains("%20"), "the default models root is percent-encoded")
        XCTAssertTrue(
            argument.contains("Application Support"),
            "expected an unescaped 'Application Support' in \(argument)"
        )
    }

    // MARK: Locating

    func testMissingVariantReturnsNil() throws {
        try makeVariant("large-v3")
        XCTAssertNil(WhisperModelLocator.locateModelFolder(root: root, variant: "tiny.en"))
    }

    /// A root that does not exist yet (nothing ever downloaded) must be a
    /// clean `nil`, not a crash — this is the first-launch path.
    func testAbsentRootReturnsNil() {
        let absent = root.appendingPathComponent("never-created", isDirectory: true)
        XCTAssertNil(WhisperModelLocator.locateModelFolder(root: absent, variant: "large-v3"))
    }

    /// A folder named for the variant with no compiled model inside it is NOT
    /// a downloaded model — an interrupted download leaves exactly this, and
    /// treating it as present sends WhisperKit at an empty directory.
    func testVariantFolderWithoutACompiledModelIsNotFound() throws {
        let empty = root
            .appendingPathComponent("models/snapshots/abc", isDirectory: true)
            .appendingPathComponent("openai_whisper-large-v3", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("config.json"))

        XCTAssertNil(WhisperModelLocator.locateModelFolder(root: root, variant: "large-v3"))
    }

    /// Exact matching prevents a base variant and its compressed/prefixed
    /// sibling from resolving according to filesystem enumeration order.
    func testDistinctVariantsResolveToTheirOwnFolders() throws {
        let plain = try makeVariant("large-v3")
        let turbo = try makeVariant("large-v3-v20240930_turbo")
        _ = try makeVariant("large-v3-v20240930_turbo_632MB")

        XCTAssertEqual(
            WhisperModelLocator.locateModelFolder(
                root: root,
                variant: "large-v3-v20240930_turbo"
            )?.lastPathComponent,
            turbo.lastPathComponent
        )
        XCTAssertEqual(
            WhisperModelLocator.locateModelFolder(root: root, variant: "large-v3")?.lastPathComponent,
            plain.lastPathComponent
        )
    }
}

final class WhisperModelOptionTests: XCTestCase {
    private var previousSelection: Any?

    override func setUp() {
        super.setUp()
        previousSelection = UserDefaults.standard.object(forKey: SettingsKeys.whisperModel)
        UserDefaults.standard.removeObject(forKey: SettingsKeys.whisperModel)
    }

    override func tearDown() {
        if let previousSelection {
            UserDefaults.standard.set(previousSelection, forKey: SettingsKeys.whisperModel)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKeys.whisperModel)
        }
        super.tearDown()
    }

    func testMultilingualLargeIsTheCanonicalDefault() {
        XCTAssertEqual(WhisperModelOption.defaultsCase, .largeV3Turbo)
        XCTAssertEqual(SettingsKeys.defaultWhisperModel, "large-v3-v20240930_turbo")
        XCTAssertEqual(SettingsKeys.whisperModelName, "large-v3-v20240930_turbo")
        XCTAssertEqual(WhisperModelOption.largeV3Turbo.displayTitle, "Multilingual — Large")
        XCTAssertEqual(WhisperModelOption.largeV3Turbo.approximateSize, "1.64 GB")
    }

    func testLegacyTurboSpellingsParseWithoutRewritingStoredSelection() {
        for legacy in ["large-v3-turbo", "large-v3_turbo"] {
            UserDefaults.standard.set(legacy, forKey: SettingsKeys.whisperModel)

            XCTAssertEqual(WhisperModelOption(named: legacy), .largeV3Turbo)
            XCTAssertEqual(SettingsKeys.whisperModelName, "large-v3-v20240930_turbo")
            XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.whisperModel), legacy)
        }
    }
}
