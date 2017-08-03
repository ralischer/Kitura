// Experimental

// TODO
// 1. Should we make Handler threadsafe? E.g., how to deal
// with ProcessingDelegate
// 2. Default inputs provided to every ProcessingDelegate, e.g.
// HTTPRequest and HTTPResponseWriter?

import HTTP

public protocol ProcessingDelegate: class {
    associatedtype Input
    associatedtype Output

    func process(_ input: Input) -> Output
}

public class Handler<Input, Output>: ProcessingDelegate {
    private class Noop<T>: ProcessingDelegate {
        public func process(_ input: T) -> T {
            return input
        }
    }

    let _process: (Input) -> Output

    public init<PreviousAction: ProcessingDelegate, CurrentAction: ProcessingDelegate>
        (previousAction: PreviousAction, currentAction: CurrentAction)
        where PreviousAction.Input == Input, PreviousAction.Output == CurrentAction.Input, CurrentAction.Output == Output {
        _process = { input in
            return currentAction.process(previousAction.process(input))
        }
    }

    public convenience init<CurrentAction: ProcessingDelegate>
        (currentAction: CurrentAction)
        where CurrentAction.Input == Input, CurrentAction.Output == Output {
        self.init(previousAction: Noop<Input>(), currentAction: currentAction)
    }

    public func process(_ input: Input) -> Output {
        return _process(input)
    }

    public func then<NextDelegate: ProcessingDelegate>(use: NextDelegate) -> Handler<Input, NextDelegate.Output> where NextDelegate.Input == Output {
        return Handler<Input, NextDelegate.Output>(previousAction: self, currentAction: use)
    }
}

// Router example
public struct Router2 {
    private var handlers: [Path: Handler<(request: HTTPRequest, response: HTTPResponseWriter), HTTPBodyProcessing>] = [:]

    public init() {}

    public mutating func add(verb: Verb, path: String, handler: Handler<(request: HTTPRequest, response: HTTPResponseWriter), HTTPBodyProcessing>) {
        handlers[Path(path: path, verb: verb)] = handler
    }

    public mutating func add<HandlerDelegate: ProcessingDelegate>(verb: Verb, path: String, delegate: HandlerDelegate) where HandlerDelegate.Input == (request: HTTPRequest, response: HTTPResponseWriter), HandlerDelegate.Output == HTTPBodyProcessing {
        handlers[Path(path: path, verb: verb)] = Handler(currentAction: delegate)
    }

    // Given an HTTPRequest, find the request handler
    func getHandler(for request: HTTPRequest) -> Handler<(request: HTTPRequest, response: HTTPResponseWriter), HTTPBodyProcessing>? {
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
}

// Coordinator example
public class RouteDispatcher {
    let router: Router2

    public init(router: Router2) {
        self.router = router
    }

    public func handle(request: HTTPRequest, response: HTTPResponseWriter) -> HTTPBodyProcessing {
        guard let handler = router.getHandler(for: request) else {
            // No response creator found
            // Handle failure
            return serveWithFailureHandler(request: request, response: response)
        }

        return handler.process((request: request, response: response))
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
