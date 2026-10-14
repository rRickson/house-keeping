import Foundation
import Testing
@testable import SweepMetrics

@Suite struct RingBufferTests {
    @Test func keepsElementsInOrderWhileFilling() {
        var buffer = RingBuffer<Int>(capacity: 4)
        #expect(buffer.isEmpty)
        #expect(buffer.first == nil)
        #expect(buffer.last == nil)
        buffer.append(1)
        buffer.append(2)
        #expect(buffer.elements == [1, 2])
        #expect(buffer.count == 2)
        #expect(!buffer.isFull)
        #expect(buffer.first == 1)
        #expect(buffer.last == 2)
    }

    @Test func dropsTheOldestOnceFull() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...7 { buffer.append(value) }
        #expect(buffer.elements == [5, 6, 7])
        #expect(buffer.count == 3)
        #expect(buffer.isFull)
        #expect(buffer.first == 5)
        #expect(buffer.last == 7)
        #expect(buffer.totalAppended == 7)
    }

    @Test func staysCorrectAtEveryFillLevel() {
        var buffer = RingBuffer<Int>(capacity: 5)
        for value in 0..<23 {
            buffer.append(value)
            let expected = Array(max(0, value - 4)...value)
            #expect(buffer.elements == expected)
            #expect(buffer.first == expected.first)
            #expect(buffer.last == expected.last)
        }
    }

    @Test func removeAllEmptiesItAndItFillsAgain() {
        var buffer = RingBuffer<Int>(capacity: 2)
        for value in 1...5 { buffer.append(value) }
        buffer.removeAll()
        #expect(buffer.isEmpty)
        #expect(buffer.elements == [])
        buffer.append(9)
        #expect(buffer.elements == [9])
    }

    @Test func aCapacityBelowOneBecomesOne() {
        var buffer = RingBuffer<Int>(capacity: 0)
        buffer.append(1)
        buffer.append(2)
        #expect(buffer.capacity == 1)
        #expect(buffer.elements == [2])
    }
}

@Suite struct MetricsHistoryTests {
    @Test func sixtySecondsAtOneSecondIsSixtySamples() {
        #expect(MetricsHistory().capacity == 60)
        #expect(MetricsHistory(window: 60, interval: 0.5).capacity == 120)
        #expect(MetricsHistory(window: 60, interval: 2).capacity == 30)
    }

    @Test func keepsOnlyTheLastWindow() {
        var history = MetricsHistory(capacity: 60)
        for second in 0..<100 {
            history.append(snapshot(at: Double(second), cpu: Double(second) / 100))
        }
        let points = history.points(.cpu)
        #expect(points.count == 60)
        #expect(points.first?.index == 40)
        #expect(points.last?.index == 99)
        #expect(points.last?.value == 0.99)
        #expect(history.indexRange == 40...99)
        #expect(history.latest(.cpu) == 0.99)
    }

    @Test func theWindowIsFullWidthBeforeItFills() {
        var history = MetricsHistory(capacity: 60)
        #expect(history.isEmpty)
        #expect(history.indexRange == 0...59)
        history.append(snapshot(at: 0, cpu: 0.5))
        #expect(!history.isEmpty)
        #expect(history.indexRange == 0...59)
        #expect(history.points(.cpu) == [MetricPoint(index: 0, value: 0.5)])
    }

    @Test func aMetricThatWasNotCollectedLeavesAGap() {
        var history = MetricsHistory(capacity: 10)
        history.append(snapshot(at: 0, gpu: 0.1))
        history.append(snapshot(at: 1))             // no GPU reading in this sample
        history.append(snapshot(at: 2, gpu: 0.3))
        #expect(history.points(.gpu).map(\.index) == [0, 2])
        #expect(history.values(.gpu) == [0.1, 0.3])
        #expect(history.points(.cpu).map(\.index) == [0, 1, 2])
        #expect(history.points(.diskRead).isEmpty)
    }

    @Test func pointsOlderThanTheWindowAreHiddenEvenIfTheirSeriesStopped() {
        var history = MetricsHistory(capacity: 5)
        history.append(snapshot(at: 0, gpu: 0.9))
        for second in 1..<8 { history.append(snapshot(at: Double(second))) }
        #expect(history.points(.gpu).isEmpty)
    }

    @Test func aPauseStartsTheHistoryOver() {
        var history = MetricsHistory(capacity: 60, gapThreshold: 5)
        for second in 0..<10 { history.append(snapshot(at: Double(second), cpu: 0.9)) }
        history.append(snapshot(at: 600, cpu: 0.1))
        #expect(history.values(.cpu) == [0.1])
        // Numbering carries on, so the new point never reuses an old identity.
        #expect(history.points(.cpu).first?.index == 10)
    }

    @Test func ordinaryJitterDoesNotResetIt() {
        var history = MetricsHistory(capacity: 60, gapThreshold: 5)
        history.append(snapshot(at: 0))
        history.append(snapshot(at: 1.4))
        history.append(snapshot(at: 4.9))
        #expect(history.points(.cpu).count == 3)
    }

    @Test func keepsAHistoryPerCore() {
        var history = MetricsHistory(capacity: 3)
        for second in 0..<5 {
            history.append(snapshot(at: Double(second), perCore: [Double(second), Double(second) * 10]))
        }
        #expect(history.coreCount == 2)
        #expect(history.corePoints(0).map(\.value) == [2, 3, 4])
        #expect(history.corePoints(1).map(\.value) == [20, 30, 40])
        #expect(history.corePoints(7).isEmpty)
    }

    @Test func recordsRatesAndTheirPeak() {
        var history = MetricsHistory(capacity: 10)
        history.append(snapshot(at: 0, disk: DiskSample(readBytesPerSecond: 100, writeBytesPerSecond: 900)))
        history.append(snapshot(at: 1, disk: DiskSample(readBytesPerSecond: 400, writeBytesPerSecond: 50)))
        #expect(history.values(.diskRead) == [100, 400])
        #expect(history.values(.diskWrite) == [900, 50])
        #expect(history.peak(.diskRead) == 400)
        #expect(history.peak(.diskRead, .diskWrite) == 900)
        #expect(history.values(.load) == [1.5, 1.5])
    }

    @Test func valuesThatAreNotNumbersAreSkipped() {
        var history = MetricsHistory(capacity: 10)
        history.append(snapshot(at: 0, cpu: .nan))
        history.append(snapshot(at: 1, cpu: 0.2))
        #expect(history.values(.cpu) == [0.2])
    }
}
