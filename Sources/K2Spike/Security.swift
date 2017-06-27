import Foundation
import Dispatch
import SwiftServerHttp
import LoggerAPI

protocol SecurityProtocol {
    func process(request: HTTPRequest, context: RequestContext, scopes: [String]) -> SecurityResult
}

public enum Security: SecurityProtocol {
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
    case authorized(sessionInfo: String)
    case unauthorized
    case forbidden
}

public struct SecurityOptions {
    private let schemes: [[(security: Security, scopes: [String])]]

    public init(_ security: Security?, scopes: [String] = []) {
        if let security = security {
            self.schemes = [[(security, scopes)]]
        } else {
            self.schemes = [[]] // no security
        }
    }

    public init(schemes: [[(security: Security, scopes: [String])]]) {
        self.schemes = schemes
    }

    public init(all: [(security: Security, scopes: [String])]) {
        self.schemes = [all]
    }

    public init(any: [(security: Security, scopes: [String])]) {
        self.schemes = any.map { [$0] }
    }

    func process(request: HTTPRequest, context: RequestContext) -> SecurityResult {
        var response: ResponseCreating?
        var ctx = context

        for logicalOrSchemes in schemes {
            var logicalAndResponse: ResponseCreating?
            var logicalAndCtx = context
            logicalAndLoop: for (security, scopes) in logicalOrSchemes {
                switch security.process(request: request, context: ctx, scopes: scopes) {
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
    private static let validity: TimeInterval = 1800
    private static let cookieName = "kitura_session"

    private static var storage = [String: [String: (info: String, expires: Date)]]()

    private static func getCookies(_ request: HTTPRequest) -> [String: String] {
        var cookies = [String: String]()
        if let cookieHeader = request.headers["cookie"].first {
            for cookie in cookieHeader.components(separatedBy: ";") {
                guard let range = cookie.range(of: "=") else {
                    continue
                }
                let name = cookie.substring(to: range.lowerBound).trimmingCharacters(in: .whitespaces)
                let value = cookie.substring(from: range.upperBound)
                cookies[name] = value
            }
        }
        return cookies
    }

    private static func getSession(_ request: HTTPRequest) -> (id: String, isNew: Bool) {
        if let cookieValue = getCookies(request)[cookieName] {
            return (cookieValue, false)
        }
        return (UUID().uuidString, true)
    }

    @discardableResult
    static func store(uuid: String, info: String, request: HTTPRequest, expires: TimeInterval?, responseHeaders: inout HTTPHeaders) -> String {
        let session = getSession(request)
        var data = storage[session.id] ?? [String: (String, Date)]()

        data[uuid] = (info, Date(timeIntervalSinceNow: expires ?? validity))
        storage[session.id] = data

        if session.isNew {
            responseHeaders["Set-Cookie"] = ["\(cookieName)=\(session.id); Path=/"]
        }
        return session.id
    }

    static func retrieve(uuid: String, request: HTTPRequest) -> String? {
        let session = getSession(request)
        guard !session.isNew else {
            return nil
        }
        guard let value = storage[session.id]?[uuid] else {
            return nil
        }
        guard value.expires.timeIntervalSinceNow > 0 else {
            storage.removeValue(forKey: session.id)
            return nil
        }
        return value.info
    }

    @discardableResult
    static func remove(uuid: String, request: HTTPRequest, sessionId: String? = nil) -> String? {
        if let sessionId = sessionId {
            return storage[sessionId]?.removeValue(forKey: uuid)?.info
        }
        let session = getSession(request)
        return storage[session.id]?.removeValue(forKey: uuid)?.info
    }
}


public struct BasicAuth: SecurityProtocol {
    public typealias Authorize = (String, String) -> Authorization

    let realm: String
    let authorize: Authorize
    let setContext: Security.SetContext

    func process(request: HTTPRequest, context: RequestContext, scopes: [String]) -> SecurityResult {
        var authorization: Authorization = .unauthorized
        let authHeader = request.headers["authorization"]
        if !authHeader.isEmpty {
            let components = authHeader[0].components(separatedBy: " ")
            if components.count >= 2 {
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
        case .authorized(let sessionInfo):
            return .proceed(setContext(context, sessionInfo))
        default:
            let responseCreator = SimpleAuthResponseCreator(scheme: "Basic", realm: realm, authorization: authorization)
            return .securityResponse(context, responseCreator)
        }
    }
}

class SimpleAuthResponseCreator: ResponseCreating {
    let scheme: String
    let realm: String
    let authorization: Authorization

    init(scheme: String, realm: String?, authorization: Authorization) {
        self.scheme = scheme
        self.realm = realm ?? "Unknown"
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
    let setContext: Security.SetContext

    public enum Location {
        case query
        case header
    }

    init(name: String, location: Location, authorize: @escaping Authorize, setContext: @escaping Security.SetContext) {
        self.name = name.lowercased()
        self.location = location
        self.authorize = authorize
        self.setContext = setContext
    }

    func process(request: HTTPRequest, context: RequestContext, scopes: [String]) -> SecurityResult {
        var apiKey: String?
        switch(location) {
        case .header:
            apiKey = request.headers[name].first
        case .query:
            if let queryItems = URLComponents(string: request.target)?.queryItems,
                let match = queryItems.first(where: { $0.name.lowercased() == name }) {
                    apiKey = match.value
            }
        }

        var authorization: Authorization = .unauthorized
        if let apiKey = apiKey {
            authorization = authorize(apiKey)
        }

        switch authorization {
        case .authorized(let sessionInfo):
            return .proceed(setContext(context, sessionInfo))
        default:
            let responseCreator = SimpleAuthResponseCreator(scheme: "apikey", realm: name, authorization: authorization)
            return .securityResponse(context, responseCreator)
        }
    }
}

public struct OAuth2: SecurityProtocol {
    public typealias UserInfoRequest = (String, String) -> URLRequest
    public typealias Authorize = ([String: Any]) -> Authorization

    let authorizedId = UUID().uuidString
    let unauthorizedId = UUID().uuidString

    let authorizationUrl: URL
    let redirectUrl: URL
    let tokenUrl: URL
    let userInfoRequest: UserInfoRequest

    let clientId: String
    let clientSecret: String

    let authorize: Authorize
    let setContext: Security.SetContext

    func process(request: HTTPRequest, context: RequestContext, scopes: [String]) -> SecurityResult {
        let target = URLComponents(string: request.target)!
        if redirectUrl.path == target.path { // called back after call to authorizationUrl
            let state: String?
            if let stateId = target.queryItems?.first(where: { $0.name == "state" })?.value {
                state = Session.retrieve(uuid: stateId, request: request)
            } else {
                state = nil
            }

            guard let location = state, URL(string: location) != nil else {
                Log.warning("Invalid state query parameter: \(state ?? "nil") for \(target.path)")
                return .securityResponse(context, OAuth2ResponseCreator(authorization: .unauthorized, body: "State not set or invalid"))
            }

            guard let code = target.queryItems?.first(where: { $0.name == "code" })?.value else {
                Log.warning("No code query parameter for \(target.path)")
                var headers = HTTPHeaders([("Location", location)])
                Session.store(uuid: unauthorizedId, info: "Authorization code not set",
                                              request: request, expires: 600, responseHeaders: &headers)
                return .securityResponse(context, OAuth2ResponseCreator(headers: headers))
            }

            let urlSession = URLSession(configuration: URLSessionConfiguration.default)
            let taskComplete = DispatchSemaphore(value: 0)

            var token = getToken(tokenUrl: tokenUrl, redirectUrl: redirectUrl, authCode: code, urlSession: urlSession, taskComplete: taskComplete)

            let userInfo: [String: Any]?
            if let accessToken = token?["access_token"] as? String, let tokenType = token?["token_type"] as? String {
                userInfo = getUserInfo(userInfoRequest: userInfoRequest, token: accessToken, tokenType: tokenType, urlSession: urlSession, taskComplete: taskComplete)
            } else {
                Log.warning("access_token or token_type unavailable in \(token ?? [:])")
                userInfo = nil
            }

            var authorization: Authorization = .unauthorized
            if let userInfo = userInfo {
                authorization = authorize(userInfo)
            }

            var headers = HTTPHeaders()
            if let location = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                headers["Location"] = [location]
            } else {
                Log.error("addingPercentEncoding to \(location) failed")
                headers["Location"] = [location]
            }

            switch authorization {
            case .authorized(let sessionInfo):
                let sessionId = Session.store(uuid: authorizedId, info: sessionInfo, request: request,
                                           expires: token?["expires_in"] as? TimeInterval, responseHeaders: &headers)

                // remove any prior unauthorized session info
                Session.remove(uuid: unauthorizedId, request: request, sessionId: sessionId)
                return .securityResponse(context, OAuth2ResponseCreator(headers: headers))
            default:
                let sessionId = Session.store(uuid: unauthorizedId, info: String(describing: authorization) + ": Authorization failed",
                                           request: request, expires: 600, responseHeaders: &headers)

                // remove any prior authorized session info
                Session.remove(uuid: authorizedId, request: request, sessionId: sessionId)

                return .securityResponse(context, OAuth2ResponseCreator(headers: headers))
            }
        } else {
            if let sessionInfo = Session.retrieve(uuid: authorizedId, request: request) {
                return .proceed(setContext(context, sessionInfo))
            }
            if let unauthorizedInfo = Session.retrieve(uuid: unauthorizedId, request: request) {
                return .securityResponse(context, OAuth2ResponseCreator(authorization: .unauthorized, body: unauthorizedInfo))
            }

            let scopeList = scopes.joined(separator: " ")
            let stateId = UUID().uuidString

            var headers = HTTPHeaders()
            Session.store(uuid: stateId, info: request.target, request: request, expires: 300, responseHeaders: &headers)
            let location = "\(authorizationUrl.absoluteString)?response_type=code&client_id=\(clientId)&redirect_uri=\(redirectUrl.absoluteString)&scope=\(scopeList)&state=\(stateId)"

            if let location = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                headers["Location"] = [location]
                return .securityResponse(context, OAuth2ResponseCreator(headers: headers))
            } else {
                Log.error("addingPercentEncoding to \(location) failed")
                return .securityResponse(context, OAuth2ResponseCreator(headers: headers, authorization: .unauthorized, body: "Server error"))
            }
        }
    }

    private func getToken(tokenUrl: URL, redirectUrl: URL, authCode: String, urlSession: URLSession, taskComplete: DispatchSemaphore) -> [String: Any]? {
        var request = URLRequest(url: tokenUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let requestBody = "grant_type=authorization_code&code=\(authCode)&client_id=\(clientId)&client_secret=\(clientSecret)&redirect_uri=\(redirectUrl.absoluteString)"
        request.httpBody = requestBody.data(using: .utf8)

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
                    Log.error("Error in token json: \(error)")
                }
            } else {
                Log.error("\(response?.statusCode ?? 0) response for token request")
            }
        }

        task.resume()
        taskComplete.wait()
        return json
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

    init(headers: HTTPHeaders? = nil, authorization: Authorization? = nil, body: String? = nil) {
        self.headers = headers ?? HTTPHeaders()
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
