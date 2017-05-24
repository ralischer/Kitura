#if os(macOS) && swift(>=4)
    import Foundation
    import XCTest
    @testable import K2Spike

    import HTTPSketch

    class CodableTests: XCTestCase {
        func testCodable() throws {
            let user = User(id: UUID().uuidString, name: "Mario", address: Address(number: 123, street: "Mushroom St", type: .apartment))

            print("example struct: \(user)")

            let testUserData = try JSONEncoder().encode(user)
            print("encoded: \(String(describing: String(data: testUserData, encoding: .utf8)))")

            let decoded = try JSONDecoder().decode(User.self, from: testUserData)
            print("decoded: \(decoded)")

            XCTAssertEqual(user, decoded)
        }

        func testCache() throws {
            let expectation = self.expectation(description: "\(#function)")

            let path = Path(path: "/user/mario", verb: .GET)
            let cacheKey = (path.verb.rawValue + path.path) as AnyObject
            let cacheWebApp = CacheWebApp()
            var router = Router()
            router.add(verb: .GET, path: path.path, responseCreator: cacheWebApp)
            let coordinator = RequestHandlingCoordinator(router: router)
            let server = BlueSocketSimpleServer()
            try server.start(port: 0, webapp: coordinator.handle)

            let session = URLSession(configuration: URLSessionConfiguration.default)
            let url = URL(string: "http://localhost:\(server.port)\(path.path)")!

            session.dataTask(with: url) { (responseBody, rawResponse, error) in
                let response = rawResponse as? HTTPURLResponse
                XCTAssertNil(error, "\(error!.localizedDescription)")
                XCTAssertNotNil(response)
                XCTAssertNotNil(responseBody)
                XCTAssertEqual(Int(HTTPResponseStatus.ok.code), response?.statusCode ?? 0)

                let cachedData = cacheWebApp.cache.object(forKey: cacheKey)
                XCTAssertNotNil(cachedData)
                XCTAssertEqual(cachedData as? Data, responseBody)

                do {
                    let user1 = try JSONDecoder().decode(User.self, from: responseBody!)

                    // Make request again
                    session.dataTask(with: url) { (responseBody, rawResponse, error) in
                        let response = rawResponse as? HTTPURLResponse
                        XCTAssertNil(error, "\(error!.localizedDescription)")
                        XCTAssertNotNil(response)
                        XCTAssertNotNil(responseBody)
                        XCTAssertEqual(Int(HTTPResponseStatus.ok.code), response?.statusCode ?? 0)

                        let cachedData = cacheWebApp.cache.object(forKey: cacheKey)
                        XCTAssertNotNil(cachedData)
                        XCTAssertEqual(cachedData as? Data, responseBody)

                        do {
                            let user2 = try JSONDecoder().decode(User.self, from: responseBody!)
                            XCTAssertEqual(user1, user2)

                            expectation.fulfill()

                        } catch {
                            XCTFail("\(error)")
                        }
                        }.resume()

                } catch {
                    XCTFail("\(error)")
                }
                }.resume()
            
            self.waitForExpectations(timeout: 10) { (error) in
                if let error = error {
                    XCTFail("\(error)")
                }
            }
            
            server.stop()
        }
    }
#endif
