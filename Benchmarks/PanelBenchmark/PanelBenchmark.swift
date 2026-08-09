import CoreGraphics
import Darwin
import Foundation
import IndicateAppleDisplay

private enum BenchmarkError: Error, CustomStringConvertible {
    case missingCorpusArgument
    case cannotReadCorpus(path: String, source: any Error)
    case invalidCorpus(path: String, source: any Error)
    case missingScene(String)
    case frameFailed(panel: String, reason: DisplayReason)
    case frameTimeBudget(panel: String, scale: Int, rate: Int, measuredMs: Double)
    case allocationBudget(panel: String, scale: Int, allocations: UInt64)
    case heapGrowthBudget(panel: String, scale: Int, bytes: UInt64, blocks: UInt64)
    case schedulingBudget(panel: String, scale: Int, rate: Int)

    var description: String {
        switch self {
        case .missingCorpusArgument:
            "Use --corpus <path>."
        case let .cannotReadCorpus(path, source):
            "Cannot read the corpus at \(path): \(source)"
        case let .invalidCorpus(path, source):
            "Cannot decode the corpus at \(path): \(source)"
        case let .missingScene(name):
            "The corpus does not contain \(name)."
        case let .frameFailed(panel, reason):
            "The \(panel) benchmark frame failed with \(reason.label)."
        case let .frameTimeBudget(panel, scale, rate, measuredMs):
            "The \(panel) \(scale)x \(rate) Hz p95 time is \(measuredMs) ms."
        case let .allocationBudget(panel, scale, allocations):
            "The \(panel) \(scale)x run allocated \(allocations) pixel buffers."
        case let .heapGrowthBudget(panel, scale, bytes, blocks):
            "The \(panel) \(scale)x run retained \(bytes) bytes in \(blocks) blocks."
        case let .schedulingBudget(panel, scale, rate):
            "The \(panel) \(scale)x \(rate) Hz worker did not complete each scheduled frame."
        }
    }
}

private struct Corpus: Decodable {
    struct Entry: Decodable {
        let name: String
        let bytesHex: String?
    }

    let entries: [Entry]

    func scene(named name: String) throws -> [UInt8] {
        guard let hex = entries.first(where: { $0.name == name })?.bytesHex else {
            throw BenchmarkError.missingScene(name)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex, hex.index(after: index) < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return bytes
    }
}

private struct PanelCase {
    let name: String
    let corpusName: String
    let criticalLayers: Set<SceneLayer>
}

private struct Record {
    let panel: String
    let scale: Int
    let rate: Int
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
    let pixelBufferAllocations: UInt64
    let heapGrowthBytes: UInt64
    let heapGrowthBlocks: UInt64
    let submitted: UInt64
    let completed: UInt64
    let coalesced: UInt64
    let staleCompletions: UInt64
}

private struct Timing {
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
    let pixelBufferAllocations: UInt64
    let pixelBufferCapacity: Int
    let heapGrowthBytes: UInt64
    let heapGrowthBlocks: UInt64
}

private struct HeapSample {
    let bytes: UInt64
    let blocks: UInt64
}

private final class FixedProducer: SceneProducing {
    let bytes: [UInt8]

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    func frame(designFrame _: CGRect) throws -> SceneFrame {
        SceneFrame(bytes: bytes, generation: 1)
    }
}

private let designSize = CGSize(width: 480, height: 360)
private let frameTimeBudgetMs = 8.0
private let heapGrowthBudgetBytes: UInt64 = 256 * 1_024
private let measuredFrames = 50
private let warmupFrames = 6
private let scheduledFrames = 12

private func corpusPath() throws -> String {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2, arguments[0] == "--corpus" else {
        throw BenchmarkError.missingCorpusArgument
    }
    return arguments[1]
}

private func loadCorpus(path: String) throws -> Corpus {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw BenchmarkError.cannotReadCorpus(path: path, source: error)
    }
    do {
        return try JSONDecoder().decode(Corpus.self, from: data)
    } catch {
        throw BenchmarkError.invalidCorpus(path: path, source: error)
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func heapSample() -> HeapSample {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return HeapSample(
        bytes: UInt64(statistics.size_in_use),
        blocks: UInt64(statistics.blocks_in_use)
    )
}

private func growth(from start: UInt64, to end: UInt64) -> UInt64 {
    end > start ? end - start : 0
}

private func schedule(
    display: PanelDisplay,
    width: Int,
    height: Int,
    rate: Int
) async throws -> PanelRenderWorkerSnapshot {
    let worker = PanelRenderWorker(display: display)
    let (stream, continuation) = AsyncStream.makeStream(of: PanelFrameOutcome.self)
    let interval = Duration.nanoseconds(1_000_000_000 / Int64(rate))

    for frame in 0..<scheduledFrames {
        worker.submit(
            pixelWidth: width,
            pixelHeight: height,
            nowMs: Double(frame) * 1_000 / Double(rate)
        ) { outcome in
            if frame == scheduledFrames - 1 {
                continuation.yield(outcome)
                continuation.finish()
            }
        }
        if frame < scheduledFrames - 1 {
            try await ContinuousClock().sleep(for: interval)
        }
    }

    var iterator = stream.makeAsyncIterator()
    guard let outcome = await iterator.next() else {
        throw BenchmarkError.frameFailed(panel: display.requirements.title, reason: .renderTrap)
    }
    guard !outcome.showingFailure else {
        throw BenchmarkError.frameFailed(
            panel: display.requirements.title,
            reason: outcome.reason
        )
    }
    return worker.snapshot
}

private func timeFrames(
    display: PanelDisplay,
    panel: String,
    width: Int,
    height: Int
) throws -> Timing {
    var lastOutcome: PanelFrameOutcome?
    for frame in 0..<warmupFrames {
        lastOutcome = autoreleasepool {
            display.renderBlocking(
                pixelWidth: width,
                pixelHeight: height,
                nowMs: Double(frame)
            )
        }
    }
    guard let warmOutcome = lastOutcome, !warmOutcome.showingFailure else {
        throw BenchmarkError.frameFailed(
            panel: panel,
            reason: lastOutcome?.reason ?? .renderTrap
        )
    }

    var samples: [Double] = []
    samples.reserveCapacity(measuredFrames)
    let heapBefore = heapSample()
    for frame in 0..<measuredFrames {
        let start = ContinuousClock.now
        let outcome = autoreleasepool {
            display.renderBlocking(
                pixelWidth: width,
                pixelHeight: height,
                nowMs: Double(frame + warmupFrames)
            )
        }
        samples.append(milliseconds(start.duration(to: .now)))
        lastOutcome = outcome
        guard !outcome.showingFailure else {
            throw BenchmarkError.frameFailed(panel: panel, reason: outcome.reason)
        }
    }
    let heapAfter = heapSample()

    samples.sort()
    let percentileIndex = Int((Double(samples.count) * 0.95).rounded(.up)) - 1
    return Timing(
        p95Milliseconds: samples[percentileIndex],
        maximumMilliseconds: samples.last ?? 0,
        pixelBufferAllocations: lastOutcome?.pixelBuffers.allocations ?? 0,
        pixelBufferCapacity: lastOutcome?.pixelBuffers.capacity ?? 0,
        heapGrowthBytes: growth(from: heapBefore.bytes, to: heapAfter.bytes),
        heapGrowthBlocks: growth(from: heapBefore.blocks, to: heapAfter.blocks)
    )
}

private func validate(
    timing: Timing,
    worker: PanelRenderWorkerSnapshot,
    panel: String,
    scale: Int,
    rate: Int
) throws {
    guard timing.p95Milliseconds <= frameTimeBudgetMs else {
        throw BenchmarkError.frameTimeBudget(
            panel: panel,
            scale: scale,
            rate: rate,
            measuredMs: timing.p95Milliseconds
        )
    }
    guard timing.pixelBufferAllocations <= UInt64(timing.pixelBufferCapacity) else {
        throw BenchmarkError.allocationBudget(
            panel: panel,
            scale: scale,
            allocations: timing.pixelBufferAllocations
        )
    }
    guard timing.heapGrowthBytes <= heapGrowthBudgetBytes else {
        throw BenchmarkError.heapGrowthBudget(
            panel: panel,
            scale: scale,
            bytes: timing.heapGrowthBytes,
            blocks: timing.heapGrowthBlocks
        )
    }
    let counters = worker.counters
    guard counters.submitted == scheduledFrames,
          counters.completed == scheduledFrames,
          counters.coalesced == 0,
          counters.staleCompletions == 0,
          counters.deliveryTasksScheduled == scheduledFrames else {
        throw BenchmarkError.schedulingBudget(panel: panel, scale: scale, rate: rate)
    }
}

private func measure(
    panel: PanelCase,
    bytes: [UInt8],
    scale: Int,
    rate: Int
) async throws -> Record {
    let requirements = PanelRequirements(
        id: panel.name.lowercased(),
        title: panel.name,
        criticalLayers: panel.criticalLayers,
        frameMin: designSize,
        frameMax: designSize,
        canonicalFrame: designSize,
        preferredFramesPerSecond: rate
    )
    let display = PanelDisplay(
        requirements: requirements,
        producer: FixedProducer(bytes: bytes)
    )
    let width = Int(designSize.width) * scale
    let height = Int(designSize.height) * scale
    let timing = try timeFrames(
        display: display,
        panel: panel.name,
        width: width,
        height: height
    )
    let worker = try await schedule(
        display: display,
        width: width,
        height: height,
        rate: rate
    )
    try validate(timing: timing, worker: worker, panel: panel.name, scale: scale, rate: rate)
    return Record(
        panel: panel.name,
        scale: scale,
        rate: rate,
        p95Milliseconds: timing.p95Milliseconds,
        maximumMilliseconds: timing.maximumMilliseconds,
        pixelBufferAllocations: timing.pixelBufferAllocations,
        heapGrowthBytes: timing.heapGrowthBytes,
        heapGrowthBlocks: timing.heapGrowthBlocks,
        submitted: worker.counters.submitted,
        completed: worker.counters.completed,
        coalesced: worker.counters.coalesced,
        staleCompletions: worker.counters.staleCompletions
    )
}

@main
private enum PanelBenchmark {
    static func main() async throws {
        let path = try corpusPath()
        let corpus = try loadCorpus(path: path)
        let panels = [
            PanelCase(
                name: "PFD",
                corpusName: "multi-layer-pfd",
                criticalLayers: [.attitude, .tapes, .annunciation]
            ),
            PanelCase(
                name: "HSI",
                corpusName: "guidance-cdi",
                criticalLayers: [.guidance]
            ),
        ]

        print(
            "panel,scale,target_hz,p95_ms,maximum_ms,pixel_buffer_allocations,"
                + "heap_growth_bytes,heap_growth_blocks,"
                + "submitted,completed,coalesced,stale_completions"
        )
        for panel in panels {
            let bytes = try corpus.scene(named: panel.corpusName)
            for scale in [1, 2] {
                for rate in [60, 120] {
                    let record = try await measure(
                        panel: panel,
                        bytes: bytes,
                        scale: scale,
                        rate: rate
                    )
                    print(
                        "\(record.panel),\(record.scale),\(record.rate),"
                            + String(
                                format: "%.3f,%.3f,%llu,%llu,%llu,%llu,%llu,%llu,%llu",
                                record.p95Milliseconds,
                                record.maximumMilliseconds,
                                record.pixelBufferAllocations,
                                record.heapGrowthBytes,
                                record.heapGrowthBlocks,
                                record.submitted,
                                record.completed,
                                record.coalesced,
                                record.staleCompletions
                            )
                    )
                }
            }
        }
    }
}
