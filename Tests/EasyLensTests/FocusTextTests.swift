import XCTest
@testable import EasyLens

final class FocusTextTests: XCTestCase {
    func testEnglishGateSkipsNonEnglishText() {
        XCTAssertNil(eligibleEnglishText("这是中文段落", maxLength: 1200))
        XCTAssertEqual(eligibleEnglishText("Good morning!", maxLength: 1200),
                       "Good morning!")
    }

    func testSelectionSupportsCurrentFocusButNotStaleNearbyText() {
        XCTAssertNotNil(selectedTextAtFocus("before the meeting", anchor: "before",
                                             focusLine: "before the meeting", focusWordIndex: 0))
        XCTAssertNil(selectedTextAtFocus("before the meeting", anchor: "before",
                                          focusLine: "before the calendar", focusWordIndex: 0))
        XCTAssertNil(selectedTextAtFocus("one two", anchor: "Two",
                                          focusLine: "three Two", focusWordIndex: 1))
    }

    func testRelativeTimeTranslation() {
        XCTAssertEqual(relativeTimeChinese("3 hours ago"), "3小时前")
    }

    func testInlinePathDoesNotHideAdjacentProseWords() {
        let line = "tgz, vendor lock or node_modules/openclaw."
        let cleaned = excludingInlinePaths(line)
        XCTAssertTrue(cleaned.contains("vendor lock"))
        XCTAssertFalse(cleaned.contains("node_modules"))
        XCTAssertEqual((cleaned as NSString).length, (line as NSString).length)
        XCTAssertFalse(inlinePathRanges("Renderer KP/EIFAIFX").isEmpty)
        XCTAssertEqual(excludingInlinePaths("package.json"),
                       String(repeating: " ", count: "package.json".count))
    }

    func testMissingLanguagesRequireExplicitPreparation() async {
        await MainActor.run {
            let setup = TranslationLanguageSetup()
            setup.previewMissingLanguages()
            XCTAssertFalse(setup.isReady)
            XCTAssertNil(setup.configuration)
            setup.beginDownload()
            XCTAssertEqual(setup.status, .downloading)
            XCTAssertNotNil(setup.configuration)
        }
    }
}
