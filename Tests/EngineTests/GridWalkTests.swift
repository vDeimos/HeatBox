import Testing
@testable import Engine

@Suite struct GridWalkTests {
    @Test func columnsFitTheWidth() {
        // The Library's tiles: at least 184 wide with 8 between them.
        #expect(GridWalk.columns(width: 183, minimum: 184, spacing: 8) == 1)
        #expect(GridWalk.columns(width: 184, minimum: 184, spacing: 8) == 1)
        #expect(GridWalk.columns(width: 375, minimum: 184, spacing: 8) == 1)
        #expect(GridWalk.columns(width: 376, minimum: 184, spacing: 8) == 2)
        #expect(GridWalk.columns(width: 600, minimum: 184, spacing: 8) == 3)
        #expect(GridWalk.columns(width: 0, minimum: 184, spacing: 8) == 1)
        #expect(GridWalk.columns(width: .infinity, minimum: 184, spacing: 8) == 1)
    }

    @Test func nothingToWalkGivesNothing() {
        #expect(GridWalk.move(from: nil, groups: [], columns: 3, .right) == nil)
        #expect(GridWalk.move(from: 2, groups: [0, 0], columns: 3, .down) == nil)
    }

    @Test func anyArrowPicksTheFirstTileWhenNothingIsSelected() {
        for direction in [GridWalk.Direction.left, .right, .up, .down] {
            #expect(GridWalk.move(from: nil, groups: [5], columns: 3, direction) == 0)
        }
        // A selection that is no longer on the page counts as none.
        #expect(GridWalk.move(from: 9, groups: [5], columns: 3, .left) == 0)
    }

    @Test func leftAndRightRunThroughEveryTileAndStopAtTheEnds() {
        #expect(GridWalk.move(from: 0, groups: [3, 2], columns: 3, .left) == 0)
        #expect(GridWalk.move(from: 2, groups: [3, 2], columns: 3, .right) == 3)
        #expect(GridWalk.move(from: 3, groups: [3, 2], columns: 3, .left) == 2)
        #expect(GridWalk.move(from: 4, groups: [3, 2], columns: 3, .right) == 4)
    }

    @Test func upAndDownKeepTheColumnInsideAGroup() {
        // 0 1 2
        // 3 4 5
        // 6
        #expect(GridWalk.move(from: 1, groups: [7], columns: 3, .down) == 4)
        #expect(GridWalk.move(from: 4, groups: [7], columns: 3, .up) == 1)
        #expect(GridWalk.move(from: 3, groups: [7], columns: 3, .down) == 6)
        #expect(GridWalk.move(from: 1, groups: [7], columns: 3, .up) == 1)
        #expect(GridWalk.move(from: 6, groups: [7], columns: 3, .down) == 6)
    }

    @Test func downOntoAShortLastRowLandsOnItsLastTile() {
        // 0 1 2
        // 3
        #expect(GridWalk.move(from: 2, groups: [4], columns: 3, .down) == 3)
        #expect(GridWalk.move(from: 3, groups: [4], columns: 3, .up) == 0)
    }

    @Test func upAndDownCrossFromOneGroupToTheNext() {
        // 0 1 2      group one (6 tiles)
        // 3 4 5
        // 6 7        group two (2 tiles)
        // 8 9 10     group three (4 tiles)
        // 11
        let groups = [6, 2, 4]
        #expect(GridWalk.move(from: 4, groups: groups, columns: 3, .down) == 7)
        #expect(GridWalk.move(from: 5, groups: groups, columns: 3, .down) == 7)
        #expect(GridWalk.move(from: 7, groups: groups, columns: 3, .up) == 4)
        #expect(GridWalk.move(from: 6, groups: groups, columns: 3, .down) == 8)
        #expect(GridWalk.move(from: 10, groups: groups, columns: 3, .up) == 7)
        #expect(GridWalk.move(from: 8, groups: groups, columns: 3, .down) == 11)
        #expect(GridWalk.move(from: 11, groups: groups, columns: 3, .down) == 11)
    }

    @Test func emptyGroupsAreSteppedOver() {
        #expect(GridWalk.move(from: 1, groups: [2, 0, 2], columns: 2, .down) == 3)
        #expect(GridWalk.move(from: 2, groups: [2, 0, 2], columns: 2, .up) == 0)
    }

    @Test func oneColumnWalksLikeAList() {
        #expect(GridWalk.move(from: 0, groups: [2, 2], columns: 1, .down) == 1)
        #expect(GridWalk.move(from: 1, groups: [2, 2], columns: 1, .down) == 2)
        #expect(GridWalk.move(from: 2, groups: [2, 2], columns: 1, .up) == 1)
        #expect(GridWalk.move(from: 2, groups: [2, 2], columns: 0, .up) == 1)
    }

    @Test func everyMoveStaysOnThePage() {
        let groups = [5, 1, 7, 3]
        let total = groups.reduce(0, +)
        for columns in 1...6 {
            for start in 0..<total {
                for direction in [GridWalk.Direction.left, .right, .up, .down] {
                    let landed = GridWalk.move(from: start, groups: groups, columns: columns, direction)
                    #expect(landed != nil && landed! >= 0 && landed! < total)
                }
            }
        }
    }
}
