// Experimental

import Dispatch
import HTTP

public class HTTPRequestContext {
    // from HTTPRequest
    public let method: HTTPMethod
    public let target: String /* e.g. "/foo/bar?buz=qux" */
    public let httpVersion: HTTPVersion
    public let headers: HTTPHeaders

    // storage for extensions to HTTPRequestContext
    public var context: [String: Any] = [:]

    init(_ request: HTTPRequest) {
        method = request.method
        target = request.target
        httpVersion = request.httpVersion
        headers = request.headers
    }
}

public protocol RouteHandler {
    func process(request: HTTPRequestContext, response: HTTPResponseWriter) -> HTTPBodyProcessing
}

// WebApp example
public struct RoutingWebApp {
    private var handlers: [Path: RouteHandler] = [:]

    public init() {}

    public mutating func add(verb: Verb, path: String, handler: RouteHandler) {
        handlers[Path(path: path, verb: verb)] = handler
    }

    // Given an HTTPRequest, find the route handler
    func getRouteHandler(for request: HTTPRequest) -> RouteHandler? {
        guard let verb = Verb(request.method) else {
            // Unsupported method
            return nil
        }

        // Shortcut for exact match
        let exactPath = Path(path: request.target, verb: verb)

        if let exactMatch = handlers[exactPath] {
            return exactMatch
        }

        // Search map of routes for a matching handler
        for (path, match) in handlers {
            if verb == path.verb,
                let _ = URLParameterParser(path: path.path).parse(request.target) {
                return match
            }
        }

        return nil
    }

    public func handle(request: HTTPRequest, response: HTTPResponseWriter) -> HTTPBodyProcessing {
        guard let handler = getRouteHandler(for: request) else {
            // No response creator found
            // Handle failure
            return serveWithFailureHandler(request: request, response: response)
        }

        return handler.process(request: HTTPRequestContext(request), response: response)
    }

    private func serveWithFailureHandler(request: HTTPRequest, response: HTTPResponseWriter) -> HTTPBodyProcessing {
        response.writeHeader(status: .notFound, headers: [.transferEncoding: "chunked"])
        return .processBody { (chunk, stop) in
            switch chunk {
            case .chunk(_, let finishedProcessing):
                finishedProcessing()
            case .end:
                response.done()
            default:
                stop = true /* don't call us anymore */
                response.abort()
            }
        }
    }
}
