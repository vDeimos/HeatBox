import Foundation
import Testing
@testable import Engine

@Suite struct LineSplitterTests {
    @Test func splitsOnNewlinesAndCarriageReturns() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("10%\r20%\rdone\nnext".utf8)) == ["10%", "20%", "done"])
        #expect(splitter.flush() == "next")
        #expect(splitter.flush() == nil)
    }

    @Test func aWindowsLineEndingIsOneBreak() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("a\r\nb\r\n\n\n".utf8)) == ["a", "b"])
        #expect(splitter.flush() == nil)
    }

    @Test func aLineSplitAcrossReadsIsJoined() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("hel".utf8)).isEmpty)
        #expect(splitter.append(Data("lo wor".utf8)).isEmpty)
        #expect(splitter.append(Data("ld\nagain".utf8)) == ["hello world"])
        #expect(splitter.append(Data("\n".utf8)) == ["again"])
    }

    @Test func aCharacterSplitAcrossReadsSurvives() {
        let bytes = Array("café ›\n".utf8)
        var splitter = LineSplitter()
        var lines: [String] = []
        for byte in bytes { lines += splitter.append(Data([byte])) }
        #expect(lines == ["café ›"])
    }

    // MARK: A limit on how long a line may be

    @Test func aLineLongerThanTheLimitIsCutAndMarked() {
        var splitter = LineSplitter(maxLineLength: 10)
        #expect(splitter.append(Data("short\n0123456789ABCDEF\nnext\n".utf8)) == ["short", "0123456789…", "next"])
    }

    @Test func aLineThatNeverEndsDoesNotGrowAndIsCutWhenItDoes() {
        var splitter = LineSplitter(maxLineLength: 8)
        for _ in 0..<1000 { #expect(splitter.append(Data(repeating: 0x41, count: 1000)).isEmpty) }
        #expect(splitter.append(Data("\rafter\n".utf8)) == ["AAAAAAAA…", "after"])
        #expect(splitter.flush() == nil)
    }

    @Test func theLimitAppliesAcrossReadsAndToTheUnfinishedLastLine() {
        var splitter = LineSplitter(maxLineLength: 6)
        #expect(splitter.append(Data("abcd".utf8)).isEmpty)
        #expect(splitter.append(Data("efgh".utf8)).isEmpty)
        #expect(splitter.flush() == "abcdef…")
        // A line of exactly the limit is whole.
        #expect(splitter.append(Data("123456\n".utf8)) == ["123456"])
    }

    @Test func withoutALimitALineMayBeAnyLength() {
        var splitter = LineSplitter()
        let long = String(repeating: "x", count: 300_000)
        #expect(splitter.append(Data((long + "\n").utf8)) == [long])
        #expect(splitter.maxLineLength == nil)
    }
}
