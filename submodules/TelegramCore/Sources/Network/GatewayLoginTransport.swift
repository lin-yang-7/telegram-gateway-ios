import Foundation
import SwiftSignalKit
import GRPC
import NIOPosix
import GatewaySessionClient

public struct GatewayLoginResult: Equatable {
    public let challengeId: String
    public let codeLength: Int32
    public let passwordRequired: Bool
    public let authorized: Bool
    public let accountId: String
    public let deviceToken: String
    public let telegramUserId: Int64
    public let displayName: String

    init(_ value: Gateway_V1_LoginResult) {
        self.challengeId = value.challengeID
        self.codeLength = value.codeLength
        self.passwordRequired = value.passwordRequired
        self.authorized = value.authorized
        self.accountId = value.accountID
        self.deviceToken = value.deviceToken
        self.telegramUserId = value.telegramUserID
        self.displayName = value.displayName
    }
}

public enum GatewayLoginError: Error {
    case unavailable
    case rejected
}

/// Narrow anonymous login control plane. It deliberately never exposes a
/// Telegram auth key or sends credentials in a TL payload.
public enum GatewayLoginTransport {
    public static func requestCode(phoneE164: String, deviceId: String) -> Signal<GatewayLoginResult, GatewayLoginError> {
        var login = Gateway_V1_LoginRequest()
        var request = Gateway_V1_RequestLoginCode()
        request.phoneE164 = phoneE164
        request.deviceID = deviceId
        login.action = .requestCode(request)
        return send(login)
    }

    public static func submitCode(challengeId: String, code: String) -> Signal<GatewayLoginResult, GatewayLoginError> {
        var login = Gateway_V1_LoginRequest()
        var request = Gateway_V1_SubmitLoginCode()
        request.challengeID = challengeId
        request.code = code
        login.action = .submitCode(request)
        return send(login)
    }

    public static func submitPassword(challengeId: String, password: String) -> Signal<GatewayLoginResult, GatewayLoginError> {
        var login = Gateway_V1_LoginRequest()
        var request = Gateway_V1_SubmitLoginPassword()
        request.challengeID = challengeId
        request.password = password
        login.action = .submitPassword(request)
        return send(login)
    }

    private static func send(_ login: Gateway_V1_LoginRequest) -> Signal<GatewayLoginResult, GatewayLoginError> {
        return Signal { subscriber in
            guard let endpoint = GatewayEndpoint() else {
                subscriber.putError(.unavailable)
                return EmptyDisposable
            }
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let lock = NSLock()
            var finished = false
            var channel: GRPCChannel?
            var call: BidirectionalStreamingCall<Gateway_V1_ClientEnvelope, Gateway_V1_ServerEnvelope>?
            func finish(_ result: Result<GatewayLoginResult, GatewayLoginError>) {
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                finished = true
                let activeCall = call
                let activeChannel = channel
                lock.unlock()
                activeCall?.cancel(promise: nil)
                activeChannel?.close(promise: group.next().makePromise(of: Void.self))
                group.shutdownGracefully { _ in }
                switch result {
                case let .success(value):
                    subscriber.putNext(value)
                    subscriber.putCompletion()
                case let .failure(error):
                    subscriber.putError(error)
                }
            }
            do {
                let opened = try GRPCChannelPool.with(target: .host(endpoint.host, port: endpoint.port), transportSecurity: .tls(.makeClientConfigurationBackedByNIOSSL()), eventLoopGroup: group)
                channel = opened
                let client = GRPCAnyServiceClient(channel: opened)
                call = client.makeBidirectionalStreamingCall(path: "/gateway.v1.GatewaySession/Connect", requestType: Gateway_V1_ClientEnvelope.self, responseType: Gateway_V1_ServerEnvelope.self, handler: { response in
                    if case .login? = response.payload {
                        finish(.success(GatewayLoginResult(response.login)))
                    } else {
                        finish(.failure(.rejected))
                    }
                })
                var envelope = Gateway_V1_ClientEnvelope()
                envelope.requestID = UUID().uuidString
                envelope.apiLayer = endpoint.apiLayer
                envelope.control = .login(login)
                call?.sendMessage(envelope, promise: nil)
            } catch {
                finish(.failure(.unavailable))
            }
            return ActionDisposable {
                finish(.failure(.unavailable))
            }
        }
    }
}
