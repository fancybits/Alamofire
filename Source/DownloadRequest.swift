import Foundation

/// `Request` subclass which downloads `Data` to a file on disk using `URLSessionDownloadTask`.
public final class DownloadRequest: Request {
    /// A set of options to be executed prior to moving a downloaded file from the temporary `URL` to the destination
    /// `URL`.
    public struct Options: OptionSet {
        /// Specifies that intermediate directories for the destination URL should be created.
        public static let createIntermediateDirectories = Options(rawValue: 1 << 0)
        /// Specifies that any previous file at the destination `URL` should be removed.
        public static let removePreviousFile = Options(rawValue: 1 << 1)

        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
    }

    // MARK: Destination

    /// A closure executed once a `DownloadRequest` has successfully completed in order to determine where to move the
    /// temporary file written to during the download process. The closure takes two arguments: the temporary file URL
    /// and the `HTTPURLResponse`, and returns two values: the file URL where the temporary file should be moved and
    /// the options defining how the file should be moved.
    ///
    /// - Note: Downloads from a local `file://` `URL`s do not use the `Destination` closure, as those downloads do not
    ///         return an `HTTPURLResponse`. Instead the file is merely moved within the temporary directory.
    public typealias Destination = (_ temporaryURL: URL,
                                    _ response: HTTPURLResponse) -> (destinationURL: URL, options: Options)

    /// Creates a download file destination closure which uses the default file manager to move the temporary file to a
    /// file URL in the first available directory with the specified search path directory and search path domain mask.
    ///
    /// - Parameters:
    ///   - directory: The search path directory. `.documentDirectory` by default.
    ///   - domain:    The search path domain mask. `.userDomainMask` by default.
    ///   - options:   `DownloadRequest.Options` used when moving the downloaded file to its destination. None by
    ///                default.
    /// - Returns: The `Destination` closure.
    public class func suggestedDownloadDestination(for directory: FileManager.SearchPathDirectory = .documentDirectory,
                                                   in domain: FileManager.SearchPathDomainMask = .userDomainMask,
                                                   options: Options = []) -> Destination {
        { temporaryURL, response in
            let directoryURLs = FileManager.default.urls(for: directory, in: domain)
            let url = directoryURLs.first?.appendingPathComponent(response.suggestedFilename!) ?? temporaryURL

            return (url, options)
        }
    }

    /// Default `Destination` used by Alamofire to ensure all downloads persist. This `Destination` prepends
    /// `Alamofire_` to the automatically generated download name and moves it within the temporary directory. Files
    /// with this destination must be additionally moved if they should survive the system reclamation of temporary
    /// space.
    static let defaultDestination: Destination = { url, _ in
        (defaultDestinationURL(url), [])
    }

    /// Default `URL` creation closure. Creates a `URL` in the temporary directory with `Alamofire_` prepended to the
    /// provided file name.
    static let defaultDestinationURL: (URL) -> URL = { url in
        let filename = "Alamofire_\(url.lastPathComponent)"
        let destination = url.deletingLastPathComponent().appendingPathComponent(filename)

        return destination
    }

    // MARK: Downloadable

    /// Type describing the source used to create the underlying `URLSessionDownloadTask`.
    public enum Downloadable {
        /// Download should be started from the `URLRequest` produced by the associated `URLRequestConvertible` value.
        case request(URLRequestConvertible)
        /// Download should be started from the associated resume `Data` value.
        case resumeData(Data)
    }

    // MARK: Mutable State

    /// Type containing all mutable state for `DownloadRequest` instances.
    private struct DownloadRequestMutableState {
        /// Possible resume `Data` produced when cancelling the instance.
        var resumeData: Data?
        /// `URL` to which `Data` is being downloaded.
        var fileURL: URL?
    }

    /// Protected mutable state specific to `DownloadRequest`.
    private let mutableDownloadState = Protected(DownloadRequestMutableState())

    /// If the download is resumable and is eventually cancelled or fails, this value may be used to resume the download
    /// using the `download(resumingWith data:)` API.
    ///
    /// - Note: For more information about `resumeData`, see [Apple's documentation](https://developer.apple.com/documentation/foundation/urlsessiondownloadtask/1411634-cancel).
    public var resumeData: Data? {
        #if !canImport(FoundationNetworking) // If we not using swift-corelibs-foundation.
        return mutableDownloadState.resumeData ?? error?.downloadResumeData
        #else
        return mutableDownloadState.resumeData
        #endif
    }

    /// If the download is successful, the `URL` where the file was downloaded.
    public var fileURL: URL? { mutableDownloadState.fileURL }

    // MARK: Initial State

    /// `Downloadable` value used for this instance.
    public let downloadable: Downloadable
    /// The `Destination` to which the downloaded file is moved.
    let destination: Destination

    /// Creates a `DownloadRequest` using the provided parameters.
    ///
    /// - Parameters:
    ///   - id:                 `UUID` used for the `Hashable` and `Equatable` implementations. `UUID()` by default.
    ///   - downloadable:       `Downloadable` value used to create `URLSessionDownloadTasks` for the instance.
    ///   - underlyingQueue:    `DispatchQueue` on which all internal `Request` work is performed.
    ///   - serializationQueue: `DispatchQueue` on which all serialization work is performed. By default targets
    ///                         `underlyingQueue`, but can be passed another queue from a `Session`.
    ///   - eventMonitor:       `EventMonitor` called for event callbacks from internal `Request` actions.
    ///   - interceptor:        `RequestInterceptor` used throughout the request lifecycle.
    ///   - delegate:           `RequestDelegate` that provides an interface to actions not performed by the `Request`
    ///   - destination:        `Destination` closure used to move the downloaded file to its final location.
    init(id: UUID = UUID(),
         downloadable: Downloadable,
         underlyingQueue: DispatchQueue,
         serializationQueue: DispatchQueue,
         eventMonitor: EventMonitor?,
         interceptor: RequestInterceptor?,
         delegate: RequestDelegate,
         destination: @escaping Destination) {
        self.downloadable = downloadable
        self.destination = destination

        super.init(id: id,
                   underlyingQueue: underlyingQueue,
                   serializationQueue: serializationQueue,
                   eventMonitor: eventMonitor,
                   interceptor: interceptor,
                   delegate: delegate)
    }

    override func reset() {
        super.reset()

        mutableDownloadState.write {
            $0.resumeData = nil
            $0.fileURL = nil
        }
    }

    /// Called when a download has finished.
    ///
    /// - Parameters:
    ///   - task:   `URLSessionTask` that finished the download.
    ///   - result: `Result` of the automatic move to `destination`.
    func didFinishDownloading(using task: URLSessionTask, with result: Result<URL, AFError>) {
        eventMonitor?.request(self, didFinishDownloadingUsing: task, with: result)

        switch result {
        case let .success(url): mutableDownloadState.fileURL = url
        case let .failure(error): self.error = error
        }
    }

    /// Updates the `downloadProgress` using the provided values.
    ///
    /// - Parameters:
    ///   - bytesWritten:              Total bytes written so far.
    ///   - totalBytesExpectedToWrite: Total bytes expected to write.
    func updateDownloadProgress(bytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        downloadProgress.totalUnitCount = totalBytesExpectedToWrite
        downloadProgress.completedUnitCount += bytesWritten

        downloadProgressHandler?.queue.async { self.downloadProgressHandler?.handler(self.downloadProgress) }
    }

    override func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        session.downloadTask(with: request)
    }

    /// Creates a `URLSessionTask` from the provided resume data.
    ///
    /// - Parameters:
    ///   - data:    `Data` used to resume the download.
    ///   - session: `URLSession` used to create the `URLSessionTask`.
    ///
    /// - Returns:   The `URLSessionTask` created.
    public func task(forResumeData data: Data, using session: URLSession) -> URLSessionTask {
        session.downloadTask(withResumeData: data)
    }

    /// Cancels the instance. Once cancelled, a `DownloadRequest` can no longer be resumed or suspended.
    ///
    /// - Note: This method will NOT produce resume data. If you wish to cancel and produce resume data, use
    ///         `cancel(producingResumeData:)` or `cancel(byProducingResumeData:)`.
    ///
    /// - Returns: The instance.
    @discardableResult
    override public func cancel() -> Self {
        cancel(producingResumeData: false)
    }

    /// Cancels the instance, optionally producing resume data. Once cancelled, a `DownloadRequest` can no longer be
    /// resumed or suspended.
    ///
    /// - Note: If `producingResumeData` is `true`, the `resumeData` property will be populated with any resume data, if
    ///         available.
    ///
    /// - Returns: The instance.
    @discardableResult
    public func cancel(producingResumeData shouldProduceResumeData: Bool) -> Self {
        cancel(optionallyProducingResumeData: shouldProduceResumeData ? { _ in } : nil)
    }

    /// Cancels the instance while producing resume data. Once cancelled, a `DownloadRequest` can no longer be resumed
    /// or suspended.
    ///
    /// - Note: The resume data passed to the completion handler will also be available on the instance's `resumeData`
    ///         property.
    ///
    /// - Parameter completionHandler: The completion handler that is called when the download has been successfully
    ///                                cancelled. It is not guaranteed to be called on a particular queue, so you may
    ///                                want use an appropriate queue to perform your work.
    ///
    /// - Returns:                     The instance.
    @discardableResult
    public func cancel(byProducingResumeData completionHandler: @escaping (_ data: Data?) -> Void) -> Self {
        cancel(optionallyProducingResumeData: completionHandler)
    }

    /// Internal implementation of cancellation that optionally takes a resume data handler. If no handler is passed,
    /// cancellation is performed without producing resume data.
    ///
    /// - Parameter completionHandler: Optional resume data handler.
    ///
    /// - Returns:                     The instance.
    private func cancel(optionallyProducingResumeData completionHandler: ((_ resumeData: Data?) -> Void)?) -> Self {
        mutableState.write { mutableState in
            guard mutableState.state.canTransitionTo(.cancelled) else { return }

            mutableState.state = .cancelled

            underlyingQueue.async { self.didCancel() }

            guard let task = mutableState.tasks.last as? URLSessionDownloadTask, task.state != .completed else {
                underlyingQueue.async { self.finish() }
                return
            }

            if let completionHandler {
                // Resume to ensure metrics are gathered.
                task.resume()
                task.cancel { resumeData in
                    self.mutableDownloadState.resumeData = resumeData
                    self.underlyingQueue.async { self.didCancelTask(task) }
                    completionHandler(resumeData)
                }
            } else {
                // Resume to ensure metrics are gathered.
                task.resume()
                task.cancel()
                self.underlyingQueue.async { self.didCancelTask(task) }
            }
        }

        return self
    }

    /// Validates the request, using the specified closure.
    ///
    /// - Note: If validation fails, subsequent calls to response handlers will have an associated error.
    ///
    /// - Parameter validation: `Validation` closure to validate the response.
    ///
    /// - Returns:              The instance.
    @discardableResult
    public func validate(_ validation: @escaping Validation) -> Self {
        let validator: () -> Void = { [unowned self] in
            guard error == nil, let response else { return }

            let result = validation(request, response, fileURL)

            if case let .failure(error) = result {
                self.error = error.asAFError(or: .responseValidationFailed(reason: .customValidationFailed(error: error)))
            }

            eventMonitor?.request(self,
                                  didValidateRequest: request,
                                  response: response,
                                  fileURL: fileURL,
                                  withResult: result)
        }

        validators.write { $0.append(validator) }

        return self
    }
}
