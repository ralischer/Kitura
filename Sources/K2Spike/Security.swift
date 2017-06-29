import Foundation
import Dispatch
import SwiftServerHttp
import LoggerAPI

public enum AuthorizationScheme {
    public typealias SetContext = (RequestContext, String) -> RequestContext

    case basic(BasicAuth)
    case apiKey(APIKey)
    case oauth2(OAuth2)

    func authorize(request: HTTPRequest, context: RequestContext, scopes: [String]) -> AuthorizationResult {
        switch(self) {
        case .basic(let basicAuth):
            return basicAuth.verifyAuthorization(request: request, context: context, scopes: scopes)
        case .apiKey(let apiKey):
            return apiKey.verifyAuthorization(request: request, context: context, scopes: scopes)
        case .oauth2(let oauth2):
            return oauth2.verifyAuthorization(request: request, context: context, scopes: scopes)
        }
    }
}

enum AuthorizationResult {
    case proceed(RequestContext)
    case redirect(RequestContext, ResponseCreating)
    case responseCreating(RequestContext, ResponseCreating)
}

public enum Authorization {
    case authorized(userInfo: String)
    case unauthorized
    case forbidden
}

public enum AuthorizationVerifier {
    case noAuthorization
    case verify(scheme: AuthorizationScheme, scopes: [String])
    case verifyAny([(scheme: AuthorizationScheme, scopes: [String])])
    case verifyAll([(scheme: AuthorizationScheme, scopes: [String])])

    func authorize(request: HTTPRequest, context: RequestContext) -> AuthorizationResult {
        switch(self) {
        case .noAuthorization:
            return .proceed(context)
        case .verify(let scheme, let scopes):
            return scheme.authorize(request: request, context: context, scopes: scopes)
        case .verifyAny(let schemes):
            var finalResult: AuthorizationResult?
            for (scheme, scopes) in schemes {
                let result = scheme.authorize(request: request, context: context, scopes: scopes)
                switch result {
                case .proceed:
                    return result
                case .redirect:
                    finalResult = result
                case .responseCreating:
                    if finalResult == nil {
                        finalResult = result
                    }
                }
            }

            if let finalResult = finalResult {
                return finalResult
            } else {
                Log.error("empty `any` AuthorizationVerifier for \(request.target)")
                return .responseCreating(context, AuthorizationResponseCreator(status: .internalServerError, body: "Invalid AuthorizationVerifier"))
            }
        case let .verifyAll(schemes):
            var finalResult: AuthorizationResult?
            var combinedContext = context
            for (scheme, scopes) in schemes {
                let result = scheme.authorize(request: request, context: combinedContext, scopes: scopes)
                switch result {
                case .proceed(let newContext):
                    combinedContext = newContext
                    finalResult = result
                default:
                    return result
                }
            }

            if let finalResult = finalResult {
                return finalResult
            } else {
                Log.error("empty `all` AuthorizationVerifier for \(request.target)")
                return .responseCreating(context, AuthorizationResponseCreator(status: .internalServerError, body: "Invalid AuthorizationVerifier"))
            }
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


public struct BasicAuth {
    public typealias Authorize = (String, String) -> Authorization

    let scheme = "Basic"
    let realm: String
    let authorize: Authorize
    let setContext: AuthorizationScheme.SetContext

    func verifyAuthorization(request: HTTPRequest, context: RequestContext, scopes: [String]) -> AuthorizationResult {
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
            return .responseCreating(context, responseCreator)
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

public struct APIKey {
    public typealias Authorize = (String) -> Authorization

    let name: String
    let location: Location
    let authorize: Authorize
    let setContext: AuthorizationScheme.SetContext

    public enum Location {
        case query
        case header
    }

    func verifyAuthorization(request: HTTPRequest, context: RequestContext, scopes: [String]) -> AuthorizationResult {
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
            return .responseCreating(context, responseCreator)
        }
    }
}

public struct OAuth2 {
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
    let setContext: AuthorizationScheme.SetContext

    func verifyAuthorization(request: HTTPRequest, context: RequestContext, scopes: [String]) -> AuthorizationResult {
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
                return .responseCreating(context, AuthorizationResponseCreator(status: .unauthorized, body: "State not set or invalid"))
            }

            guard let location = sessionInfo.originalTarget, URL(string: location) != nil else {
                Log.warning("Invalid originalTarget: \(sessionInfo.originalTarget ?? "nil") for \(target.path)")
                return .responseCreating(context, AuthorizationResponseCreator(status: .unauthorized, body: "originalTarget not set or invalid"))
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
                return .redirect(context, AuthorizationResponseCreator(headers: headers))
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
            return .redirect(context, AuthorizationResponseCreator(headers: headers))
        } else {
            if let authorization = sessionInfo.authorization {
                switch authorization {
                case .authorized(let userInfo):
                    return .proceed(setContext(context, userInfo))
                case .unauthorized:
                    return .responseCreating(context, AuthorizationResponseCreator(status: .unauthorized))
                case .forbidden:
                    return .responseCreating(context, AuthorizationResponseCreator(status: .forbidden))
                }
            }

            let scopeList = scopes.joined(separator: " ")
            let state = UUID().uuidString
            sessionInfo.state = state
            sessionInfo.originalTarget = request.target
            let location = "\(authorizationUrl.absoluteString)?response_type=code&client_id=\(clientId)&redirect_uri=\(redirectUrl.absoluteString)&scope=\(scopeList)&state=\(state)"

            if let location = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                headers["Location"] = [location]
                return .redirect(context, AuthorizationResponseCreator(headers: headers))
            } else {
                Log.error("addingPercentEncoding to \(location) failed")
                headers["Location"] = [location]
                return .redirect(context, AuthorizationResponseCreator(headers: headers, status: .unauthorized, body: "Server error"))
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

class AuthorizationResponseCreator: ResponseCreating {
    let headers: HTTPHeaders
    let status: HTTPResponseStatus
    let body: String

    init(headers: HTTPHeaders = HTTPHeaders(), status: HTTPResponseStatus = .internalServerError, body: String? = nil) {
        self.headers = headers
        self.status = status
        self.body = body ?? status.reasonPhrase
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

        let data = body.data(using: .utf8)
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
