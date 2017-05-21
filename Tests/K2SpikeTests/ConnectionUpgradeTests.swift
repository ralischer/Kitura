//
//  ConnectionUpgradeTests.swift
//  K2Spike
//
//  Created by Samuel Kallner on 14/05/2017.
//
//

import Foundation
import XCTest

import HTTPSketch

import CHttpParser
import HeliumLogger
import Socket

@testable import K2Spike

class ConnectionUpgradeTests: XCTestCase {
    static var allTests = [
        ("testMissingUpgradeHeader", testMissingUpgradeHeader),
        ("testNoRegistrations", testNoRegistrations),
        ("testWrongRegistration", testWrongRegistration)
    ]
    
    static let messageToProtocol: [UInt8] = [0x04, 0xa0, 0xb0, 0xc0, 0xd0]
    static let messageFromProtocol: [UInt8] = [0x10, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f]
    
    func testMissingUpgradeHeader() {
        HeliumLogger.use(.info)
        
        let server = HTTPSimpleServer()
        do {
            try server.start(port: 0, webapp: upgradeTestsWebApp)
            
            let socket = try Socket.create()
            try socket.connect(to: "localhost", port: Int32(server.port))
            
            let request = "GET /test/upgrade HTTP/1.1\r\n" +
                "Host: localhost:\(server.port)\r\n" +
                "Connection: Upgrade\r\n" +
                "\r\n"
            
            guard let data = request.data(using: .utf8) else { return }
            
            try socket.write(from: data)
            
            let (rawResponse, _) = processUpgradeResponse(socket: socket)
            
            guard let response = rawResponse else { return }
            
            XCTAssertEqual(response.status, HTTPResponseStatus.ok, "The status code if the response wasn't \(HTTPResponseStatus.ok), it was \(response.status)")
            
            server.stop()
        } catch {
            XCTFail("Error listening on port \(0): \(error). Use server.failed(callback:) to handle")
        }
    }
    
    func testNoRegistrations() {
        ConnectionProcessorCreatorRegistry.clear()
        
        unregisteredProtocolHelper()
    }
    
    func testSuccessfullUpgrade() {
        ConnectionProcessorCreatorRegistry.clear()
        ConnectionProcessorCreatorRegistry.register(creator: TestingConnectionProcessorCreator())
        
        HeliumLogger.use(.info)
        
        let server = HTTPSimpleServer()
        do {
            try server.start(port: 0, webapp: upgradeTestsWebApp)
            
            guard let socket = self.sendUpgradeRequest(forProtocol: "Testing", on: server.port) else { return }
            
            let (rawResponse, _) = self.processUpgradeResponse(socket: socket)
            
            guard let response = rawResponse else { return }
            
            XCTAssertEqual(response.status, HTTPResponseStatus.switchingProtocols, "Returned status code on upgrade request was \(response.status) and not \(HTTPResponseStatus.switchingProtocols)")
            
            do {
                try socket.write(from: NSData(bytes: ConnectionUpgradeTests.messageToProtocol, length: ConnectionUpgradeTests.messageToProtocol.count))
            }
            catch {
                XCTFail("Failed to send message to TestingProtocol. Error=\(error)")
            }
            
            do {
                let buffer = NSMutableData()
                let bytesRead = try socket.read(into: buffer)
                
                XCTAssertEqual(bytesRead, ConnectionUpgradeTests.messageFromProtocol.count, "Message sent by testing protocol wasn't the correct length")
                
                socket.close()
            }
            catch {
                XCTFail("Failed to receive message from TestingProtocol. Error=\(error)")
            }
            
            server.stop()
        } catch {
            XCTFail("Error listening on port \(0): \(error). Use server.failed(callback:) to handle")
        }
    }
    
    func testWrongRegistration() {
        ConnectionProcessorCreatorRegistry.clear()
        ConnectionProcessorCreatorRegistry.register(creator: TestingConnectionProcessorCreator())
        
        unregisteredProtocolHelper()
    }
    
    private func unregisteredProtocolHelper() {
        HeliumLogger.use(.info)
        
        let server = HTTPSimpleServer()
        do {
            try server.start(port: 0, webapp: upgradeTestsWebApp)
            
            guard let socket = self.sendUpgradeRequest(forProtocol: "testing123", on: server.port) else { return }
            
            let (rawResponse, _) = self.processUpgradeResponse(socket: socket)
            
            guard let response = rawResponse else { return }
            
            XCTAssertEqual(response.status, HTTPResponseStatus.notFound, "Returned status code on upgrade request was \(response.status) and not \(HTTPResponseStatus.notFound)")
            
            server.stop()
        } catch {
            XCTFail("Error listening on port \(0): \(error). Use server.failed(callback:) to handle")
        }
    }
    
    private func sendUpgradeRequest(forProtocol: String, on port: Int) -> Socket? {
        var socket: Socket?
        do {
            socket = try Socket.create()
            try socket?.connect(to: "localhost", port: Int32(port))
            
            let request = "GET /test/upgrade HTTP/1.1\r\n" +
                "Host: localhost:\(port)\r\n" +
                "Upgrade: " + forProtocol + "\r\n" +
                "Connection: Upgrade\r\n" +
                "\r\n"
            
            guard let data = request.data(using: .utf8) else { return nil }
            
            try socket?.write(from: data)
        }
        catch let error {
            socket = nil
            XCTFail("Failed to send upgrade request. Error=\(error)")
        }
        return socket
    }
    
    private func processUpgradeResponse(socket: Socket) -> (HTTPResponse?, Data?) {
        var response: HTTPResponse?
        var unparsedData: Data?
        
        let parser = StreamingResponseParser()
        
        var keepProcessing = true
        var notFoundEof = true
        var buffer = Data()
        var bufferPosition = 0
        
        do {
            while keepProcessing {
                let count = try socket.read(into: &buffer)
                
                if notFoundEof {
                    let unprocessedDataRange: Range<Data.Index> = bufferPosition..<buffer.count
                    let numberParsed = parser.readStream(data: buffer.subdata(in: unprocessedDataRange))
                    bufferPosition += numberParsed
                    
                    if parser.lastCallBack == .messageCompleted || parser.lastCallBack == .headersCompleted {
                        keepProcessing = false
                        if bufferPosition != buffer.count {
                            let unprocessedDataRange: Range<Data.Index> = bufferPosition..<buffer.count
                            unparsedData = buffer.subdata(in: unprocessedDataRange)
                            response = parser.createResponse()
                        }
                    }
                    else {
                        notFoundEof = count != 0
                    }
                }
                else {
                    keepProcessing = false
                    XCTFail("Server closed socket prematurely")
                }
            }
        }
        catch let error {
            XCTFail("Failed to receive upgrade response. Error=\(error)")
        }
        return (response, unparsedData)
    }
    
    class TestingConnectionProcessorCreator: ConnectionProcessorCreator {
        public var name = "Testing"
        
        public func createConnectionProcessor(request: HTTPRequest, responseWriter: HTTPResponseWriter, webapp: WebApp) -> ConnectionProcessor? {
            
            let response = HTTPResponse(httpVersion: (1, 1), status: HTTPResponseStatus.switchingProtocols,
                                        transferEncoding: .identity(contentLength: UInt(0)),
                                        headers: HTTPHeaders([("Upgrade", name), ("Connection", "Upgrade")]))
            responseWriter.writeResponse(response)
            responseWriter.done()
            
            return TestingConnectionProcessor()
        }
    }
    
    class TestingConnectionProcessor: ConnectionProcessor {
        public weak var connectionListener: ConnectionListener?
        public var parserConnector: ParserConnecting?
        
        public var keepAliveUntil: TimeInterval? { return 60.0 }
        
        public func process(data: Data) -> Int {
            
            XCTAssertEqual(data.count, ConnectionUpgradeTests.messageToProtocol.count, "Message received by testing protocol wasn't the correct length")
            
            let dataToWrite = Data(bytes: ConnectionUpgradeTests.messageFromProtocol, count: ConnectionUpgradeTests.messageFromProtocol.count)
            parserConnector?.queueSocketWrite(dataToWrite)
            
            return data.count
        }
        
        public func connectionClosed() {}
    }
    
    private func upgradeTestsWebApp(request: HTTPRequest, responseWriter: HTTPResponseWriter) -> HTTPBodyProcessing {
        let body = "WebApp invoked".data(using: .utf8) ?? Data()
        let response = HTTPResponse(httpVersion: (1, 1), status: HTTPResponseStatus.ok,
                                    transferEncoding: .identity(contentLength: UInt(body.count)),
                                    headers: HTTPHeaders([("Content-Type", "plain/text")]))
        responseWriter.writeResponse(response)
        responseWriter.writeBody(data: body)
        responseWriter.done()
        
        return .discardBody
    }
}
