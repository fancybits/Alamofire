import Foundation

/// `Request` subclass which handles in-memory `Data` download using `URLSessionDataTask`.
public class DataRequest: Request {
    /// `URLRequestConvertible` value used to create `URLRequest`s for this instance.
    public let convertible: URLRequestConvertible
    /// `Data` read from the server so far.
    public var data: Data? { dataMutableState.data }

    private struct DataMutableState {
        var data: Data?
        var httpResponseHandler: (queue: DispatchQueue,
                                  handler: (_ response: HTTPURLResponse,
                                            _ completionHandler: @escaping (ResponseDisposition) -> Void) -> Void)?
    }

    private let dataMutableState = Protected(DataMutableState())

    /// Creates a `DataRequest` using the provided parameters.
    ///
    /// - Parameters:
    ///   - id:                 `UUID` used for the `Hashable` and `Equatable` implementations. `UUID()` by default.
    ///   - convertible:        `URLRequestConvertible` value used to create `URLRequest`s for this instance.
    ///   - underlyingQueue:    `DispatchQueue` on which all internal `Request` work is performed.
    ///   - serializationQueue: `DispatchQueue` on which all serialization work is performed. By default targets
    ///                         `underlyingQueue`, but can be passed another queue from a `Session`.
    ///   - eventMonitor:       `EventMonitor` called for event callbacks from internal `Request` actions.
    ///   - interceptor:        `RequestInterceptor` used throughout the request lifecycle.
    ///   - delegate:           `RequestDelegate` that provides an interface to actions not performed by the `Request`.
    init(id: UUID = UUID(),
         convertible: URLRequestConvertible,
         underlyingQueue: DispatchQueue,
         serializationQueue: DispatchQueue,
         eventMonitor: EventMonitor?,
         interceptor: RequestInterceptor?,
         delegate: RequestDelegate) {
        self.convertible = convertible

        super.init(id: id,
                   underlyingQueue: underlyingQueue,
                   serializationQueue: serializationQueue,
                   eventMonitor: eventMonitor,
                   interceptor: interceptor,
                   delegate: delegate)
    }

    override func reset() {
        super.reset()

        dataMutableState.write { mutableState in
            mutableState.data = nil
        }
    }

    /// Called when `Data` is received by this instance.
    ///
    /// - Note: Also calls `updateDownloadProgress`.
    ///
    /// - Parameter data: The `Data` received.
    func didReceive(data: Data) {
        dataMutableState.write { mutableState in
            if mutableState.data == nil {
                mutableState.data = data
            } else {
                mutableState.data?.append(data)
            }
        }

        updateDownloadProgress()
    }

    func didReceiveResponse(_ response: HTTPURLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        dataMutableState.read { dataMutableState in
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

    override func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        let copiedRequest = request
        return session.dataTask(with: copiedRequest)
    }

    /// Called to update the `downloadProgress` of the instance.
    func updateDownloadProgress() {
        let totalBytesReceived = Int64(data?.count ?? 0)
        let totalBytesExpected = task?.response?.expectedContentLength ?? NSURLSessionTransferSizeUnknown

        downloadProgress.totalUnitCount = totalBytesExpected
        downloadProgress.completedUnitCount = totalBytesReceived

        downloadProgressHandler?.queue.async { self.downloadProgressHandler?.handler(self.downloadProgress) }
    }

    /// Validates the request, using the specified closure.
    ///
    /// - Note: If validation fails, subsequent calls to response handlers will have an associated error.
    ///
    /// - Parameter validation: `Validation` closure used to validate the response.
    ///
    /// - Returns:              The instance.
    @discardableResult
    public func validate(_ validation: @escaping Validation) -> Self {
        let validator: () -> Void = { [unowned self] in
            guard error == nil, let response else { return }

            let result = validation(request, response, data)

            if case let .failure(error) = result { self.error = error.asAFError(or: .responseValidationFailed(reason: .customValidationFailed(error: error))) }

            eventMonitor?.request(self,
                                  didValidateRequest: request,
                                  response: response,
                                  data: data,
                                  withResult: result)
        }

        validators.write { $0.append(validator) }

        return self
    }

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
        dataMutableState.write { mutableState in
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
}
