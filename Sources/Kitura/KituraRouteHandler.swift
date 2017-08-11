// Experimental

import Dispatch
import HTTP

public protocol ProcessingDelegate {
    func process(request: HTTPRequestContext, response: HTTPResponseWriter)
}

let bufferedBodyKey = "@@Kitura@@bufferedBody"
let bufferBodyKey = "@@Kitura@@bufferBody"
let bodyHandlersKey = "@@Kitura@@bodyHandlers"

extension HTTPRequestContext {
    // default fields provided by Kitura
    public internal(set) var bufferedBody: DispatchData? {
        get {
            return context[bufferedBodyKey] as? DispatchData
        }
        set {
            context[bufferedBodyKey] = newValue
        }
    }

    var bufferBody: Bool {
        get {
            return context[bufferBodyKey] as? Bool ?? false
        }
        set {
            context[bufferBodyKey] = newValue
        }
    }

    // TODO
    // Change to a different type than HTTPBodyHandler closure?
    var bodyHandlers: [HTTPBodyHandler] {
        get {
            return context[bodyHandlersKey] as? [HTTPBodyHandler] ?? []
        }
        set {
            context[bodyHandlersKey] = newValue
        }
    }

    public func enableBodyBuffer() {
        bufferBody = true
    }

    public func addBodyHandler(_ handler: @escaping HTTPBodyHandler) {
        bodyHandlers.append(handler)
    }
}

public struct KituraRouteHandler: RouteHandler {
    var processors: [ProcessingDelegate]

    init(processors: [ProcessingDelegate] = []) {
        self.processors = processors
    }

    mutating func add(processors: ProcessingDelegate...) {
        self.processors.append(contentsOf: processors)
    }

    public func process(request: HTTPRequestContext, response: HTTPResponseWriter) -> HTTPBodyProcessing {
        return KituraRouteHandler.processWalker(request: request, response: response, with: processors[processors.startIndex...])
    }

    private static func processWalker(request: HTTPRequestContext, response: HTTPResponseWriter, with processors: ArraySlice<ProcessingDelegate>) -> HTTPBodyProcessing {
        // n = 0 case: no more processors left
        // check request context for body handlers
        guard let processor = processors.first else {
            if request.bodyHandlers.isEmpty {
                return .discardBody
            }
            else {
                return .processBody() { chunk, stop in
                    // TODO
                    // Make sure setting the stop does not
                    for handler in request.bodyHandlers {
                        handler(chunk, &stop)
                    }
                }
            }
        }

        // n >= 1 case
        let nextProcessors = processors[(processors.startIndex + 1)...]

        // run next processor
        processor.process(request: request, response: response)

        // inspect request context for need to buffer body
        if request.bufferedBody == nil && request.bufferBody {
            // need to buffer body
            request.bufferedBody = DispatchData.empty

            return .processBody() { chunk, stop in
                switch chunk {
                case .chunk(let data, let finishedProcessing):
                    // buffer the body chunks
                    if (data.count > 0) {
                        request.bufferedBody?.append(data)
                    }

                    finishedProcessing()
                default:
                    stop = true
                }

                // if there are any body handlers already, run those as well
                for handler in request.bodyHandlers {
                    handler(chunk, &stop)
                }
            }
        }
        else {
            // no need to do anything else
            // continue to execute processors in list
            return KituraRouteHandler.processWalker(request: request, response: response, with: nextProcessors)
        }
    }
}
