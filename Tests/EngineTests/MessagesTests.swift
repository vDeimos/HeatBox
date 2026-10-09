import Testing
@testable import Engine

// Ported from Phobos's self-check ("Messages", retry wording, sign-in).
// Phobos pointed people at a `phobos-login` terminal command and a
// "Settings > Tools > Update now" button that did not exist; the new wording
// names only things the app has.

@Suite struct MessagesTests {
    @Test func privateVideoIsExplained() {
        let result = ErrorTranslator.translate("ERROR: [youtube] abc: Private video")
        #expect(result.kind == .privateVideo)
        #expect(result.message.contains("private"))
    }

    @Test func outOfDateToolIsExplained() {
        let result = ErrorTranslator.translate("ERROR: Unable to extract player")
        #expect(result.kind == .toolOutOfDate)
        #expect(result.message.contains("Settings > Tools"))
    }

    @Test func unknownMessagesPassThrough() {
        let result = ErrorTranslator.translate("ERROR: something odd")
        #expect(result.kind == .unknown)
        #expect(result.message == "something odd")
        #expect(ErrorTranslator.friendly("ERROR: something odd") == "something odd")
    }

    @Test func membersOnlyIsExplainedWithTheNextStep() {
        let result = ErrorTranslator.translate("ERROR: [youtube] abc: Join this channel to get access to members-only content")
        #expect(result.kind == .membersOnly)
        #expect(result.message.contains("Copy my sign-in"))
    }

    @Test func anExpiredSignInIsExplained() {
        let result = ErrorTranslator.translate("ERROR: The provided YouTube account cookies are no longer valid")
        #expect(result.kind == .signInExpired)
        #expect(result.message.contains("Copy my sign-in"))
    }

    @Test func anUnviewablePlaylistIsExplained() {
        let result = ErrorTranslator.translate("ERROR: [youtube:tab] RDabc: YouTube said: This playlist type is unviewable")
        #expect(result.kind == .unviewablePlaylist)
        #expect(result.message.contains("kind of playlist"))
    }

    @Test(arguments: [
        ("ERROR: This video is DRM protected", ErrorKind.protected),
        ("ERROR: [youtube] zzzzzzzzzzz: This video is unavailable", ErrorKind.unavailable),
        ("ERROR: [youtube] abc: This live event will begin in 30 hours.", ErrorKind.upcoming),
        ("ERROR: [youtube] abc: Premieres in 3 days", ErrorKind.upcoming),
        ("ERROR: Sign in to confirm you're not a bot", .signInRequired),
        ("ERROR: Sign in to confirm your age", .signInRequired),
        ("ERROR: The uploader has not made this video available in your country", .regionBlocked),
        ("ERROR: [youtube] abc: Video unavailable", .unavailable),
        ("ERROR: HTTP Error 429: Too Many Requests", .rateLimited),
        ("ERROR: Unsupported URL: https://example.com", .unsupportedSite),
        ("ERROR: [Errno 28] No space left on device", .diskFull),
        ("ERROR: Requested format is not available", .toolOutOfDate),
        ("ERROR: Unable to download webpage: <urlopen error timed out>", .unreachable),
    ])
    func eachKnownFailureHasAKind(raw: String, kind: ErrorKind) {
        let result = ErrorTranslator.translate(raw)
        #expect(result.kind == kind)
        #expect(!result.message.contains("ERROR"))
        #expect(result.message.hasSuffix("."))
    }

    @Test func noSentenceMentionsTheOldAppsOrMissingControls() {
        let sentences = [
            Messages.noTool, Messages.noConverter, Messages.live, Messages.pausedBecauseClosed,
            Messages.signInBlocked, Messages.signInNotFound, Messages.signInExpired, Messages.membersOnly,
            Messages.signInRequired, Messages.toolOutOfDate,
        ]
        for sentence in sentences {
            #expect(!sentence.contains("Phobos ") || sentence.contains(Engine.productName))
            #expect(!sentence.contains("phobos-login"))
            #expect(!sentence.contains("Update now"))
            #expect(!sentence.contains("brewup"))
        }
        #expect(Messages.live.contains(Engine.productName))
    }

    @Test func theRetryWaitIsSaidPlainly() {
        #expect(Messages.retrying(inSeconds: 15, retry: 1, of: 3) == "The connection dropped. Trying again in 15 seconds (retry 1 of 3).")
        #expect(Messages.retrying(inSeconds: 60, retry: 2, of: 3).contains("1 minute ("))
        #expect(Messages.retrying(inSeconds: 180, retry: 3, of: 3).contains("3 minutes"))
    }

    @Test func aBlockedBrowserIsExplained() {
        #expect(Messages.signInFailure("could not find firefox cookies database").contains("Full Disk Access"))
        #expect(Messages.signInFailure("something else") == Messages.signInNotFound)
    }
}
