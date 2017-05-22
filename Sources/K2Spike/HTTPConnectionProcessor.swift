//
//  HTTPConnectionHandler.swift
//  K2Spike
//
//  Created by Samuel Kallner on 10/05/2017.
//
//

import Foundation
import Dispatch
import HTTPSketch

class HTTPConnectionProcessor: ConnectionProcessing {
    let webapp: WebApp
    let parser: StreamingParser
    
    public weak var connectionListener: ConnectionListener?
    
    public var parserConnector: ParserConnecting?  {
        didSet {
            parser.parserConnector = parserConnector
        }
    }
    
    init(webapp: @escaping WebApp) {
        self.webapp = webapp
        self.parser = StreamingParser(webapp: webapp)
    }
    
    func process(data: Data) -> Int {
        let numberParsed = parser.readStream(data: data)
        if parser.upgradeRequested {
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
            parserConnector?.responseComplete()
            
            return
        }
        
        var notFound = true
        let protocolList = protocols.split(separator: ",")
        let registry = ConnectionProcessingCreatingRegistry.instance.registry
        var connectionProcessor: ConnectionProcessing?
        for eachProtocol in protocolList {
            let theProtocol = eachProtocol.first?.trimmingCharacters(in: CharacterSet.whitespaces) ?? ""
            if theProtocol.characters.count != 0, let creator = registry[theProtocol.lowercased()] {
                connectionProcessor = creator.createConnectionProcessor(request: request, responseWriter: parser, webapp: webapp)
                notFound = false
                break
            }
        }
        
        if !notFound {
            if let connectionListener = connectionListener, var unwrappedConnectionProcessor = connectionProcessor {
                connectionProcessor?.parserConnector = parserConnector
                connectionListener.connectionProcessor = unwrappedConnectionProcessor
                unwrappedConnectionProcessor.connectionListener = self.connectionListener
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
        parserConnector?.responseComplete()
    }
}
