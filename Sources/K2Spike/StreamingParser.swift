//
//  StreamingParser.swift
//  K2Spike
//
//  Created by Carl Brown on 5/4/17.
//
//

import Foundation
import Dispatch

import LoggerAPI

import CHttpParser

public class StreamingParser: HTTPResponseWriter {

    let webapp : WebApp
    
    static let keepAliveTimeout: TimeInterval = 5
    var clientRequestedKeepAlive = false
    var keepAliveUntil: TimeInterval?

    let maxRequests = 100

    var parserBuffer: DispatchData?

    ///HTTP Parser
    var httpParser = http_parser()
    var httpParserSettings = http_parser_settings()
    
    var httpBodyProcessingCallback: HTTPBodyProcessing?
    
    var writeToConnection: ConnectionWriter?
    var closeConnection: ConnectionCloser?

    public init(webapp: @escaping WebApp) {
        self.webapp = webapp
        
        httpParserSettings.on_message_begin = {
            parser -> Int32 in
            guard let listener = StreamingParser.getSelf(parser: parser) else {
                return Int32(0)
            }
            return listener.messageBegan()
        }
        
        httpParserSettings.on_message_complete = {
            parser -> Int32 in
            guard let listener = StreamingParser.getSelf(parser: parser) else {
                return Int32(0)
            }
            return listener.messageCompleted()
        }
        
        httpParserSettings.on_headers_complete = {
            parser -> Int32 in
            guard let listener = StreamingParser.getSelf(parser: parser) else {
                return Int32(0)
            }
            return listener.headersCompleted()
        }
        
        httpParserSettings.on_header_field = {
            (parser, chunk, length) -> Int32 in
            guard let listener = StreamingParser.getSelf(parser: parser) else {
                return Int32(0)
            }
            return listener.headerFieldReceived(data: chunk, length: length)
        }
        
        httpParserSettings.on_header_value = {
            (parser, chunk, length) -> Int32 in
            guard let listener = StreamingParser.getSelf(parser: parser) else {
                return Int32(0)
            }
            return listener.headerValueReceived(data: chunk, length: length)
        }
        
        httpParserSettings.on_body = {
            (parser, chunk, length) -> Int32 in
            guard let listener = StreamingParser.getSelf(parser: parser) else {
                return Int32(0)
            }
            return listener.bodyReceived(data: chunk, length: length)
        }
        
        httpParserSettings.on_url = {
            (parser, chunk, length) -> Int32 in
            guard let listener = StreamingParser.getSelf(parser: parser) else {
                return Int32(0)
            }
            return listener.urlReceived(data: chunk, length: length)
        }
        http_parser_init(&httpParser, HTTP_REQUEST)
        
        self.httpParser.data = Unmanaged.passUnretained(self).toOpaque()
        
    }
    
    public func readStream(bytes: UnsafePointer<Int8>!, len: Int) -> (Int, Bool) {
        let numberParsed = http_parser_execute(&self.httpParser, &self.httpParserSettings, bytes, len)
        let isUpgradeRequest = get_upgrade_value(&self.httpParser) == 1
        return (numberParsed, isUpgradeRequest)
    }
    
    enum CallbackRecord {
        case idle, messageBegan, messageCompleted, headersCompleted, headerFieldReceived, headerValueReceived, bodyReceived, urlReceived
    }
    var lastCallBack = CallbackRecord.idle
    var lastHeaderName: String?
    var parsedHeaders = HTTPHeaders()
    var parsedHTTPMethod: HTTPMethod?
    var parsedHTTPVersion: HTTPVersion?
    var parsedURL: URL?
    
    @discardableResult
    func processCurrentCallback(_ currentCallBack:CallbackRecord) -> Bool {
        Log.verbose("\(#function) called from \(lastCallBack) to \(currentCallBack)")

        if lastCallBack == currentCallBack {
            return false
        }
        switch lastCallBack {
        case .headerFieldReceived:
            if let parserBuffer = self.parserBuffer {
                self.lastHeaderName = String(data: Data(parserBuffer), encoding: .utf8)
                self.parserBuffer=nil
            } else {
                Log.error("Missing parserBuffer after \(lastCallBack)")
            }
        case .headerValueReceived:
            if let parserBuffer = self.parserBuffer, let lastHeaderName = self.lastHeaderName, let headerValue = String(data: Data(parserBuffer), encoding: .utf8) {
                self.parsedHeaders.append(newHeader: (lastHeaderName, headerValue))
                self.lastHeaderName = nil
                self.parserBuffer=nil
            } else {
                Log.error("Missing parserBuffer after \(lastCallBack)")
            }
        case .headersCompleted:
            let methodId = self.httpParser.method
            if let methodName = http_method_str(http_method(rawValue: methodId)) {
                self.parsedHTTPMethod = HTTPMethod(rawValue: String(validatingUTF8: methodName) ?? "GET")
            }
            self.parsedHTTPVersion = (Int(self.httpParser.http_major), Int(self.httpParser.http_minor))
            
            self.parserBuffer=nil
            
            if 0 == get_upgrade_value(&self.httpParser) {
                self.httpBodyProcessingCallback = self.webapp(createRequest(), self)
            }
        case .urlReceived:
            if let parserBuffer = self.parserBuffer {
                if let urlString = String(data: Data(parserBuffer), encoding: .utf8) {
                    self.parsedURL = URL(string: urlString)
                }
                self.parserBuffer=nil
            } else {
                Log.error("Missing parserBuffer after \(lastCallBack)")
            }
        case .idle:
            break
        case .messageBegan:
            break
        case .messageCompleted:
            break
        case .bodyReceived:
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
        Log.debug("\(#function) called")
        
        let didChangeState = processCurrentCallback(.messageCompleted)
        if let chunkHandler = self.httpBodyProcessingCallback, didChangeState {
            var stop=false
            switch chunkHandler {
            case .processBody(let handler):
                handler(.end, &stop)
            case .discardBody:
                break
            }
        }
        return 0
    }
    
    func headersCompleted() -> Int32 {
        processCurrentCallback(.headersCompleted)
        //This needs to be set here and not messageCompleted if it's going to work here
        self.clientRequestedKeepAlive = (http_should_keep_alive(&httpParser) == 1)
        self.keepAliveUntil = Date(timeIntervalSinceNow: StreamingParser.keepAliveTimeout).timeIntervalSinceReferenceDate
        return 0
    }
    
    func headerFieldReceived(data: UnsafePointer<Int8>?, length: Int) -> Int32 {
        processCurrentCallback(.headerFieldReceived)
        guard let data = data else { return 0 }
        data.withMemoryRebound(to: UInt8.self, capacity: length) { (ptr) -> Void in
            let buff = UnsafeBufferPointer<UInt8>(start: ptr, count: length)
            self.parserBuffer == nil ? self.parserBuffer = DispatchData(bytes:buff) : self.parserBuffer?.append(buff)
        }
        return 0
    }
    
    func headerValueReceived(data: UnsafePointer<Int8>?, length: Int) -> Int32 {
        processCurrentCallback(.headerValueReceived)
        guard let data = data else { return 0 }
        data.withMemoryRebound(to: UInt8.self, capacity: length) { (ptr) -> Void in
            let buff = UnsafeBufferPointer<UInt8>(start: ptr, count: length)
            self.parserBuffer == nil ? self.parserBuffer = DispatchData(bytes:buff) : self.parserBuffer?.append(buff)
        }
        return 0
    }
    
    func bodyReceived(data: UnsafePointer<Int8>?, length: Int) -> Int32 {
        Log.info("\(#function) called")
        processCurrentCallback(.bodyReceived)
        guard let data = data else { return 0 }
        data.withMemoryRebound(to: UInt8.self, capacity: length) { (ptr) -> Void in
            let buff = UnsafeBufferPointer<UInt8>(start: ptr, count: length)
            let chunk = DispatchData(bytes:buff)
            if let chunkHandler = self.httpBodyProcessingCallback {
                var stop=false
                var finished=false
                while !stop && !finished {
                    switch chunkHandler {
                    case .processBody(let handler):
                        handler(.chunk(data: chunk, finishedProcessing: {
                            finished=true
                        }), &stop)
                    case .discardBody:
                        finished=true
                    }
                }
            }
        }
        return 0
    }
    
    func urlReceived(data: UnsafePointer<Int8>?, length: Int) -> Int32 {
        processCurrentCallback(.urlReceived)
        guard let data = data else { return 0 }
        data.withMemoryRebound(to: UInt8.self, capacity: length) { (ptr) -> Void in
            let buff = UnsafeBufferPointer<UInt8>(start: ptr, count: length)
            self.parserBuffer == nil ? self.parserBuffer = DispatchData(bytes:buff) : self.parserBuffer?.append(buff)
        }
        return 0
    }
    
    static func getSelf(parser: UnsafeMutablePointer<http_parser>?) -> StreamingParser? {
        guard let pointee = parser?.pointee.data else { return nil }
        return Unmanaged<StreamingParser>.fromOpaque(pointee).takeUnretainedValue()
    }
    
    var headersWritten = false
    var isChunked = false
    
    func createRequest() -> HTTPRequest {
        return HTTPRequest(method: self.parsedHTTPMethod!, target:self.parsedURL!.path, httpVersion: self.parsedHTTPVersion!, headers: self.parsedHeaders)
    }
    
    public func writeContinue(headers: HTTPHeaders?) /* to send an HTTP `100 Continue` */ {
        var status = "HTTP/1.1 \(HTTPResponseStatus.continue.code) \(HTTPResponseStatus.continue.reasonPhrase)\r\n"
        if let headers = headers {
            for (key, value) in headers.makeIterator() {
                status += "\(key): \(value)\r\n"
            }
        }
        status += "\r\n"
        
        // TODO use requested encoding if specified
        if let data = status.data(using: .utf8) {
            data.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
                self.writeToConnection?(DispatchData(bytes: UnsafeBufferPointer(start: ptr, count: data.count)))
            }
        } else {
            //TODO handle encoding error
        }
    }
    
    public func writeResponse(_ response: HTTPResponse) {
        guard !headersWritten else {
            return
        }
        
        var headers = "HTTP/1.1 \(response.status.code) \(response.status.reasonPhrase)\r\n"
        
        switch(response.transferEncoding) {
        case .chunked:
            headers += "Transfer-Encoding: chunked\r\n"
            isChunked = true
        case .identity(let contentLength):
            headers += "Content-Length: \(contentLength)\r\n"
        }
        
        for (key, value) in response.headers.makeIterator() {
            headers += "\(key): \(value)\r\n"
        }
        
            if  clientRequestedKeepAlive {
                headers.append("Connection: Keep-Alive\r\n")
                headers.append("Keep-Alive: timeout=\(Int(StreamingParser.keepAliveTimeout)), max=\(maxRequests)\r\n")
            }
            else {
                headers.append("Connection: Close\r\n")
            }
        headers.append("\r\n")
        
        Log.debug("\(#function) about to write '\(headers)'")

        // TODO use requested encoding if specified
        if let data = headers.data(using: .utf8) {
            data.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
                self.writeToConnection?(DispatchData(bytes: UnsafeBufferPointer(start: ptr, count: data.count)))
            }
            headersWritten = true
        } else {
            //TODO handle encoding error
        }
    }
    
    public func writeTrailer(key: String, value: String) {
        fatalError("Not implemented")
    }
    
    public func writeBody(data: DispatchData, completion: @escaping (Result<POSIXError, ()>) -> Void) {
        if Log.isLogging(.debug) {
            let bodyString=String(data:Data(data),encoding:.utf8)!
            Log.debug("\(#function) about to write '\(bodyString)'")
        }

        guard headersWritten else {
            //TODO error or default headers?
            return
        }
        
        guard data.count > 0 else {
            // TODO fix Result
            completion(Result(completion: ()))
            return
        }
        
        var dataToWrite: DispatchData!
        if isChunked {
            let chunkStart = (String(data.count, radix: 16) + "\r\n").data(using: .utf8)!
            chunkStart.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
                dataToWrite = DispatchData(bytes: UnsafeBufferPointer<UInt8>(start: ptr, count: chunkStart.count))
            }
            
            dataToWrite.append(data)
            
            let chunkEnd = "\r\n".data(using: .utf8)!
            chunkEnd.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
                dataToWrite.append(ptr, count: chunkEnd.count)
            }
        } else {
            dataToWrite = data
        }
        
        self.writeToConnection?(dataToWrite)
        
        completion(Result(completion: ()))
    }
    
    public func writeBody(data: DispatchData) /* convenience */ {
        writeBody(data: data) { _ in
            
        }
    }
    
    public func writeBody(data: Data, completion: @escaping (Result<POSIXError, ()>) -> Void) {
        if Log.isLogging(.debug) {
            let bodyString=String(data:Data(data),encoding:.utf8)!
            Log.debug("\(#function) called with '\(bodyString)'")
        }

        guard headersWritten else {
            //TODO error or default headers?
            return
        }
        
        guard data.count > 0 else {
            // TODO fix Result
            completion(Result(completion: ()))
            return
        }
        
        var dataToWrite: DispatchData!
        if isChunked {
            let chunkStart = (String(data.count, radix: 16) + "\r\n").data(using: .utf8)!
            chunkStart.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
                dataToWrite = DispatchData(bytes: UnsafeBufferPointer<UInt8>(start: ptr, count: chunkStart.count))
            }
            
            data.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
                dataToWrite.append(ptr, count: data.count)
            }
            
            let chunkEnd = "\r\n".data(using: .utf8)!
            chunkEnd.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
                dataToWrite.append(ptr, count: chunkEnd.count)
            }
        } else {
            data.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
                dataToWrite = DispatchData(bytes: UnsafeBufferPointer<UInt8>(start: ptr, count: data.count))
            }
        }
        
        if Log.isLogging(.debug) {
            let bodyString2=String(data:Data(dataToWrite),encoding:.utf8)!
            Log.debug("\(#function) called with '\(bodyString2)'")
        }
        self.writeToConnection?(dataToWrite)
        
        completion(Result(completion: ()))
    }
    
    public func writeBody(data: Data) /* convenience */ {
        writeBody(data: data) { _ in
            
        }
    }
    
    public func done(completion: @escaping (Result<POSIXError, ()>) -> Void) {
        if isChunked {
            let chunkTerminate = "0\r\n\r\n".data(using: .utf8)!
            chunkTerminate.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
                self.writeToConnection?(DispatchData(bytes: UnsafeBufferPointer<UInt8>(start: ptr, count: chunkTerminate.count)))
            }

        }
        
        if clientRequestedKeepAlive {
            keepAliveUntil = Date(timeIntervalSinceNow:StreamingParser.keepAliveTimeout).timeIntervalSinceReferenceDate
            self.parsedHTTPMethod = nil
            self.parsedURL=nil
            self.parsedHeaders = HTTPHeaders()
            self.lastHeaderName = nil
            self.parserBuffer = nil
            self.parsedHTTPMethod = nil
            self.parsedHTTPVersion = nil
            self.lastCallBack = .idle
            self.headersWritten = false
        } else {
            self.closeConnection?()
        }
        
        completion(Result(completion: ()))
    }
    
    public func done() /* convenience */ {
        done() { _ in
        }
    }
    
    public func abort() {
        fatalError("abort called, not sure what to do with it")
    }

}
