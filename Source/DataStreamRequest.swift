import Foundation

/// `Request` subclass which streams HTTP response `Data` through a `Handler` closure.
public final class DataStreamRequest: Request {
    /// Closure type handling `DataStreamRequest.Stream` values.
    public typealias Handler<Success, Failure: Error> = (Stream<Success, Failure>) throws -> Void

    /// Type encapsulating an `Event` as it flows through the stream, as well as a `CancellationToken` which can be used
    /// to stop the stream at any time.
    public struct Stream<Success, Failure: Error> {
        /// Latest `Event` from the stream.
        public let event: Event<Success, Failure>
        /// Token used to cancel the stream.
        public let token: CancellationToken

        /// Cancel the ongoing stream by canceling the underlying `DataStreamRequest`.
        public func cancel() {
            token.cancel()
        }
    }

    /// Type representing an event flowing through the stream. Contains either the `Result` of processing streamed
    /// `Data` or the completion of the stream.
    public enum Event<Success, Failure: Error> {
        /// Output produced every time the instance receives additional `Data`. The associated value contains the
        /// `Result` of processing the incoming `Data`.
        case stream(Result<Success, Failure>)
        /// Output produced when the instance has completed, whether due to stream end, cancellation, or an error.
        /// Associated `Completion` value contains the final state.
        case complete(Completion)
    }

    /// Value containing the state of a `DataStreamRequest` when the stream was completed.
    public struct Completion {
        /// Last `URLRequest` issued by the instance.
        public let request: URLRequest?
        /// Last `HTTPURLResponse` received by the instance.
        public let response: HTTPURLResponse?
        /// Last `URLSessionTaskMetrics` produced for the instance.
        public let metrics: URLSessionTaskMetrics?
        /// `AFError` produced for the instance, if any.
        public let error: AFError?
    }

    /// Type used to cancel an ongoing stream.
    public struct CancellationToken {
        weak var request: DataStreamRequest?

        init(_ request: DataStreamRequest) {
            self.request = request
        }

        /// Cancel the ongoing stream by canceling the underlying `DataStreamRequest`.
        public func cancel() {
            request?.cancel()
        }
    }

    /// `URLRequestConvertible` value used to create `URLRequest`s for this instance.
    public let convertible: URLRequestConvertible
    /// Whether or not the instance will be cancelled if stream parsing encounters an error.
    public let automaticallyCancelOnStreamError: Bool

    /// Internal mutable state specific to this type.
    struct StreamMutableState {
        /// `OutputStream` bound to the `InputStream` produced by `asInputStream`, if it has been called.
        var outputStream: OutputStream?
        /// Stream closures called as `Data` is received.
        var streams: [(_ data: Data) -> Void] = []
        /// Number of currently executing streams. Used to ensure completions are only fired after all streams are
        /// enqueued.
        var numberOfExecutingStreams = 0
        /// Completion calls enqueued while streams are still executing.
        var enqueuedCompletionEvents: [() -> Void] = []
        /// Handler for any `HTTPURLResponse`s received.
        var httpResponseHandler: (queue: DispatchQueue,
                                  handler: (_ response: HTTPURLResponse,
                                            _ completionHandler: @escaping (ResponseDisposition) -> Void) -> Void)?
    }

    let streamMutableState = Protected(StreamMutableState())

    /// Creates a `DataStreamRequest` using the provided parameters.
    ///
    /// - Parameters:
    ///   - id:                               `UUID` used for the `Hashable` and `Equatable` implementations. `UUID()`
    ///                                        by default.
    ///   - convertible:                      `URLRequestConvertible` value used to create `URLRequest`s for this
    ///                                        instance.
    ///   - automaticallyCancelOnStreamError: `Bool` indicating whether the instance will be cancelled when an `Error`
    ///                                       is thrown while serializing stream `Data`.
    ///   - underlyingQueue:                  `DispatchQueue` on which all internal `Request` work is performed.
    ///   - serializationQueue:               `DispatchQueue` on which all serialization work is performed. By default
    ///                                       targets
    ///                                       `underlyingQueue`, but can be passed another queue from a `Session`.
    ///   - eventMonitor:                     `EventMonitor` called for event callbacks from internal `Request` actions.
    ///   - interceptor:                      `RequestInterceptor` used throughout the request lifecycle.
    ///   - delegate:                         `RequestDelegate` that provides an interface to actions not performed by
    ///                                       the `Request`.
    init(id: UUID = UUID(),
         convertible: URLRequestConvertible,
         automaticallyCancelOnStreamError: Bool,
         underlyingQueue: DispatchQueue,
         serializationQueue: DispatchQueue,
         eventMonitor: EventMonitor?,
         interceptor: RequestInterceptor?,
         delegate: RequestDelegate) {
        self.convertible = convertible
        self.automaticallyCancelOnStreamError = automaticallyCancelOnStreamError

        super.init(id: id,
                   underlyingQueue: underlyingQueue,
                   serializationQueue: serializationQueue,
                   eventMonitor: eventMonitor,
                   interceptor: interceptor,
                   delegate: delegate)
    }

    override func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        let copiedRequest = request
        return session.dataTask(with: copiedRequest)
    }

    override func finish(error: AFError? = nil) {
        streamMutableState.write { state in
            state.outputStream?.close()
        }

        super.finish(error: error)
    }

    func didReceive(data: Data) {
        streamMutableState.write { state in
            #if !canImport(FoundationNetworking) // If we not using swift-corelibs-foundation.
            if let stream = state.outputStream {
                underlyingQueue.async {
                    var bytes = Array(data)
                    stream.write(&bytes, maxLength: bytes.count)
                }
            }
            #endif
            state.numberOfExecutingStreams += state.streams.count
            let localState = state
            underlyingQueue.async { localState.streams.forEach { $0(data) } }
        }
    }

    func didReceiveResponse(_ response: HTTPURLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        streamMutableState.read { dataMutableState in
            guard let httpResponseHandler = dataMutableState.httpResponseHandler else {
                underlyingQueue.async { completionHandler(.allow) }
                return
            }

            httpResponseHandler.queue.async {
                httpResponseHandler.handler(response) { disposition in
                    if disposition == .cancel {
                        self.mutableState.write { mutableState in
                            mutableState.state = .cancelled
                            mutableState.error = mutableState.error ?? AFError.explicitlyCancelled
                        }
                    }

                    self.underlyingQueue.async {
                        completionHandler(disposition.sessionDisposition)
                    }
                }
            }
        }
    }

    /// Validates the `URLRequest` and `HTTPURLResponse` received for the instance using the provided `Validation` closure.
    ///
    /// - Parameter validation: `Validation` closure used to validate the request and response.
    ///
    /// - Returns:              The `DataStreamRequest`.
    @discardableResult
    public func validate(_ validation: @escaping Validation) -> Self {
        let validator: () -> Void = { [unowned self] in
            guard error == nil, let response else { return }

            let result = validation(request, response)

            if case let .failure(error) = result {
                self.error = error.asAFError(or: .responseValidationFailed(reason: .customValidationFailed(error: error)))
            }

            eventMonitor?.request(self,
                                  didValidateRequest: request,
                                  response: response,
                                  withResult: result)
        }

        validators.write { $0.append(validator) }

        return self
    }

    #if !canImport(FoundationNetworking) // If we not using swift-corelibs-foundation.
    /// Produces an `InputStream` that receives the `Data` received by the instance.
    ///
    /// - Note: The `InputStream` produced by this method must have `open()` called before being able to read `Data`.
    ///         Additionally, this method will automatically call `resume()` on the instance, regardless of whether or
    ///         not the creating session has `startRequestsImmediately` set to `true`.
    ///
    /// - Parameter bufferSize: Size, in bytes, of the buffer between the `OutputStream` and `InputStream`.
    ///
    /// - Returns:              The `InputStream` bound to the internal `OutboundStream`.
    public func asInputStream(bufferSize: Int = 1024) -> InputStream? {
        defer { resume() }

        var inputStream: InputStream?
        streamMutableState.write { state in
            Foundation.Stream.getBoundStreams(withBufferSize: bufferSize,
                                              inputStream: &inputStream,
                                              outputStream: &state.outputStream)
            state.outputStream?.open()
        }

        return inputStream
    }
    #endif

    /// Sets a closure called whenever the `DataRequest` produces an `HTTPURLResponse` and providing a completion
    /// handler to return a `ResponseDisposition` value.
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which the closure will be called. `.main` by default.
    ///   - handler: Closure called when the instance produces an `HTTPURLResponse`. The `completionHandler` provided
    ///              MUST be called, otherwise the request will never complete.
    ///
    /// - Returns:   The instance.
    @_disfavoredOverload
    @discardableResult
    public func onHTTPResponse(
        on queue: DispatchQueue = .main,
        perform handler: @escaping (_ response: HTTPURLResponse,
                                    _ completionHandler: @escaping (ResponseDisposition) -> Void) -> Void
    ) -> Self {
        streamMutableState.write { mutableState in
            mutableState.httpResponseHandler = (queue, handler)
        }

        return self
    }

    /// Sets a closure called whenever the `DataRequest` produces an `HTTPURLResponse`.
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which the closure will be called. `.main` by default.
    ///   - handler: Closure called when the instance produces an `HTTPURLResponse`.
    ///
    /// - Returns:   The instance.
    @discardableResult
    public func onHTTPResponse(on queue: DispatchQueue = .main,
                               perform handler: @escaping (HTTPURLResponse) -> Void) -> Self {
        onHTTPResponse(on: queue) { response, completionHandler in
            handler(response)
            completionHandler(.allow)
        }

        return self
    }

    func capturingError(from closure: () throws -> Void) {
        do {
            try closure()
        } catch {
            self.error = error.asAFError(or: .responseSerializationFailed(reason: .customSerializationFailed(error: error)))
            cancel()
        }
    }

    func appendStreamCompletion<Success, Failure>(on queue: DispatchQueue,
                                                  stream: @escaping Handler<Success, Failure>) {
        appendResponseSerializer {
            self.underlyingQueue.async {
                self.responseSerializerDidComplete {
                    self.streamMutableState.write { state in
                        guard state.numberOfExecutingStreams == 0 else {
                            state.enqueuedCompletionEvents.append {
                                self.enqueueCompletion(on: queue, stream: stream)
                            }

                            return
                        }

                        self.enqueueCompletion(on: queue, stream: stream)
                    }
                }
            }
        }
    }

    func enqueueCompletion<Success, Failure>(on queue: DispatchQueue,
                                             stream: @escaping Handler<Success, Failure>) {
        queue.async {
            do {
                let completion = Completion(request: self.request,
                                            response: self.response,
                                            metrics: self.metrics,
                                            error: self.error)
                try stream(.init(event: .complete(completion), token: .init(self)))
            } catch {
                // Ignore error, as errors on Completion can't be handled anyway.
            }
        }
    }
}

extension DataStreamRequest.Stream {
    /// Incoming `Result` values from `Event.stream`.
    public var result: Result<Success, Failure>? {
        guard case let .stream(result) = event else { return nil }

        return result
    }

    /// `Success` value of the instance, if any.
    public var value: Success? {
        guard case let .success(value) = result else { return nil }

        return value
    }

    /// `Failure` value of the instance, if any.
    public var error: Failure? {
        guard case let .failure(error) = result else { return nil }

        return error
    }

    /// `Completion` value of the instance, if any.
    public var completion: DataStreamRequest.Completion? {
        guard case let .complete(completion) = event else { return nil }

        return completion
    }
}
