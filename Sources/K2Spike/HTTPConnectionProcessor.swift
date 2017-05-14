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
        let (numberParsed, _) = self.parser.readStream(bytes: bytes, len: length)
        return numberParsed
    }
    
    func connectionClosed() {}
}
