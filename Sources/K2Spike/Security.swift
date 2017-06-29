import Foundation
import Dispatch
import SwiftServerHttp
import LoggerAPI

protocol SecurityProtocol {
    func process(request: HTTPRequest, context: RequestContext, scopes: [String]) -> SecurityResult
}

public enum SecurityScheme: SecurityProtocol {
    public typealias SetContext = (RequestContext, String) -> RequestContext

    case basic(BasicAuth)
    case apiKey(APIKey)
    case oauth2(OAuth2)

    func process(request: HTTPRequest, context: RequestContext, scopes: [String]) -> SecurityResult {
        switch(self) {
        case .basic(let basicAuth):
            return basicAuth.process(request: request, context: context, scopes: scopes)
        case .apiKey(let apiKey):
            return apiKey.process(request: request, context: context, scopes: scopes)
        case .oauth2(let oauth2):
            return oauth2.process(request: request, context: context, scopes: scopes)
        }
    }
}

enum SecurityResult {
    case proceed(RequestContext)
    case securityResponse(RequestContext, ResponseCreating)
}

public enum Authorization {
    case authorized(userInfo: String)
    case unauthorized
    case forbidden
}

public struct SecurityRequirement: Sequence {
    private let schemes: [(scheme: SecurityScheme, scopes: [String])]

    public init(_ scheme: SecurityScheme?, scopes: [String] = []) {
        if let scheme = scheme {
            self.schemes = [(scheme, scopes)]
        } else {
            self.schemes = [] // no security
        }
    }

    public init(all: [(scheme: SecurityScheme, scopes: [String])]) {
        self.schemes = all
    }

    public func makeIterator() -> IndexingIterator<[(scheme: SecurityScheme, scopes: [String])]> {
        return schemes.makeIterator()
    }
}

public struct Security {
    private let options: [SecurityRequirement]

    public init(_ scheme: SecurityScheme?, scopes: [String] = []) {
        if let scheme = scheme {
            self.options = [SecurityRequirement(scheme, scopes: scopes)]
        } else {
            self.options = [] // no security
        }
    }

    public init(options: [SecurityRequirement]) {
        self.options = options
    }

    public init(all: [(scheme: SecurityScheme, scopes: [String])]) {
        self.options = [SecurityRequirement(all: all)]
    }

    public init(any: [(scheme: SecurityScheme, scopes: [String])]) {
        self.options = any.map { SecurityRequirement($0.scheme, scopes: $0.scopes) }
    }

    func process(request: HTTPRequest, context: RequestContext) -> SecurityResult {
        var response: ResponseCreating?
        var ctx = context

        for logicalOrSchemes in options {
            var logicalAndResponse: ResponseCreating?
            var logicalAndCtx = context
            logicalAndLoop: for (scheme, scopes) in logicalOrSchemes {
                switch scheme.process(request: request, context: logicalAndCtx, scopes: scopes) {
                case .proceed(let secureContext):
                    logicalAndCtx = secureContext
                case .securityResponse(let secureContext, let responseCreator):
                    logicalAndCtx = secureContext
                    logicalAndResponse = responseCreator
                    break logicalAndLoop
                }
            }

            if let logicalAndResponse = logicalAndResponse {
                ctx = logicalAndCtx
                if response == nil { // process schemes in order
                    response = logicalAndResponse
                }
            } else {
                return .proceed(logicalAndCtx)
            }
        }

        if let response = response {
            return .securityResponse(ctx, response)
        } else {
            return .proceed(ctx)
        }
    }
}

internal class Session {
    private static let defaultValidity: TimeInterval = 1800
    private static let cookieName = "kitura_session"
    private static var sessions = [String: [String: Session]]()

    var validity = defaultValidity
    private var expires = Date(timeIntervalSinceNow: defaultValidity)

    var sessionInfo: Any? {
        didSet {
            expires = Date(timeIntervalSinceNow: validity)
        }
    }

    static func getSession(_ request: HTTPRequest, applicationId: String, responseHeaders: inout HTTPHeaders) -> Session {
        var sessionId: String?
        if let cookieHeader = request.headers["cookie"].first {
            for cookie in cookieHeader.components(separatedBy: ";") {
                guard let range = cookie.range(of: "=") else {
                    continue
                }
                if cookieName == cookie.substring(to: range.lowerBound).trimmingCharacters(in: .whitespaces) {
                    sessionId = cookie.substring(from: range.upperBound)
                    break
                }
            }
        }

        if let sessionId = sessionId, var userSessions = sessions[sessionId] {
            if let session = userSessions[applicationId], session.expires.timeIntervalSinceNow > 0 {
                return session
            } else {
                let session = Session()
                userSessions[applicationId] = session
                sessions[sessionId] = userSessions
                return session
            }
        }

        let newSession = Session()
        let newSessionId = UUID().uuidString
        sessions[newSessionId] = [applicationId: newSession]
        responseHeaders["Set-Cookie"] = ["\(cookieName)=\(newSessionId); Path=/"]
        return newSession
    }
}


public struct BasicAuth: SecurityProtocol {
    public typealias Authorize = (String, String) -> Authorization

    let scheme = "Basic"
    let realm: String
    let authorize: Authorize
    let setContext: SecurityScheme.SetContext

    func process(request: HTTPRequest, context: RequestContext, scopes: [String]) -> SecurityResult {
        var authorization: Authorization = .unauthorized
        let authHeader = request.headers["authorization"]
        if !authHeader.isEmpty {
            let components = authHeader[0].characters.split(separator: " ", maxSplits: 1).map(String.init)
            if components.count == 2, components[0] == scheme {
                if let data = Data(base64Encoded: components[1]), let decodedAuth = String(data: data, encoding: .utf8) {
                    if let range = decodedAuth.range(of: ":") {
                        let username = decodedAuth.substring(to: range.lowerBound)
                        let password = decodedAuth.substring(from: range.upperBound)
                        authorization = authorize(username, password)
                    }
                }
            }
        }

        switch authorization {
        case .authorized(let userInfo):
            return .proceed(setContext(context, userInfo))
        default:
            let responseCreator = SimpleAuthResponseCreator(scheme: scheme, realm: realm, authorization: authorization)
            return .securityResponse(context, responseCreator)
        }
    }
}

class SimpleAuthResponseCreator: ResponseCreating {
    let scheme: String
    let realm: String
    let authorization: Authorization

    init(scheme: String, realm: String, authorization: Authorization) {
        self.scheme = scheme
        self.realm = realm
        self.authorization = authorization
    }

    public func serve(request: HTTPRequest, context: RequestContext, response: HTTPResponseWriter) -> HTTPBodyProcessing {
        let status: HTTPResponseStatus
        var headers: HTTPHeaders?
        var responseBody: Data?

        switch(authorization) {
        case .unauthorized:
            status = .unauthorized
            headers = HTTPHeaders([("WWW-Authenticate", "\(scheme) realm=\"\(realm)\"")])
        case .forbidden:
            status = .forbidden
            responseBody = "Access Forbidden".data(using: .utf8)
        case .authorized:
            // we should not be created if authorized
            status = .internalServerError
            responseBody = "Internal Server Error".data(using: .utf8)
        }

        response.writeResponse(HTTPResponse(httpVersion: request.httpVersion,
                                       status: status,
                                       transferEncoding: .identity(contentLength: UInt(responseBody?.count ?? 0)),
                                       headers: headers ?? HTTPHeaders()))

        if let responseBody = responseBody {
            response.writeBody(data: responseBody)
        }

        response.done()
        return .discardBody
    }
}

public struct APIKey: SecurityProtocol {
    public typealias Authorize = (String) -> Authorization

    let name: String
    let location: Location
    let authorize: Authorize
    let setContext: SecurityScheme.SetContext

    public enum Location {
        case query
        case header
    }

    func process(request: HTTPRequest, context: RequestContext, scopes: [String]) -> SecurityResult {
        var apiKey: String?
        switch(location) {
        case .header:
            apiKey = request.headers[name].first
        case .query:
            if let queryItems = URLComponents(string: request.target)?.queryItems,
                let match = queryItems.first(where: { $0.name == name }) {
                    apiKey = match.value
            }
        }

        var authorization: Authorization = .unauthorized
        if let apiKey = apiKey {
            authorization = authorize(apiKey)
        }

        switch authorization {
        case .authorized(let userInfo):
            return .proceed(setContext(context, userInfo))
        default:
            let responseCreator = SimpleAuthResponseCreator(scheme: "apikey", realm: name, authorization: authorization)
            return .securityResponse(context, responseCreator)
        }
    }
}

public struct OAuth2: SecurityProtocol {
    public typealias UserInfoRequest = (String, String) -> URLRequest
    public typealias Authorize = ([String: Any]) -> Authorization

    private struct SessionInfo {
        var authorization: Authorization?
        var state: String?
        var originalTarget: String?
    }

    let applicationId = UUID().uuidString

    let authorizationUrl: URL
    let redirectUrl: URL
    let tokenUrl: URL
    let userInfoRequest: UserInfoRequest

    let clientId: String
    let clientSecret: String

    let authorize: Authorize
    let setContext: SecurityScheme.SetContext

    func process(request: HTTPRequest, context: RequestContext, scopes: [String]) -> SecurityResult {
        let target = URLComponents(string: request.target)!
        var headers = HTTPHeaders()

        let session = Session.getSession(request, applicationId: applicationId, responseHeaders: &headers)
        var sessionInfo = session.sessionInfo as? SessionInfo ?? SessionInfo()
        defer {
            session.sessionInfo = sessionInfo
        }

        if redirectUrl.path == target.path { // called back after call to authorizationUrl
            let state = target.queryItems?.first(where: { $0.name == "state" })?.value
            guard state == sessionInfo.state else {
                Log.warning("Invalid state query parameter: \(state ?? "nil") for \(target.path)")
                return .securityResponse(context, OAuth2ResponseCreator(authorization: .unauthorized, body: "State not set or invalid"))
            }

            guard let location = sessionInfo.originalTarget, URL(string: location) != nil else {
                Log.warning("Invalid originalTarget: \(sessionInfo.originalTarget ?? "nil") for \(target.path)")
                return .securityResponse(context, OAuth2ResponseCreator(authorization: .unauthorized, body: "originalTarget not set or invalid"))
            }

            if let location = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                headers["Location"] = [location]
            } else {
                Log.error("addingPercentEncoding to \(location) failed")
                headers["Location"] = [location]
            }

            guard let code = target.queryItems?.first(where: { $0.name == "code" })?.value else {
                Log.warning("No code query parameter for \(target.path)")
                sessionInfo.authorization = .unauthorized
                return .securityResponse(context, OAuth2ResponseCreator(headers: headers))
            }

            let urlSession = URLSession(configuration: URLSessionConfiguration.default)
            let taskComplete = DispatchSemaphore(value: 0)

            var token = getToken(tokenUrl: tokenUrl, redirectUrl: redirectUrl, authCode: code, urlSession: urlSession, taskComplete: taskComplete)

            let userInfo: [String: Any]?
            if let accessToken = token["access_token"] as? String, let tokenType = token["token_type"] as? String {
                userInfo = getUserInfo(userInfoRequest: userInfoRequest, token: accessToken, tokenType: tokenType, urlSession: urlSession, taskComplete: taskComplete)
            } else {
                Log.warning("access_token or token_type unavailable in \(token)")
                userInfo = nil
            }

            var authorization: Authorization = .unauthorized
            if let userInfo = userInfo {
                authorization = authorize(userInfo)
            }

            sessionInfo.authorization = authorization
            return .securityResponse(context, OAuth2ResponseCreator(headers: headers))
        } else {
            if let authorization = sessionInfo.authorization {
                switch authorization {
                case .authorized(let userInfo):
                    return .proceed(setContext(context, userInfo))
                default:
                    return .securityResponse(context, OAuth2ResponseCreator(authorization: authorization))
                }
            }

            let scopeList = scopes.joined(separator: " ")
            let state = UUID().uuidString
            sessionInfo.state = state
            sessionInfo.originalTarget = request.target
            let location = "\(authorizationUrl.absoluteString)?response_type=code&client_id=\(clientId)&redirect_uri=\(redirectUrl.absoluteString)&scope=\(scopeList)&state=\(state)"

            if let location = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                headers["Location"] = [location]
                return .securityResponse(context, OAuth2ResponseCreator(headers: headers))
            } else {
                Log.error("addingPercentEncoding to \(location) failed")
                return .securityResponse(context, OAuth2ResponseCreator(headers: headers, authorization: .unauthorized, body: "Server error"))
            }
        }
    }

    private func getToken(tokenUrl: URL, redirectUrl: URL, authCode: String, urlSession: URLSession, taskComplete: DispatchSemaphore) -> [String: Any] {
        var request = URLRequest(url: tokenUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let requestBody = "grant_type=authorization_code&code=\(authCode)&client_id=\(clientId)&client_secret=\(clientSecret)&redirect_uri=\(redirectUrl.absoluteString)"
        request.httpBody = requestBody.data(using: .utf8)

        var token = [String: Any]()
        var body: String?
        let task = urlSession.dataTask(with: request) { (responseBody, rawResponse, error) in
            defer {
                taskComplete.signal()
            }
            let response = rawResponse as? HTTPURLResponse
            if response?.statusCode == Int(HTTPResponseStatus.ok.code), let responseBody = responseBody {
                do {
                    body = String(describing: responseBody)
                    if let json = try JSONSerialization.jsonObject(with: responseBody, options: []) as? [String: Any] {
                        token = json
                    }
                } catch {
                    Log.error("Error in token json: \(error)")
                }
            } else {
                Log.error("\(response?.statusCode ?? 0) response for token request")
            }
        }

        task.resume()
        taskComplete.wait()
        return token
    }

    private func getUserInfo(userInfoRequest: UserInfoRequest, token: String, tokenType: String, urlSession: URLSession, taskComplete: DispatchSemaphore) -> [String: Any]? {
        var request = userInfoRequest(token, tokenType)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var json: [String: Any]?
        var body: String?
        let task = urlSession.dataTask(with: request) { (responseBody, rawResponse, error) in
            defer {
                taskComplete.signal()
            }
            let response = rawResponse as? HTTPURLResponse
            if response?.statusCode == Int(HTTPResponseStatus.ok.code), let responseBody = responseBody {
                do {
                    body = String(describing: responseBody)
                    json = try JSONSerialization.jsonObject(with: responseBody, options: []) as? [String: Any]
                } catch {
                    Log.error("Error in userinfo json: \(error)")
                }
            } else {
                Log.error("\(response?.statusCode ?? 0) response for userinfo request")
            }
        }

        task.resume()
        taskComplete.wait()
        return json
    }
}

class OAuth2ResponseCreator: ResponseCreating {
    let headers: HTTPHeaders
    let authorization: Authorization?
    let body: String?

    init(headers: HTTPHeaders = HTTPHeaders(), authorization: Authorization? = nil, body: String? = nil) {
        self.headers = headers
        self.authorization = authorization
        self.body = body
    }

    public func serve(request: HTTPRequest, context: RequestContext, response: HTTPResponseWriter) -> HTTPBodyProcessing {
        if !headers["location"].isEmpty {
            response.writeResponse(HTTPResponse(httpVersion: request.httpVersion,
                                           status: .found,
                                           transferEncoding: .identity(contentLength: 0),
                                           headers: headers))
            response.done()
            return .discardBody
        }

        let status: HTTPResponseStatus
        if let authorization = authorization {
            switch(authorization) {
            case .unauthorized:
                status = .unauthorized
            case .forbidden:
                status = .forbidden
            case .authorized:
                status = .internalServerError
            }
        } else {
            status = .internalServerError
        }

        let data = body?.data(using: .utf8)
        response.writeResponse(HTTPResponse(httpVersion: request.httpVersion,
                                       status: status,
                                       transferEncoding: .identity(contentLength: UInt(data?.count ?? 0)),
                                       headers: headers))

        if let data = data {
            response.writeBody(data: data)
        }

        response.done()
        return .discardBody
    }
}
