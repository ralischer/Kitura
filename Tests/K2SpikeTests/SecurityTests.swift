import XCTest
import HeliumLogger
@testable import SwiftServerHttp
@testable import K2Spike

class SecurityTests: XCTestCase {
    static var allTests = [
        ("testBasicAuthAuthorized", testBasicAuthAuthorized),
        ("testBasicAuthUnauthorized", testBasicAuthUnauthorized),
        ("testBasicAuthForbidden", testBasicAuthForbidden),
        ("testAPIKeyAuthorized", testAPIKeyAuthorized),
        ("testAPIKeyUnauthorized", testAPIKeyUnauthorized),
        ("testAPIKeyForbidden", testAPIKeyForbidden),
        ("testOauth2Authorized", testOauth2Authorized),
        ("testOauth2TokenError", testOauth2TokenError),
        ("testOauth2UserInfoError", testOauth2UserInfoError)
    ]

    func testBasicAuthAuthorized() {
        let authorization = "Basic " + "foo:bar".data(using: .utf8)!.base64EncodedString()
        let requestHeaders = HTTPHeaders([("Authorization", authorization)])
        testBasicAuth(requestHeaders: requestHeaders, expectedStatus: .ok)
    }

    func testBasicAuthUnauthorized() {
        testBasicAuth(requestHeaders: HTTPHeaders(), expectedStatus: .unauthorized)

        let authorization = "Basic " + "foo:bar1".data(using: .utf8)!.base64EncodedString()
        let requestHeaders = HTTPHeaders([("Authorization", authorization)])
        testBasicAuth(requestHeaders: requestHeaders, expectedStatus: .unauthorized)
    }

    func testBasicAuthForbidden() {
        let authorization = "Basic " + "foo2:bar".data(using: .utf8)!.base64EncodedString()
        let requestHeaders = HTTPHeaders([("Authorization", authorization)])
        testBasicAuth(requestHeaders: requestHeaders, expectedStatus: .forbidden)
    }

    let apiKeyName = "X-API-Key"
    let apiKeyValue = "foo-bar-123"

    func testAPIKeyAuthorized() {
        testAPIKey(location: .header, requestHeaders: HTTPHeaders([(apiKeyName, apiKeyValue)]), query: nil, expectedStatus: .ok)
        testAPIKey(location: .query, requestHeaders: nil, query: "\(apiKeyName)=\(apiKeyValue)", expectedStatus: .ok)
    }

    func testAPIKeyUnauthorized() {
        testAPIKey(location: .query, requestHeaders: HTTPHeaders([(apiKeyName, apiKeyValue)]), query: nil, expectedStatus: .unauthorized)
        testAPIKey(location: .header, requestHeaders: nil, query: "\(apiKeyName)=\(apiKeyValue)", expectedStatus: .unauthorized)
    }

    func testAPIKeyForbidden() {
        testAPIKey(location: .header, requestHeaders: HTTPHeaders([(apiKeyName, apiKeyValue + ".")]), query: nil, expectedStatus: .forbidden)
        testAPIKey(location: .query, requestHeaders: nil, query: "\(apiKeyName)==\(apiKeyValue)", expectedStatus: .forbidden)
    }

    private func testBasicAuth(requestHeaders: HTTPHeaders, expectedStatus: HTTPResponseStatus) {
        let sessionInfo = UUID().uuidString

        let authorize: BasicAuth.Authorize = { username, password in
            if username == "foo" {
                return password == "bar" ? .authorized(sessionInfo: sessionInfo) : .unauthorized
            } else {
                return .forbidden
            }
        }
        let setContext: Security.SetContext = { context, info in
            return context.adding(dict: [SecurityTestWebApp.contextKey: info])
        }

        let basicAuth = BasicAuth(realm: "test realm", authorize: authorize, setContext: setContext)

        let path = "/testBasicAuth"
        var router = Router()
        router.add(verb: .GET, path: path, responseCreator: SecurityTestWebApp(), security: SecurityOptions(.basic(basicAuth)))

        let request = HTTPRequest(method: .GET, target: path, httpVersion: (1, 1), headers: requestHeaders)
        let resolver = TestResponseResolver(request: request, requestBody: Data())
        let coordinator = RequestHandlingCoordinator(router: router)
        resolver.resolveHandler(coordinator.handle)
        XCTAssertNotNil(resolver.response)
        XCTAssertEqual(expectedStatus.code, resolver.response?.status.code ?? 0)

        if expectedStatus == .ok {
            XCTAssertNotNil(resolver.responseBody)
            XCTAssertEqual("Hello, \(sessionInfo)!", String(data: resolver.responseBody ?? Data(), encoding: .utf8) ?? "Nil")
        }
    }

    private func testAPIKey(location: APIKey.Location, requestHeaders: HTTPHeaders?, query: String?, expectedStatus: HTTPResponseStatus) {
        let sessionInfo = UUID().uuidString

        let authorize: APIKey.Authorize = { keyValue in
            if keyValue == self.apiKeyValue {
                return .authorized(sessionInfo: sessionInfo)
            } else {
                return .forbidden
            }
        }
        let setContext: Security.SetContext = { context, info in
            return context.adding(dict: [SecurityTestWebApp.contextKey: info])
        }

        let apiKey = APIKey(name: apiKeyName, location: location, authorize: authorize, setContext: setContext)

        let path = "/testAPIKey"
        var router = Router(security: SecurityOptions(.apiKey(apiKey)))
        router.add(verb: .GET, path: path, responseCreator: SecurityTestWebApp())

        let target: String
        if let query = query {
            target = path + "?" + query
        } else {
            target = path
        }
        let headers = requestHeaders ?? HTTPHeaders()

        let request = HTTPRequest(method: .GET, target: target, httpVersion: (1, 1), headers: headers)
        let resolver = TestResponseResolver(request: request, requestBody: Data())
        let coordinator = RequestHandlingCoordinator(router: router)
        resolver.resolveHandler(coordinator.handle)
        XCTAssertNotNil(resolver.response)
        XCTAssertEqual(expectedStatus.code, resolver.response?.status.code ?? 0)

        if expectedStatus == .ok {
            XCTAssertNotNil(resolver.responseBody)
            XCTAssertEqual("Hello, \(sessionInfo)!", String(data: resolver.responseBody ?? Data(), encoding: .utf8) ?? "Nil")
        }
    }

    public func testOauth2Authorized() {
        testOauth2(tokenOk: true, userInfoOk: true)
    }

    public func testOauth2TokenError() {
        testOauth2(tokenOk: false, userInfoOk: true)
    }

    public func testOauth2UserInfoError() {
        testOauth2(tokenOk: true, userInfoOk: false)
    }

    public func testOauth2(tokenOk: Bool, userInfoOk: Bool) {
        HeliumLogger.use(.info)

        let provider = OAuth2Provider(tokenOk: tokenOk, userInfoOk: userInfoOk)
        let port = 8443
        let host = "http://localhost:\(port)"

        var providerRouter = Router()
        providerRouter.add(verb: .GET, path: provider.authPath, responseCreator: provider)
        providerRouter.add(verb: .POST, path: provider.tokenPath, responseCreator: provider)
        providerRouter.add(verb: .GET, path: provider.userInfoPath, responseCreator: provider)
        let providerCoordinator = RequestHandlingCoordinator(router: providerRouter)
        let server = BlueSocketSimpleServer()

        do {
            try server.start(port: port, webapp: providerCoordinator.handle)

            let userInfoRequest: OAuth2.UserInfoRequest = { token, tokenType in
                var request = URLRequest(url: URL(string: host + provider.userInfoPath)!)
                request.setValue("\(tokenType) \(token)", forHTTPHeaderField: "Authorization")
                return request
            }

            let sessionInfo = UUID().uuidString
            let redirectPath = "/oauth2/callback"
            let scopes = ["email", "phone", "id"]
            let redirectUrl = URL(string: "http://localhost" + redirectPath)!

            let authorize: OAuth2.Authorize = { json in
                if json[provider.userInfoKey] as? String == provider.userInfo {
                    return .authorized(sessionInfo: sessionInfo)
                } else {
                    return .forbidden
                }
            }

            let setContext: Security.SetContext = { context, info in
                return context.adding(dict: [SecurityTestWebApp.contextKey: info])
            }

            let oauth2 = OAuth2(authorizationUrl: URL(string: host + provider.authPath)!, redirectUrl: redirectUrl,
                                tokenUrl: URL(string: host + provider.tokenPath)!, userInfoRequest: userInfoRequest,
                                clientId: provider.clientId, clientSecret: provider.clientSecret,
                                authorize: authorize, setContext: setContext)

            let path = "/testOauth2"
            let pathWithQuery = path + "?q1=x,y&q2=x:y&q3=x/y"

            let webapp = SecurityTestWebApp()
            var router = Router(security: SecurityOptions(.oauth2(oauth2), scopes: scopes))
            router.add(verb: .GET, path: path, responseCreator: webapp)
            router.add(verb: .GET, path: redirectPath, responseCreator: webapp)
            let coordinator = RequestHandlingCoordinator(router: router)

            var request = HTTPRequest(method: .GET, target: pathWithQuery, httpVersion: (1, 1), headers: HTTPHeaders())
            var resolver = TestResponseResolver(request: request, requestBody: Data())
            resolver.resolveHandler(coordinator.handle)
            XCTAssertNotNil(resolver.response)
            XCTAssertEqual(HTTPResponseStatus.found.code, resolver.response?.status.code ?? 0)

            var location = URLComponents(string: resolver.response?.headers["Location"][0] ?? "")
            let cookie = resolver.response?.headers["Set-Cookie"][0].components(separatedBy: ";")[0]
            var queryParameters = [String: String?]()
            for item in location?.queryItems ?? [] {
                queryParameters[item.name] = item.value
            }
            let state = queryParameters["state"] ?? ""

            XCTAssertEqual(provider.authPath, location?.path)
            XCTAssertEqual("code", queryParameters["response_type"] ?? "")
            XCTAssertEqual(provider.clientId, queryParameters["client_id"] ?? "")
            XCTAssertEqual(redirectUrl.absoluteString, queryParameters["redirect_uri"] ?? "")
            XCTAssertEqual(scopes.joined(separator: " "), queryParameters["scope"] ?? "")
            XCTAssertNotNil(cookie)
            XCTAssertNotNil(state)

            let target = redirectPath + "?code=\(provider.code)&state=\(state ?? "")"
            let headersWithCookies = HTTPHeaders([("Cookie", cookie ?? "")])
            request = HTTPRequest(method: .GET, target: target, httpVersion: (1, 1), headers: headersWithCookies)
            resolver = TestResponseResolver(request: request, requestBody: Data())
            resolver.resolveHandler(coordinator.handle)
            XCTAssertNotNil(resolver.response)
            XCTAssertEqual(HTTPResponseStatus.found.code, resolver.response?.status.code ?? 0)
            XCTAssertEqual(pathWithQuery, resolver.response?.headers["Location"][0])

            request = HTTPRequest(method: .GET, target: pathWithQuery, httpVersion: (1, 1), headers: headersWithCookies)
            resolver = TestResponseResolver(request: request, requestBody: Data())
            resolver.resolveHandler(coordinator.handle)
            XCTAssertNotNil(resolver.response)

            if tokenOk && userInfoOk {
                XCTAssertEqual(HTTPResponseStatus.ok.code, resolver.response?.status.code ?? 0)
                XCTAssertEqual("Hello, \(sessionInfo)!", String(data: resolver.responseBody ?? Data(), encoding: .utf8) ?? "Nil")
            } else {
                XCTAssertEqual(HTTPResponseStatus.unauthorized.code, resolver.response?.status.code ?? 0)
            }

            server.stop()
        } catch {
            XCTFail("Error listening on port \(port): \(error). Use server.failed(callback:) to handle")
        }

    }
}

class SecurityTestWebApp: ResponseCreating {
    static let contextKey = "SecurityTestWebApp"

    func serve(request req: HTTPRequest, context: RequestContext, response res: HTTPResponseWriter ) -> HTTPBodyProcessing {
        res.writeResponse(HTTPResponse(httpVersion: req.httpVersion,
                                       status: .ok,
                                       transferEncoding: .chunked,
                                       headers: HTTPHeaders()))
        return .processBody { (chunk, stop) in
            switch chunk {
            case .chunk(_, let finishedProcessing):
                finishedProcessing()
            case .end:
                res.writeBody(data: "Hello, \(context[SecurityTestWebApp.contextKey] ?? "stranger")!".data(using: .utf8)!) { _ in }
                res.done()
            default:
                stop = true /* don't call us anymore */
                res.abort()
            }
        }
    }
}

class OAuth2Provider: ResponseCreating {
    let authPath  = "/oauth2/auth"
    let tokenPath = "/oauth2/token"
    let userInfoPath = "/oauth2/userinfo"

    let clientId = UUID().uuidString
    let clientSecret = UUID().uuidString
    let code = UUID().uuidString

    let accessToken = UUID().uuidString
    let tokenType = UUID().uuidString

    let userInfoKey = UUID().uuidString
    let userInfo = UUID().uuidString

    let tokenOk: Bool
    let userInfoOk: Bool

    init(tokenOk: Bool, userInfoOk: Bool) {
        self.tokenOk = tokenOk
        self.userInfoOk = userInfoOk
    }

    func serve(request req: HTTPRequest, context: RequestContext, response res: HTTPResponseWriter ) -> HTTPBodyProcessing {
        var status: HTTPResponseStatus
        var body: Data
        do {
            if req.target == tokenPath, tokenOk {
                status = .ok
                body = try JSONSerialization.data(withJSONObject: ["access_token": accessToken, "token_type": tokenType])
            } else if req.target == userInfoPath, userInfoOk {
                status = .ok
                body = try JSONSerialization.data(withJSONObject: [userInfoKey: userInfo])
            } else {
                status = .serviceUnavailable
                body = Data()
            }
        } catch {
            XCTFail("Error serializing body: \(error)")
            status = .internalServerError
            body = Data()
        }

        res.writeResponse(HTTPResponse(httpVersion: req.httpVersion,
                                       status: status,
                                       transferEncoding: .chunked,
                                       headers: HTTPHeaders()))

        return .processBody { (chunk, stop) in
            switch chunk {
            case .chunk(_, let finishedProcessing):
                finishedProcessing()
            case .end:
                res.writeBody(data: body) { _ in }
                res.done()
            default:
                stop = true
                res.abort()
            }
        }
    }
}
