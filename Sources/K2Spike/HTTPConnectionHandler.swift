//
//  HTTPConnectionHandler.swift
//  K2Spike
//
//  Created by Samuel Kallner on 10/05/2017.
//
//

import Foundation

class HTTPConnectionHandler: ConnectionHandler {
    let parser: StreamingParser
    
    weak var connectionLitener: ConnectionListener?
    
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
    
    init(parser: StreamingParser) {
        self.parser = parser
    }
    
    var keepAliveUntil: TimeInterval? {
        return parser.keepAliveUntil
    }
    
    func handle(bytes: UnsafePointer<Int8>!, length: Int) -> Int {
        let (numberParsed, _) = self.parser.readStream(bytes: bytes, len: length)
        return numberParsed
    }
    
    func closed() {}
}
