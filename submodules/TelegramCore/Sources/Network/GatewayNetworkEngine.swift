import Foundation
import SwiftSignalKit
import MtProtoKit
import GRPC
import NIOCore
import NIOPosix
import GatewaySessionClient

/// Production Gateway endpoint. TLS is mandatory; a localhost exception is
/// intentionally not present in the iOS client.
public struct GatewayEndpoint: Equatable {
    public let host: String
    public let port: Int
    public let apiLayer: Int32

    public init?(bundle: Bundle = .main) {
        guard let configuredHost = bundle.object(forInfoDictionaryKey: "GatewayHost") as? String,
              let host = Self.validHost(configuredHost),
              let port = bundle.object(forInfoDictionaryKey: "GatewayPort") as? Int,
              (1 ... 65535).contains(port) else {
            return nil
        }
        self.host = host
        self.port = port
        self.apiLayer = (bundle.object(forInfoDictionaryKey: "GatewayApiLayer") as? NSNumber)?.int32Value ?? 231
    }

    private static func validHost(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              host.caseInsensitiveCompare("localhost") != .orderedSame,
              host != "127.0.0.1",
              host != "::1" else {
            return nil
        }
        return host
    }
}

/// Selected by the application for Gateway-only builds. It returns an engine
/// even if configuration is missing, so `Network` cannot fall back to a
/// Telegram MTProto transport.
public final class GatewayNetworkEngineFactory: AccountBoundNetworkEngineFactory {
    public init() {
    }

    public var requiresAccountBoundTransport: Bool {
        return true
    }

    public func makeEngine(context: MTContext, isAppExtension: Bool) -> NetworkEngine? {
        return nil
    }

    public func makeEngine(accountId: AccountRecordId, context: MTContext, isAppExtension: Bool) -> NetworkEngine? {
        return GatewayNetworkEngine(context: context, endpoint: GatewayEndpoint(), credentials: GatewayCredentialStore.load(accountId: accountId))
    }
}

private final class GatewayNetworkEngine: NetworkEngine {
    let kind: NetworkEngineKind = .rust

    private let context: MTContext
    private let endpoint: GatewayEndpoint?
    private let credentials: GatewayCredentials?

    init(context: MTContext, endpoint: GatewayEndpoint?, credentials: GatewayCredentials?) {
        self.context = context
        self.endpoint = endpoint
        self.credentials = credentials
    }

    func makeSession(datacenterId: Int, role: NetworkEngineSessionRole, usageCalculationInfo: MTNetworkUsageCalculationInfo?, delegate: NetworkEngineSessionDelegate?) -> NetworkEngineSession {
        return GatewayNetworkSession(context: self.context, datacenterId: datacenterId, endpoint: self.endpoint, credentials: self.credentials, delegate: delegate)
    }
}

private final class GatewayRequestService: NetworkEngineRequestService {
    weak var session: GatewayNetworkSession?

    func add(_ request: NetworkEngineRequest) -> Disposable {
        return self.session?.add(request) ?? EmptyDisposable
    }
}

private final class GatewayNetworkSession: NetworkEngineSession {
    let datacenterId: Int
    let requestService: NetworkEngineRequestService

    private let context: MTContext
    private let endpoint: GatewayEndpoint?
    private let credentials: GatewayCredentials?
    private weak var delegate: NetworkEngineSessionDelegate?
    private let lock = NSLock()
    private var pending: [String: NetworkEngineRequest] = [:]
    private var sinks: [NetworkEngineUpdateSink] = []
    private var paused = true
    private var online = true
    private var stopped = false
    private var reconnectScheduled = false
    private var reconnectAttempts = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var acknowledgedUpdateSequence: Int64 = 0
    private var streamGeneration: Int64 = 0
    private var group: MultiThreadedEventLoopGroup?
    private var channel: GRPCChannel?
    private var call: BidirectionalStreamingCall<Gateway_V1_ClientEnvelope, Gateway_V1_ServerEnvelope>?

    init(context: MTContext, datacenterId: Int, endpoint: GatewayEndpoint?, credentials: GatewayCredentials?, delegate: NetworkEngineSessionDelegate?) {
        self.context = context
        self.datacenterId = datacenterId
        self.endpoint = endpoint
        self.credentials = credentials
        self.delegate = delegate
        let service = GatewayRequestService()
        self.requestService = service
        service.session = self
    }

    deinit {
        self.stop()
    }

    func setPaused(_ paused: Bool) {
        self.lock.lock()
        self.paused = paused
        if paused {
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.reconnectScheduled = false
        }
        let resume = !paused && self.online && !self.stopped && self.isConfigured
        self.lock.unlock()
        if resume {
            self.openAndResumeUpdates()
        }
        self.reportConnection(connected: !paused && self.isConfigured)
    }

    func setOnline(_ online: Bool) {
        self.lock.lock()
        self.online = online
        let resume = online && !self.paused && !self.stopped && self.isConfigured
        self.lock.unlock()
        if resume {
            self.openAndResumeUpdates()
        }
    }

    func addUpdateSink(_ sink: NetworkEngineUpdateSink) {
        self.lock.lock()
        self.sinks.append(sink)
        self.lock.unlock()
    }

    func stop() {
        self.lock.lock()
        guard !self.stopped else {
            self.lock.unlock()
            return
        }
        self.stopped = true
        self.streamGeneration += 1
        self.reconnectWorkItem?.cancel()
        self.reconnectWorkItem = nil
        let requests = Array(self.pending.values)
        self.pending.removeAll()
        let call = self.call
        self.call = nil
        let channel = self.channel
        self.channel = nil
        let group = self.group
        self.group = nil
        self.lock.unlock()
        call?.cancel(promise: nil)
        if let group, let channel {
            channel.close(promise: group.next().makePromise(of: Void.self))
        }
        try? group?.syncShutdownGracefully()
        for request in requests {
            self.complete(request, error: "GATEWAY_UNAVAILABLE")
        }
        self.reportConnection(connected: false)
    }

    func movePendingRequests(to service: NetworkEngineRequestService, completion: @escaping () -> Void) {
        self.lock.lock()
        let requests = Array(self.pending.values)
        self.pending.removeAll()
        self.lock.unlock()
        for request in requests {
            let disposable = service.add(request)
            if self.stopped {
                disposable.dispose()
            }
        }
        completion()
    }

    func add(_ request: NetworkEngineRequest) -> Disposable {
        let requestId = UUID().uuidString
        self.lock.lock()
        let unavailable = self.stopped || self.paused || !self.isConfigured || !self.openLocked()
        if !unavailable {
            self.pending[requestId] = request
        }
        let call = self.call
        self.lock.unlock()
        guard !unavailable, var envelope = self.envelope(requestId: requestId, targetDatacenterId: Int32(self.datacenterId)) else {
            self.complete(request, error: "GATEWAY_UNAVAILABLE")
            return EmptyDisposable
        }
        envelope.tlPayload = request.payload
        request.acknowledged?()
        call?.sendMessage(envelope, promise: nil)
        return ActionDisposable { [weak self] in
            self?.lock.lock()
            self?.pending.removeValue(forKey: requestId)
            self?.lock.unlock()
        }
    }

    private var isConfigured: Bool {
        return self.endpoint != nil && self.credentials != nil
    }

    private func openLocked() -> Bool {
        if self.call != nil {
            return true
        }
        guard let endpoint = self.endpoint else {
            return false
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            self.streamGeneration += 1
            let generation = self.streamGeneration
            let channel = try GRPCChannelPool.with(target: .host(endpoint.host, port: endpoint.port), transportSecurity: .tls(.makeClientConfigurationBackedByNIOSSL()), eventLoopGroup: group)
            let client = GRPCAnyServiceClient(channel: channel)
            self.group = group
            self.channel = channel
            self.call = client.makeBidirectionalStreamingCall(path: "/gateway.v1.GatewaySession/Connect", requestType: Gateway_V1_ClientEnvelope.self, responseType: Gateway_V1_ServerEnvelope.self, handler: { [weak self] response in
                self?.receive(response, generation: generation)
            })
            self.call?.status.whenComplete { [weak self] _ in
                self?.streamClosed(generation: generation)
            }
            self.reportConnection(connected: true)
            return true
        } catch {
            try? group.syncShutdownGracefully()
            return false
        }
    }

    private func envelope(requestId: String, targetDatacenterId: Int32 = 0) -> Gateway_V1_ClientEnvelope? {
        guard let endpoint = self.endpoint, let credentials = self.credentials else {
            return nil
        }
        var envelope = Gateway_V1_ClientEnvelope()
        envelope.requestID = requestId
        envelope.accountID = credentials.accountId
        envelope.deviceToken = credentials.deviceToken
        envelope.apiLayer = endpoint.apiLayer
        envelope.targetDcID = targetDatacenterId
        return envelope
    }

    private func receive(_ response: Gateway_V1_ServerEnvelope, generation: Int64) {
        self.lock.lock()
        guard !self.stopped, generation == self.streamGeneration else {
            self.lock.unlock()
            return
        }
        self.reconnectAttempts = 0
        let request = self.pending.removeValue(forKey: response.requestID)
        let sinks = self.sinks
        self.lock.unlock()
        if case .updates? = response.payload {
            if response.updates.recoveryRequired {
                for sink in sinks {
                    sink.networkSessionDidReset()
                }
            } else if !response.updates.tlPayload.isEmpty, let message = self.context.serialization.parseMessage(response.updates.tlPayload) {
                for sink in sinks {
                    sink.networkSessionDidReceive(message: message)
                }
                self.lock.lock()
                self.acknowledgedUpdateSequence = max(self.acknowledgedUpdateSequence, response.updates.sequence)
                self.lock.unlock()
                self.acknowledgeUpdates(response.updates.sequence)
            }
            return
        }
        guard let request else {
            return
        }
        if case .error? = response.payload {
            self.complete(request, error: response.error.code)
        } else if response.tlResponse.isEmpty {
            self.complete(request, error: "GATEWAY_INVALID_RESPONSE")
        } else if let parsed = request.parse(response.tlResponse) {
            request.completed(.success(NetworkEngineResponse(result: parsed, info: self.responseInfo(response))))
        } else {
            self.complete(request, error: "TL_PARSING_ERROR")
        }
    }

    private func streamClosed(generation: Int64) {
        self.lock.lock()
        guard !self.stopped, generation == self.streamGeneration else {
            self.lock.unlock()
            return
        }
        let requests = Array(self.pending.values)
        self.pending.removeAll()
        self.call = nil
        let channel = self.channel
        self.channel = nil
        let group = self.group
        self.group = nil
        self.lock.unlock()
        if let group, let channel {
            channel.close(promise: group.next().makePromise(of: Void.self))
        }
        group?.shutdownGracefully { _ in }
        for request in requests {
            self.complete(request, error: "GATEWAY_UNAVAILABLE")
        }
        self.reportConnection(connected: false)
        self.scheduleReconnect()
    }

    // Reconnects only the authenticated updates stream. Pending requests have
    // already received a retryable failure above: replaying mutations from the
    // client could duplicate a user action if Gateway itself restarted.
    private func scheduleReconnect() {
        self.lock.lock()
        guard !self.stopped, !self.paused, self.online, self.isConfigured, !self.reconnectScheduled else {
            self.lock.unlock()
            return
        }
        self.reconnectScheduled = true
        let delay = min(32.0, pow(2.0, Double(self.reconnectAttempts)))
        self.reconnectAttempts += 1
        let work = DispatchWorkItem { [weak self] in
            self?.openAndResumeUpdates()
        }
        self.reconnectWorkItem = work
        self.lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func openAndResumeUpdates() {
        self.lock.lock()
        self.reconnectScheduled = false
        self.reconnectWorkItem = nil
        guard !self.stopped, !self.paused, self.online, self.isConfigured else {
            self.lock.unlock()
            return
        }
        let opened = self.openLocked()
        let sequence = self.acknowledgedUpdateSequence
        self.lock.unlock()
        if opened {
            self.acknowledgeUpdates(sequence)
        } else {
            self.scheduleReconnect()
        }
    }

    private func complete(_ request: NetworkEngineRequest, error: String) {
        request.completed(.failure(NetworkEngineRequestFailure(error: MTRpcError(errorCode: 500, errorDescription: error), info: NetworkEngineResponseInfo(timestamp: 0, networkType: 0, duration: 0))))
    }

    private func responseInfo(_ response: Gateway_V1_ServerEnvelope) -> NetworkEngineResponseInfo {
        return NetworkEngineResponseInfo(timestamp: Double(response.serverTimeUnixMs) / 1000.0, networkType: 0, duration: 0)
    }

    private func acknowledgeUpdates(_ sequence: Int64) {
        guard sequence >= 0, var envelope = self.envelope(requestId: UUID().uuidString) else {
            return
        }
        var acknowledgement = Gateway_V1_AckUpdates()
        acknowledgement.sequence = sequence
        envelope.control = .ackUpdates(acknowledgement)
        self.lock.lock()
        let call = self.call
        self.lock.unlock()
        call?.sendMessage(envelope, promise: nil)
    }

    private func reportConnection(connected: Bool) {
        self.delegate?.networkSessionConnectionStateChanged(NetworkEngineConnectionState(isNetworkAvailable: self.isConfigured, isConnected: connected, isUpdatingConnectionContext: false, isPerformingServiceTasks: false, proxyAddress: nil, proxyHasConnectionIssues: !connected && self.isConfigured))
    }
}
