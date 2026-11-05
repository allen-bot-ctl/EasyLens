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

    func testFormatSelectionTranslationPreservesMultipleParagraphs() {
        let input = "第一段内容。\n\n第二段内容。\n\n\n第三段内容。"
        let formatted = formatSelectionTranslation(input)
        XCTAssertEqual(formatted, "第一段内容。\n第二段内容。\n第三段内容。")
    }

    func testNormalizeSourceSelectionParagraphsSplitsChromiumInlineBullets() {
        let raw = "What you can expect from us, which describes how we provide and develop our services• What we expect from you, which establishes certain rules for using our services• Content in Google services, which describes the intellectual property rights to the content you find in our services — whether that content belongs to you, Google, or others• In case of problems or disagreements, which describes other legal rights you have, and what to expect in case someone violates these terms"
        let eligible = eligibleEnglishText(raw, maxLength: 1200)
        let lines = eligible?.components(separatedBy: "\n") ?? []
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "• What you can expect from us, which describes how we provide and develop our services")
        XCTAssertEqual(lines[1], "• What we expect from you, which establishes certain rules for using our services")
    }

    func testMatchSelectionInBlocksReconstructsPlainParagraphsAndLists() {
        let blocks = [
            "Understanding these terms is important because you’re agreeing to these terms.",
            "Besides these terms, we also publish a Privacy Policy.",
            "We encourage you to read it carefully."
        ]
        let flatRaw = blocks.joined()
        let reconstructed = matchSelectionInBlocks(raw: flatRaw, blocks: blocks)
        XCTAssertEqual(reconstructed, blocks.joined(separator: "\n"))
    }

    func testMatchSelectionInBlocksProjectsBoundariesWhenInlineWidgetDiffers() {
        let blocks = [
            "What’s covered in these terms",
            "We know it’s tempting to skip these Terms of Service, but it’s important to establish what you can expect from us as you use Google services?, and what we expect from you.",
            "These Terms of Service reflect the way Google’s business works."
        ]
        let raw = "What’s covered in these termsWe know it’s tempting to skip these Terms of Service, but it’s important to establish what you can expect from us as you use Google services, and what we expect from you.These Terms of Service reflect the way Google’s business works."
        let reconstructed = matchSelectionInBlocks(raw: raw, blocks: blocks)
        let lines = reconstructed?.components(separatedBy: "\n") ?? []
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "What’s covered in these terms")
        XCTAssertTrue(lines[1].hasPrefix("We know it’s tempting to skip"))
        XCTAssertEqual(lines[2], "These Terms of Service reflect the way Google’s business works.")
    }

    func testNormalizeSourceSelectionParagraphsSplitsHeadingAndPunctuatedParagraphSeams() {
        let raw = "What’s covered in these termsWe know it’s tempting to skip these Terms of Service, but it’s important to establish what you can expect from us as you use Google services, and what we expect from you.These Terms of Service reflect the way Google’s business works, the laws that apply to our company, and certain things we’ve always believed to be true. As a result, these Terms of Service help define Google’s relationship with you as you interact with our services. For example, these terms include the following topic headings:• What you can expect from us, which describes how we provide and develop our services• What we expect from you, which establishes certain rules for using our services"
        let normalized = normalizeSourceSelectionParagraphs(raw)
        let lines = normalized.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[0], "What’s covered in these terms")
        XCTAssertEqual(lines[1], "We know it’s tempting to skip these Terms of Service, but it’s important to establish what you can expect from us as you use Google services, and what we expect from you.")
        XCTAssertTrue(lines[2].hasPrefix("These Terms of Service reflect the way"))
        XCTAssertTrue(lines[2].hasSuffix("following topic headings:"))
        XCTAssertTrue(lines[3].hasPrefix("• What you can expect from us"))
        XCTAssertTrue(lines[4].hasPrefix("• What we expect from you"))
    }

    func testNormalizeSourceSelectionParagraphsPreservesBrandNamesInProse() {
        let prose = "You can use GitHub, JavaScript, DeepSeek, YouTube, iPhone, and macOS in your daily workflow."
        XCTAssertEqual(normalizeSourceSelectionParagraphs(prose), prose)
    }

    func testEligibleEnglishTextAllowsMultiParagraphProseWithSlashesAndLongLength() {
        let paragraph = "We know it’s tempting to skip these Terms of Service, and/or to overlook how country/region rules apply when you visit https://policies.google.com/terms or read our documentation."
        let longSelection = Array(repeating: paragraph, count: 10).joined(separator: "\n")
        XCTAssertGreaterThan(longSelection.count, 1200)
        XCTAssertNotNil(eligibleEnglishText(longSelection, maxLength: 4000))
    }

    func testFormatSelectionTranslationRestoresMiddleDotDelimitedList() {
        for dot in ["・", "·", "•"] {
            let input = [
                "您可以在期待我们做什么，其中说明了我们如何提供和发展我们的服务",
                "我们期待您做什么，其中确立了使用我们服务的某些规则",
                "Google 服务中的内容，其中描述了您在我们服务中找到的内容的知识产权——无论该内容属于您、Google 还是他人",
                "如果出现问题或分歧，其中描述了您拥有的其他法律权利，以及如果有人违反这些条款会发生什么"
            ].joined(separator: dot)
            let source = "• What you can expect from us...\n• What we expect from you...\n• Content in Google services...\n• In case of problems..."
            let formatted = formatSelectionTranslation(input, source: source)
            let lines = formatted.components(separatedBy: "\n")
            XCTAssertEqual(lines.count, 4, "Failed for dot \(dot)")
            XCTAssertTrue(lines[0].hasPrefix("• 您可以在期待我们做什么"))
            XCTAssertTrue(lines[1].hasPrefix("• 我们期待您做什么"))
            XCTAssertTrue(lines[2].hasPrefix("• Google 服务中的内容"))
            XCTAssertTrue(lines[3].hasPrefix("• 如果出现问题或分歧"))
        }
    }

    func testFormatSelectionTranslationPreservesForeignNamesWithMiddleDot() {
        for name in ["莱昂纳多・达・芬奇", "莱昂纳多·达·芬奇"] {
            let formatted = formatSelectionTranslation(name, source: "Leonardo da Vinci")
            XCTAssertEqual(formatted, name)
        }
    }

    func testFormatSelectionTranslationStripsOuterQuotesAndMarkdownHeaders() {
        let input = "\"### 条款标题\n第一项说明 • 第二项说明\""
        let formatted = formatSelectionTranslation(input)
        let lines = formatted.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "条款标题")
        XCTAssertEqual(lines[1], "第一项说明")
        XCTAssertEqual(lines[2], "• 第二项说明")
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
