import Foundation
import Testing
@testable import Engine

@Suite struct ExtraArgsPolicyTests {
    @Test func wordsAreSplitLikeAShell() {
        #expect(ExtraArgsPolicy.tokenize(#"--match-filter "duration < 600" --geo-bypass 'a b' c\ d"#)
                == ["--match-filter", "duration < 600", "--geo-bypass", "a b", "c d"])
        #expect(ExtraArgsPolicy.tokenize("") == [])
        #expect(ExtraArgsPolicy.tokenize("   \n ") == [])
        #expect(ExtraArgsPolicy.tokenize("a   b\tc\nd") == ["a", "b", "c", "d"])
        #expect(ExtraArgsPolicy.tokenize(#""""#) == [""])
        #expect(ExtraArgsPolicy.tokenize(#"'it'\''s'"#) == ["it's"])
        #expect(ExtraArgsPolicy.tokenize(#""a\"b""#) == ["a\"b"])
        #expect(ExtraArgsPolicy.tokenize(#"'a\b'"#) == [#"a\b"#])
    }

    @Test func anUnfinishedQuoteOrEscapeIsRefused() {
        #expect(ExtraArgsPolicy.tokenize("\"open") == nil)
        #expect(ExtraArgsPolicy.tokenize("'open") == nil)
        #expect(ExtraArgsPolicy.tokenize("end\\") == nil)
        #expect(ExtraArgsPolicy.check("\"open").problems == [.unfinished])
    }

    @Test func ordinaryOptionsAreAllowed() {
        let verdict = ExtraArgsPolicy.check("--geo-bypass --match-filter 'duration < 3600' -N 8 --no-playlist --sleep-requests 1")
        #expect(verdict.isAllowed)
        #expect(verdict.arguments.count == 8)
    }

    @Test(arguments: [
        "--geo-bypass", "--no-playlist", "--yes-playlist", "--force-ipv4", "--no-check-certificates", "--no-part", "--no-mtime",
        "--limit-rate 2M", "-r 2M", "-N 8", "-N8", "-R 3", "-f bestaudio", "-S res:720",
        "--format=best", "--sleep-interval 2", "--max-sleep-interval 9", "--playlist-items 1-3",
        "--match-filters 'duration < 600'", "--age-limit 12", "--proxy socks5://127.0.0.1:1080",
        "--sponsorblock-mark all", "--sub-langs en.*", "--remove-chapters 'intro'", "-I 1,3",
    ])
    func legitimateOptionsStillWork(option: String) {
        #expect(ExtraArgsPolicy.check(option).isAllowed, "\(option)")
    }

    @Test(arguments: [
        // Programs and downloaders
        "--exec echo", "--exec-before-download echo", "--use-postprocessor X", "--netrc-cmd echo",
        "--downloader /bin/sh", "--external-downloader /bin/sh", "--downloader-args ffmpeg:-y",
        "--external-downloader-args x", "--postprocessor-args ffmpeg:-y", "--ppa x",
        "--plugin-dirs /tmp", "--remote-components ejs:github", "--js-runtimes node",
        "--ffmpeg-location /tmp/x",
        // Configuration
        "--config-locations /tmp/x", "--config-location /tmp/x", "--compat-options all",
        // Files read or written
        "--batch-file /tmp/x", "-a /tmp/x", "--cookies /tmp/x", "--cookies-from-browser chrome",
        "--download-archive /tmp/x", "--print-to-file title /tmp/x", "--load-info-json /tmp/x",
        "--write-info-json", "--write-link", "--write-description", "--cache-dir /tmp/x",
        "--netrc", "-n", "--video-password x", "-u me", "-p x",
        // Where files go
        "-o x", "-P /tmp", "--paths /tmp", "--output x", "--parse-metadata x", "--replace-in-metadata a b c",
        "--trim-filenames 5", "--output-na-placeholder /tmp/", "--print title",
        // Requests to other addresses, and the tools
        "--sponsorblock-api https://example.com", "--update", "-U", "--update-to x",
        "--alias x --exec y", "-t mp3", "--preset-alias mp3",
        // Links
        "--", "-- https://example.com/other", "https://example.com/other",
        // A value that is not an option, after an option that takes none
        "--no-playlist=yes",
    ])
    func refusedOptionsAreRefused(extra: String) {
        #expect(!ExtraArgsPolicy.check(extra).isAllowed, "\(extra)")
    }

    @Test func theAliasWayAroundTheCheckIsRefused() {
        // yt-dlp's `--alias` gave a refused option a new name; the name is not on the list, so it is refused.
        let verdict = ExtraArgsPolicy.check("--alias batch --batch-file /tmp/x")
        #expect(verdict.problems.contains(.refused(option: "--alias", reason: .notAllowed)))
    }

    @Test func abbreviationsAreRefusedBecauseNamesMustMatchExactly() {
        for abbreviation in ["--exe", "--exec-b", "--batch", "--plugin", "--config-loc", "--ffmpeg", "--js-r", "--upd", "--cook", "--out"] {
            #expect(!ExtraArgsPolicy.check(abbreviation).isAllowed, "\(abbreviation)")
        }
    }

    @Test func caseChangesAreRefused() {
        #expect(!ExtraArgsPolicy.check("--EXEC echo").isAllowed)
        #expect(!ExtraArgsPolicy.check("-O title").isAllowed)
    }

    @Test func clumpedShortOptionsAreRefused() {
        // `-ik` and `-ia` would hide a refused letter behind an allowed one.
        for token in ["-ia", "-ik", "-qa", "-xa", "-ia /tmp/x", "-kq"] {
            #expect(!ExtraArgsPolicy.check(token).isAllowed, "\(token)")
        }
        // A value attached to a value option is that value, as yt-dlp reads it: `-N8` is 8 fragments.
        #expect(ExtraArgsPolicy.check("-N8").isAllowed)
    }

    @Test func aValueOptionTakesTheNextWordWhateverItLooksLike() {
        // The value is not an option, so `--exec` here is a format string, not a program.
        #expect(ExtraArgsPolicy.check("--format --exec").isAllowed)
    }

    @Test func aMissingValueIsRefused() {
        #expect(ExtraArgsPolicy.check("--limit-rate").problems == [.refused(option: "--limit-rate", reason: .missingValue)])
        #expect(ExtraArgsPolicy.check("-N").problems == [.refused(option: "-N", reason: .missingValue)])
    }

    @Test func aBareWordIsRefusedSoLinksCannotBeSmuggledIn() {
        let verdict = ExtraArgsPolicy.check("--geo-bypass https://example.com/other")
        #expect(verdict.problems == [.refused(option: "https://example.com/other", reason: .notAnOption)])
    }

    @Test func aBareDoubleDashIsRefused() {
        let verdict = ExtraArgsPolicy.check("--geo-bypass -- https://example.com/other")
        #expect(verdict.problems.contains(.refused(option: "--", reason: .endsOptions)))
    }

    @Test func eachProblemIsReported() {
        let problems = ExtraArgsPolicy.check("--exec x -a f --update").problems
        #expect(problems.contains(.refused(option: "--exec", reason: .notAllowed)))
        #expect(problems.contains(.refused(option: "-a", reason: .notAllowed)))
        #expect(problems.contains(.refused(option: "--update", reason: .notAllowed)))
    }

    @Test func everyRefusalHasAnExplanation() {
        for reason in [ExtraArgsPolicy.Reason.notAllowed, .notAnOption, .missingValue, .endsOptions] {
            let sentence = Messages.recipeExtraArguments(.refused(option: "--x", reason: reason))
            #expect(sentence.contains("--x") && sentence.hasSuffix("."), "\(reason)")
        }
    }
}

@Suite struct NameTemplateEscapeTests {
    private func recipe(_ template: String) -> DownloadRecipe {
        var recipe = DownloadRecipe()
        recipe.filenameTemplate = .custom
        recipe.customTemplate = template
        return recipe
    }

    @Test func aTemplateThatLeavesTheFolderIsRefused() {
        // yt-dlp expands `~` and `$VAR` in an output template, so both could reach a folder outside the download.
        for template in ["~/zz/%(title)s.%(ext)s", "$HOME/zz/%(title)s.%(ext)s", "a/$HOME/%(title)s.%(ext)s",
                         "../../x/%(title)s.%(ext)s", "a/../../%(title)s.%(ext)s", "/tmp/%(title)s.%(ext)s"] {
            let errors = RecipeValidator.errors(in: recipe(template))
            #expect(errors.contains { $0.field == "customTemplate" }, "\(template)")
        }
    }

    @Test func aTemplateInsideTheFolderIsAllowed() {
        for template in ["%(title)s [%(id)s].%(ext)s", "Music/%(artist)s/%(title)s.%(ext)s", "a..b/%(title)s.%(ext)s", "%(title)s.%(ext)s"] {
            let errors = RecipeValidator.errors(in: recipe(template))
            #expect(!errors.contains { $0.field == "customTemplate" }, "\(template)")
        }
    }
}

@Suite struct ImportedPresetExtraArgumentTests {
    private func presets(_ extra: String) -> PresetExchange.Imported? {
        let json = #"{"presets":[{"name":"Shared","recipe":{"extraArguments":"\#(extra)"}}]}"#
        return PresetExchange.read(Data(json.utf8))
    }

    @Test func aPresetWithARefusedOptionIsRefusedWhole() throws {
        for extra in ["--downloader /bin/sh", "--alias a --batch-file /tmp/x", "-o ~/x/%(title)s.%(ext)s", "--exec echo", "https://example.com/other"] {
            let imported = try #require(presets(extra), "\(extra)")
            #expect(imported.presets.isEmpty, "\(extra)")
            #expect(imported.refused.count == 1, "\(extra)")
        }
    }

    @Test func aPresetWithAllowedOptionsComesOver() throws {
        let imported = try #require(presets("--geo-bypass -N 4"))
        #expect(imported.presets.count == 1)
        #expect(imported.presets.first?.recipe.extraArguments == "--geo-bypass -N 4")
    }
}
