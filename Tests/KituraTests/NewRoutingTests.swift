import XCTest

@testable import HTTP
@testable import Kitura

class NewRoutingTests: XCTestCase {
    func testEcho() {
        let testString="This is a test"
        let request = HTTPRequest(method: .post, target:"/echo", httpVersion: HTTPVersion(major: 1,minor: 1), headers: HTTPHeaders())
        let resolver = TestResponseResolver(request: request, requestBody: testString.data(using: .utf8)!)
        var router = Router2()
        router.add(verb: .POST, path: "/echo", delegate: Echoer())
        let coordinator = RouteDispatcher(router: router)
        resolver.resolveHandler(coordinator.handle)

        XCTAssertNotNil(resolver.response)
        XCTAssertNotNil(resolver.responseBody)
        XCTAssertEqual(HTTPResponseStatus.ok.code, resolver.response?.status.code ?? 0)
        XCTAssertEqual(testString, resolver.responseBody?.withUnsafeBytes { String(bytes: $0, encoding: .utf8) } ?? "Nil")
    }
}

class Echoer: ProcessingDelegate {
    func process(_ input: (request: HTTPRequest, response: HTTPResponseWriter)) -> HTTPBodyProcessing {
        let (_, response) = input

        response.writeHeader(status: .ok, headers: [.transferEncoding: "chunked"])
        return .processBody { (chunk, stop) in
            switch chunk {
            case .chunk(let data, let finishedProcessing):
                response.writeBody(data) { _ in
                    finishedProcessing()
                }
            case .end:
                response.done()
            default:
                stop = true /* don't call us anymore */
                response.abort()
            }
        }
    }
}
