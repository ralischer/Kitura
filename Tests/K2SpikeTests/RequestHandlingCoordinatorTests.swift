import XCTest
@testable import K2Spike
@testable import SwiftServerHttp

class RequestHandlingCoordinatorTests: XCTestCase {
    func testRouteNotFound() throws {
        let expectation = self.expectation(description: #function)

        var router = Router()
        router.add(verb: .GET, path: "/helloworld", responseCreator: HelloWorldWebApp())

        let coordinator = RequestHandlingCoordinator(router: router)

        let server = BlueSocketSimpleServer()
        try server.start(webapp: coordinator.handle)

        let session = URLSession(configuration: URLSessionConfiguration.default)
        let url = URL(string: "http://localhost:\(server.port)/hello")!
        let dataTask = session.dataTask(with: url) { (responseBody, rawResponse, error) in
            let response = rawResponse as? HTTPURLResponse
            XCTAssertNil(error, "\(error!.localizedDescription)")
            XCTAssertNotNil(response)
            XCTAssertNotNil(responseBody)
            XCTAssertEqual(Int(HTTPResponseStatus.notFound.code), response?.statusCode ?? 0)
            expectation.fulfill()
        }
        dataTask.resume()

        waitForExpectations(timeout: 10) { (error) in
            if let error = error {
                XCTFail("\(error)")
            }
        }

        server.stop()
    }

    func testSkipBodyNoParameters() throws {
        let expectation = self.expectation(description: #function)

        var router = Router()
        router.add(verb: .GET, path: "/{hello}", parameterType: SimpleBodylessParameterContaining.self, responseCreator: SimpleBodylessParameterResponseCreating())

        let coordinator = RequestHandlingCoordinator(router: router)

        let server = BlueSocketSimpleServer()
        try server.start(webapp: coordinator.handle)

        let session = URLSession(configuration: URLSessionConfiguration.default)
        let url = URL(string: "http://localhost:\(server.port)/world")!
        let dataTask = session.dataTask(with: url) { (responseBody, rawResponse, error) in
            let response = rawResponse as? HTTPURLResponse
            XCTAssertNil(error, "\(error!.localizedDescription)")
            XCTAssertNotNil(response)
            XCTAssertNotNil(responseBody)
            XCTAssertEqual(Int(HTTPResponseStatus.notFound.code), response?.statusCode ?? 0)
            expectation.fulfill()
        }
        dataTask.resume()

        waitForExpectations(timeout: 10) { (error) in
            if let error = error {
                XCTFail("\(error)")
            }
        }

        server.stop()
    }
}

private struct SimpleBodylessParameterContaining: BodylessParameterContaining {
    init?(pathParameters: [String : String]?, queryParameters: [URLQueryItem]?, headers: HTTPHeaders) {
        return nil
    }
}

private struct SimpleBodylessParameterResponseCreating: BodylessParameterResponseCreating {
    func serve(request: HTTPRequest, context: RequestContext, parameters: BodylessParameterContaining, response: HTTPResponseWriter) -> HTTPBodyProcessing {
        return .discardBody
    }
}
