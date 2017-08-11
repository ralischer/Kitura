# Problem Statement

For Kitura-Next, we want to support these features/capabilities:

1. Non-callback-based middleware processing
2. Type-safe request parsing

Additionally, these are tentative/nice-to-have features:

1. Subrouting, or route-specific middleware chaining
2. Middleware reuse

All the while maintaining:

1. Stable memory usage
2. Thread safety

# Current Implementation

Middleware is represented as a mix of:

1. Server-lvel pre/post processors: `HTTPPreProcessing` and `HTTPPostProcessing`
2. Four different `ResponseCreating` variants

Issues:

1. Each new per-route middleware functionality requires API change, e.g., adding security requires the `ResponseCreating` APIs to support the new security APIs
2. Request parameter parsing is not completely type safe, i.e., the APIs does not directly leverage the specific Codable types
3. Choosing the right `ResponseCreating` and `ParameterParsing` type is confusing

# Time for a New Idea, Take 2

The more I thought about what it means to be an HTTP server framework, the more I felt that I had to break down and reorganize the different concepts in server-side frameworks: web application, router, route handler, and invidual processing delegates.

`WebApp` is the most basic web application, as defined by the HTTP working group. It is simply a closure: `(HTTPRequest, HTTPResponseWriter) -> HTTPBodyProcessing`.

Router is a `WebApp` that manages a map of endpoints to route handlers. In the most basic form, a routing web app is a web app that looks up route handlers in a map: `[Path: RouteHandler]`.

A route handler is similar to a `WebApp` in that it essentially boils down to `(HTTPRequest, HTTPResponseWriter) -> HTTPBodyProcessing`. However, since Kitura's supports path parameters, the router is able to extract path parameter values from the URL. These values need to be passed to the route handler as part of its execution context, but `HTTPRequest` is not modifiable. Hence, I propose a new `HTTPRequestContext` class that is an upgraded `HTTPRequest` type that supports the storing of execution context for the route handler.

Kitura's route handler, in turn, is composed of one or many `ProcessingDelegate`s. A `ProcessingDelegate` is simply a type that implements `func process(request: HTTPRequestContext, response: HTTPResponseWriter)`. That is, given a context and a response object, the delegate will execute its own block of code. All `ProcessingDelegate`s in a route handler share the same execution context store, which can be used to signal subsequent `ProcessingDelegate`s, as well as to tell the route handler how it wants to read the request body.


# Now to Implement the New Idea, Take 2

Branch here: https://github.com/IBM-Swift/Kitura/tree/UnsupportedWIP-routing

**Note**: names of various types, functions, and parameters are not final

### RoutingWebApp

`Router` and `RequestHandlingCoordinator` are now one single class. This class is a `WebApp` that can be used directly with any Swift HTTP compliant server framework.

```swift
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
```

`RoutingWebApp` manages routes. On each new request, `RoutingWebApp` will look up the correct route handler for that request, set up an `HTTPRequestContext`, and execute the route handler using that context.

### HTTPRequestContext

```swift
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
```

`HTTPRequestContext` is an upgraded `HTTPRequest` type with a dictionary solely used for extension conveniences.

### KituraRouteHandler

Much of new features of this new routing approach are located in `KituraRouteHandler`.

```swift
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
```

While you can use any `RouteHandler` implementation with the `RoutingWebApp`, `KituraRouteHandler` is our own implementation that supports 1) chaining, 2) body streaming, and 3) body buffering/parsing.

# Some Questions Remain

1. What is the memory usage/pattern of this routing paradigm?
2. How to ensure thread safety?
3. Use a separate `RouteContext` type instead of upgrading `HTTPRequest` to `HTTPRequestContext`?