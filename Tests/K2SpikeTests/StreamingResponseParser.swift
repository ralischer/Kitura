//
//  StreamingResponseParser.swift
//  K2Spike
//
//  Created by Samuel Kallner on 18/05/2017.
//
//

import Foundation

//
//  StreamingParser.swift
//  HTTPSketch
//
//  Created by Carl Brown on 5/4/17.
//
//

import Foundation
import Dispatch

import CHttpParser
import SwiftServerHttp

/// Class that wraps the CHTTPParser and calls the `WebApp` to get the response
class StreamingResponseParser {
    
    /// Flag to track if the server enabled the sending of multiple requests on the same TCP connection
    var serverEnabledKeepAlive = false
    
    /// Holds the bytes that come from the CHTTPParser until we have enough of them to do something with it
    var parserBuffer: Data?
    
    ///HTTP Parser
    var httpParser = http_parser()
    var httpParserSettings = http_parser_settings()
    
    var lastCallBack = CallbackRecord.idle
    var lastHeaderName: String?
    var parsedHeaders = HTTPHeaders()
    var parsedHTTPMethod: HTTPMethod?
    var parsedHTTPVersion: HTTPVersion?
    var dummyString: String?
    
    /// Is the currently parsed request an upgrade request?
    var upgradeRequested: Bool { return get_upgrade_value(&self.httpParser) == 1 }
    
    /// Class that wraps the CHTTPParser for responses used in the connection upgrade tests
    init() {
        
        //Set up all the callbacks for the CHTTPParser library
        httpParserSettings.on_message_begin = { parser -> Int32 in
            guard let listener = StreamingResponseParser.getSelf(parser: parser) else {
                return Int32(0)
            }
            return listener.messageBegan()
        }
        
        httpParserSettings.on_message_complete = { parser -> Int32 in
            guard let listener = StreamingResponseParser.getSelf(parser: parser) else {
                return Int32(0)
            }
            return listener.messageCompleted()
        }
        
        httpParserSettings.on_headers_complete = { parser -> Int32 in
            guard let listener = StreamingResponseParser.getSelf(parser: parser) else {
                return Int32(0)
            }
            return listener.headersCompleted()
        }
        
        httpParserSettings.on_header_field = { (parser, chunk, length) -> Int32 in
            guard let listener = StreamingResponseParser.getSelf(parser: parser) else {
                return Int32(0)
            }
            return listener.headerFieldReceived(data: chunk, length: length)
        }
        
        httpParserSettings.on_header_value = { (parser, chunk, length) -> Int32 in
            guard let listener = StreamingResponseParser.getSelf(parser: parser) else {
                return Int32(0)
            }
            return listener.headerValueReceived(data: chunk, length: length)
        }
        
        httpParserSettings.on_body = { (parser, chunk, length) -> Int32 in
            return Int32(0)
        }
        
        httpParserSettings.on_url = { (parser, chunk, length) -> Int32 in
            return Int32(0)
        }
        
        http_parser_init(&httpParser, HTTP_RESPONSE)
        
        self.httpParser.data = Unmanaged.passUnretained(self).toOpaque()
        
    }
    
    /// Read a stream from the network, pass it to the parser and return number of bytes consumed
    ///
    /// - Parameter data: data coming from network
    /// - Returns: number of bytes that we sent to the parser
    func readStream(data:Data) -> Int {
        return data.withUnsafeBytes { (ptr) -> Int in
            return http_parser_execute(&self.httpParser, &self.httpParserSettings, ptr, data.count)
        }
    }
    
    /// States to track where we are in parsing the HTTP Stream from the client
    enum CallbackRecord {
        case idle, messageBegan, messageCompleted, headersCompleted, headerFieldReceived, headerValueReceived
    }
    
    /// Process change of state as we get more and more parser callbacks
    ///
    /// - Parameter currentCallBack: state we are entering, as specified by the CHTTPParser
    /// - Returns: Whether or not the state actually changed
    @discardableResult
    func processCurrentCallback(_ currentCallBack:CallbackRecord) -> Bool {
        if lastCallBack == currentCallBack {
            return false
        }
        switch lastCallBack {
        case .headerFieldReceived:
            if let parserBuffer = self.parserBuffer {
                self.lastHeaderName = String(data: parserBuffer, encoding: .utf8)
                self.parserBuffer=nil
            } else {
                print("Missing parserBuffer after \(lastCallBack)")
            }
        case .headerValueReceived:
            if let parserBuffer = self.parserBuffer, let lastHeaderName = self.lastHeaderName, let headerValue = String(data:parserBuffer, encoding: .utf8) {
                self.parsedHeaders.append(newHeader: (lastHeaderName, headerValue))
                self.lastHeaderName = nil
                self.parserBuffer=nil
            } else {
                print("Missing parserBuffer after \(lastCallBack)")
            }
        case .headersCompleted:
            let methodId = self.httpParser.method
            if let methodName = http_method_str(http_method(rawValue: methodId)) {
                self.parsedHTTPMethod = HTTPMethod(rawValue: String(validatingUTF8: methodName) ?? "GET")
            }
            self.parsedHTTPVersion = (Int(self.httpParser.http_major), Int(self.httpParser.http_minor))
            
            self.parserBuffer=nil
        case .idle:
            break
        case .messageBegan:
            break
        case .messageCompleted:
            break
        }
        lastCallBack = currentCallBack
        return true
    }
    
    func messageBegan() -> Int32 {
        processCurrentCallback(.messageBegan)
        return 0
    }
    
    func messageCompleted() -> Int32 {
        processCurrentCallback(.messageCompleted)
        return 0
    }
    
    func headersCompleted() -> Int32 {
        processCurrentCallback(.headersCompleted)
        //This needs to be set here and not messageCompleted if it's going to work here
        self.serverEnabledKeepAlive = (http_should_keep_alive(&httpParser) == 1)
        
        return 0
    }
    
    func headerFieldReceived(data: UnsafePointer<Int8>?, length: Int) -> Int32 {
        processCurrentCallback(.headerFieldReceived)
        guard let data = data else { return 0 }
        data.withMemoryRebound(to: UInt8.self, capacity: length) { (ptr) -> Void in
            self.parserBuffer == nil ? self.parserBuffer = Data(bytes:data, count:length) : self.parserBuffer?.append(ptr, count:length)
        }
        return 0
    }
    
    func headerValueReceived(data: UnsafePointer<Int8>?, length: Int) -> Int32 {
        processCurrentCallback(.headerValueReceived)
        guard let data = data else { return 0 }
        data.withMemoryRebound(to: UInt8.self, capacity: length) { (ptr) -> Void in
            self.parserBuffer == nil ? self.parserBuffer = Data(bytes:data, count:length) : self.parserBuffer?.append(ptr, count:length)
        }
        return 0
    }
    
    static func getSelf(parser: UnsafeMutablePointer<http_parser>?) -> StreamingResponseParser? {
        guard let pointee = parser?.pointee.data else { return nil }
        return Unmanaged<StreamingResponseParser>.fromOpaque(pointee).takeUnretainedValue()
    }
    
    func createResponse() -> HTTPResponse {
        let parsedHTTPVersion = (Int(httpParser.http_major), Int(httpParser.http_minor))
        let rawStatusCode = httpParser.status_code
        let statusCode = HTTPResponseStatus.from(code: UInt16(rawStatusCode)) ?? HTTPResponseStatus.serviceUnavailable
        
        return HTTPResponse(httpVersion: parsedHTTPVersion, status: statusCode,
                            transferEncoding: .chunked,     headers: parsedHeaders)
    }
}
