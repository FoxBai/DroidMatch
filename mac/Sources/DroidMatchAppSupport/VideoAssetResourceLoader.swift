import AVFoundation
import DroidMatchCore
import Foundation
import UniformTypeIdentifiers

/// AVFoundation objects are confined to `queue`; only bounded values cross into
/// the async source. Cancelling a seek drops its result but drains the one real
/// range read before admitting another, so cancellation cannot multiply streams.
/// 中文：AVFoundation 对象只在串行 queue 访问；取消 seek 仍等待已准入读取排空。
final class VideoAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.droidmatch.video-resource")
    let resourceURL: URL
    private let source: any MediaPlaybackSource
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var active: ObjectIdentifier?
    private var closed = false
    private static let maximumPendingRequests = 8

    init(source: any MediaPlaybackSource) {
        self.source = source
        resourceURL = URL(string: "droidmatch-video://\(UUID().uuidString)/asset")!
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !closed, request.request.url == resourceURL,
              pending.count < Self.maximumPendingRequests else {
            request.finishLoading(with: Self.failure())
            return true
        }
        if let information = request.contentInformationRequest {
            information.contentType = UTType(mimeType: source.content.mimeType)?.identifier
            information.contentLength = source.content.byteCount
            information.isByteRangeAccessSupported = true
        }
        guard request.dataRequest != nil else {
            request.finishLoading()
            return true
        }
        pending.append(request)
        pump()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel request: AVAssetResourceLoadingRequest
    ) {
        pending.removeAll { $0 === request }
        pump()
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            let requests = pending
            pending.removeAll()
            for request in requests where !request.isCancelled && !request.isFinished {
                request.finishLoading(with: Self.failure())
            }
            Task { await source.close() }
        }
    }

    private func pump() {
        guard !closed, active == nil else { return }
        while let request = pending.first {
            guard !request.isCancelled, !request.isFinished,
                  let data = request.dataRequest else {
                pending.removeFirst()
                continue
            }
            let range: Range<Int64>
            do {
                range = try Self.nextRange(
                    requestedOffset: data.requestedOffset, currentOffset: data.currentOffset,
                    requestedLength: data.requestedLength,
                    toEnd: data.requestsAllDataToEndOfResource, total: source.content.byteCount
                )
            } catch {
                pending.removeFirst()
                request.finishLoading(with: Self.failure())
                continue
            }
            guard !range.isEmpty else {
                pending.removeFirst()
                request.finishLoading()
                continue
            }
            let identity = ObjectIdentifier(request)
            active = identity
            let source = self.source
            Task {
                let result: Result<Data, MediaPlaybackError>
                do {
                    let bytes = try await source.read(
                        offset: range.lowerBound, length: Int(range.count)
                    )
                    result = bytes.count == Int(range.count)
                        ? .success(bytes) : .failure(.unavailable)
                } catch { result = .failure(error as? MediaPlaybackError ?? .unavailable) }
                queue.async { [self] in finish(identity, result: result) }
            }
            return
        }
    }

    private func finish(_ identity: ObjectIdentifier, result: Result<Data, MediaPlaybackError>) {
        guard active == identity else { return }
        active = nil
        guard !closed else { return }
        if let index = pending.firstIndex(where: { ObjectIdentifier($0) == identity }) {
            let request = pending.remove(at: index)
            if !request.isCancelled && !request.isFinished {
                switch result {
                case let .success(bytes):
                    request.dataRequest?.respond(with: bytes)
                    pending.append(request)
                case .failure:
                    request.finishLoading(with: Self.failure())
                }
            }
        }
        pump()
    }

    static func nextRange(
        requestedOffset: Int64, currentOffset: Int64, requestedLength: Int,
        toEnd: Bool, total: Int64
    ) throws -> Range<Int64> {
        guard total > 0, requestedOffset >= 0, requestedOffset <= total,
              requestedLength >= 0, currentOffset >= 0 else {
            throw MediaPlaybackError.invalidRequest
        }
        let start = max(requestedOffset, currentOffset)
        let addition = requestedOffset.addingReportingOverflow(Int64(requestedLength))
        guard toEnd || !addition.overflow else { throw MediaPlaybackError.invalidRequest }
        let end = toEnd ? total : min(total, addition.partialValue)
        guard start <= end else { throw MediaPlaybackError.invalidRequest }
        return start..<(start + min(Int64(MediaPlaybackPolicy.maximumReadBytes), end - start))
    }

    private static func failure() -> NSError {
        NSError(domain: "app.droidmatch.video", code: 1)
    }
}
