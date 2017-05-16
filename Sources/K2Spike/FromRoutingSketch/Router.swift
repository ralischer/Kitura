import Foundation
import HTTPSketch

extension String {
    var isPathParameter: Bool {
        return self.hasPrefix("{") && self.hasSuffix("}")
    }

    var parameterName: String? {
        guard self.isPathParameter else {
            return nil
        }

        return self[self.index(after: self.startIndex)..<self.index(before: self.endIndex)]
    }
}

public struct PathComponents {
    let parameters: [String: String]?
    let queries: [URLQueryItem]?
}

struct URLParser {
    var pathComponents: [String]

    init?(path: String) {
        pathComponents = path.components(separatedBy: "/")

        if pathComponents.first == "" {
            pathComponents.removeFirst()
        }
    }

    func parse(_ string: String) -> PathComponents? {
        guard let url = URL(string: string) else {
            return nil
        }

        // Step 1
        // Parse URL for path parameters
        var components = url.pathComponents

        if components.first == "/" {
            components.removeFirst()
        }

        guard pathComponents.count == components.count else {
            return nil
        }

        var parameters: [String: String] = [:]

        for i in 0..<pathComponents.count {
            if let parameter = pathComponents[i].parameterName {
                parameters[parameter] = components[i]
            }
            else {
                guard pathComponents[i] == components[i] else {
                    // path does not match
                    return nil
                }
            }
        }

        // Step 2
        // Parse URL for query parameters
        let queries = URLComponents(string: string)?.queryItems
        
        return PathComponents(parameters: parameters, queries: queries)
    }
}

public struct Router {
    var map: [Path: ResponseCreating]

    public func route(request: HTTPRequest) -> (PathComponents, ResponseCreating)? {
        guard let verb = Verb(request.method) else {
            return nil
        }
        
        //shortcut for exact match
        let exactPath = Path(path: request.target, verb: verb)
        
        if let exactMatch = map[exactPath] {
            return (PathComponents(parameters:[:],queries:nil), exactMatch)
        }

        for (path, creator) in map {
            guard verb == path.verb,
                let parser = URLParser(path: path.path),
                let components = parser.parse(request.target) else {
                continue
            }

            return (components, creator)
        }

        return nil
    }
    
    public init (map:[Path: ResponseCreating]) {
        self.map = map
    }
}

public protocol RequestStructParser {
    associatedtype T: Any
    func createStruct(path:String, queryParams:String?, Body:Data?) -> T?
}

public struct RequestContext {
    let storage: [String: Any]
    init(dict:[String:Any]) {
        storage = dict
    }
    
    public subscript(key: String) -> Any? {
        get {
            return storage[key]
        }
    }
    
    public func adding(dict:[String:Any]) -> RequestContext {
        var newstorage = storage
        dict.forEach{ newstorage[$0] = $1 }
        return RequestContext(dict: newstorage)
    }
}

