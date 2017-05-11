//
//  ConnectionListenerTests.swift
//  K2Spike
//
//  Created by Quan Vo on 5/7/17.
//
//

import XCTest

@testable import K2Spike

import Socket

#if os(Linux)
    import Dispatch
#endif

class ConnectionListenerTests: XCTestCase {
    static var allTests = [
        ("testCleanUpIdleSocket", testCleanUpIdleSocket),
        ("testDontCleanUpIdleSocket", testDontCleanUpIdleSocket)
    ]

    func testCleanUpIdleSocket() throws {
        let expectation = self.expectation(description: #function)

        let keepAliveTimeout = StreamingParser.keepAliveTimeout + 1
        let socket = try Socket.create()
        try socket.listen(on: 0)

        DispatchQueue.global().async {
            repeat {
                do {
                    let newSocket = try socket.acceptClientConnection()
                    let coordinator = RequestHandlingCoordinator.init(router: Router(map: [Path(path:"/helloworld", verb:.GET): HelloWorldWebApp()]))
                    let connectionProcessor = HTTPConnectionProcessor(webapp: coordinator.handle)
                    let connectionListener = ConnectionListener(socket: newSocket, connectionProcessor: connectionProcessor)
                    XCTAssert(connectionListener.socket.isConnected)

                    socket.close()

                    connectionProcessor.parser.done()

                    print("Waiting \(keepAliveTimeout) seconds. cleanIdleSockets timer SHOULD close socket...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int(keepAliveTimeout)), execute: {
                        XCTAssertFalse(connectionListener.socket.isConnected)
                        print("Success")
                        expectation.fulfill()
                    })
                } catch {
                    XCTFail("\(error)")
                }
            } while socket.isListening
        }

        let session = URLSession(configuration: URLSessionConfiguration.default)
        let url = URL(string: "http://localhost:\(socket.listeningPort)/helloworld")!
        let dataTask = session.dataTask(with: url)
        dataTask.resume()

        waitForExpectations(timeout: keepAliveTimeout * 2) { (error) in
            if let error = error {
                XCTFail("\(error)")
            }
        }
    }

    func testDontCleanUpIdleSocket() throws {
        let expectation = self.expectation(description: #function)

        let keepAliveTimeout = StreamingParser.keepAliveTimeout
        let socket = try Socket.create()
        try socket.listen(on: 0)

        DispatchQueue.global().async {
            repeat {
                do {
                    let newSocket = try socket.acceptClientConnection()
                    let coordinator = RequestHandlingCoordinator.init(router: Router(map: [Path(path:"/helloworld", verb:.GET): HelloWorldWebApp()]))
                    let connectionProcessor = HTTPConnectionProcessor(webapp: coordinator.handle)
                    let connectionListener = ConnectionListener(socket: newSocket, connectionProcessor: connectionProcessor)
                    XCTAssert(connectionListener.socket.isConnected)

                    socket.close()

                    print("Waiting 1 second to let connectionListener's timer to start...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1), execute: {
                        print("Setting keepAliveTimeout to 5 seconds from now...")
                        connectionProcessor.parser.clientRequestedKeepAlive = true
                        connectionProcessor.parser.done()
                        XCTAssert(connectionListener.socket.isConnected)

                        print("Waiting \(keepAliveTimeout) seconds. cleanIdleSockets timer should NOT close socket...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int(keepAliveTimeout)), execute: {
                            XCTAssert(connectionListener.socket.isConnected)
                            print("Success")

                            print("Waiting another \(keepAliveTimeout) seconds. cleanIdleSockets timer SHOULD close socket...")
                            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int(keepAliveTimeout)), execute: {
                                XCTAssertFalse(connectionListener.socket.isConnected)
                                print("Success")
                                expectation.fulfill()
                            })
                        })
                    })
                } catch {
                    XCTFail("\(error)")
                }
            } while socket.isListening
        }

        let session = URLSession(configuration: URLSessionConfiguration.default)
        let url = URL(string: "http://localhost:\(socket.listeningPort)/helloworld")!
        let dataTask = session.dataTask(with: url)
        dataTask.resume()
        
        waitForExpectations(timeout: keepAliveTimeout * 3) { (error) in
            if let error = error {
                XCTFail("\(error)")
            }
        }
    }
}
