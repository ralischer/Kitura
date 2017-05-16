//
//  HTTPConnectionHandler.swift
//  K2Spike
//
//  Created by Samuel Kallner on 10/05/2017.
//
//

import Foundation
import Dispatch

class HTTPConnectionProcessor: ConnectionProcessor {
    let webapp: WebApp
    let parser: StreamingParser
    
    weak var connectionListener: ConnectionListener?
    
    var writeToConnection: ConnectionWriter? {
        didSet {
            parser.writeToConnection = writeToConnection
        }
    }
    var closeConnection: ConnectionCloser? {
        didSet {
            parser.closeConnection = closeConnection
        }
    }
    
    init(webapp: @escaping WebApp) {
        self.webapp = webapp
        self.parser = StreamingParser(webapp: webapp)
    }
    
    var keepAliveUntil: TimeInterval? {
        return parser.keepAliveUntil
    }
    
    func process(bytes: UnsafePointer<Int8>!, length: Int) -> Int {
        let (numberParsed, isUpgradeRequested) = self.parser.readStream(bytes: bytes, len: length)
        if isUpgradeRequested {
            upgradeConnection()
        }
        return numberParsed
    }
    
    func connectionClosed() {}
    
    private func upgradeConnection() {
        let request = parser.createRequest()
        
        let protocols = request.headers["upgrade"]
        guard protocols.count == 1 else {
            let body = "No protocol specified in the Upgrade header".data(using: .utf8) ?? Data()
            let response = HTTPResponse(httpVersion: (1, 1), status: HTTPResponseStatus.badRequest,
                                        transferEncoding: .identity(contentLength: UInt(body.count)),
                                        headers: HTTPHeaders([("Content-Type", "plain/text")]))
            parser.writeResponse(response)
            parser.writeBody(data: body)
            parser.done()
            
            return
        }
        
        var notFound = true
        let protocolList = protocols.split(separator: ",")
        let registry = ConnectionProcessorCreatorRegistry.instance.registry
        var connectionProcessor: ConnectionProcessor?
        for eachProtocol in protocolList {
            let theProtocol = eachProtocol.first?.trimmingCharacters(in: CharacterSet.whitespaces) ?? ""
            if theProtocol.characters.count != 0, let creator = registry[theProtocol.lowercased()] {
                connectionProcessor = creator.createConnectionProcessor(request: request, responseWriter: parser, webapp: webapp)
                notFound = false
                break
            }
        }
        
        if !notFound {
            if let connectionListener = connectionListener, let unwrappedConnectionProcessor = connectionProcessor {
                connectionProcessor?.closeConnection = closeConnection
                connectionProcessor?.writeToConnection = writeToConnection
                connectionListener.connectionProcessor = unwrappedConnectionProcessor
            }
        }
        else {
            let body = "None of the protocols specified in the Upgrade header are registered".data(using: .utf8) ?? Data()
            let response = HTTPResponse(httpVersion: (1, 1), status: HTTPResponseStatus.notFound,
                                        transferEncoding: .identity(contentLength: UInt(body.count)),
                                        headers: HTTPHeaders([("Content-Type", "plain/text")]))
            parser.writeResponse(response)
            parser.writeBody(data: body)
            parser.done()
        }
    }
}
