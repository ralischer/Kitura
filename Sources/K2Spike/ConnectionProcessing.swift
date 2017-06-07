//
//  ConnectionHandler.swift
//  K2Spike
//
//  Created by Samuel Kallner on 10/05/2017.
//
//

import Foundation
import Dispatch

import SwiftServerHttp

public protocol ConnectionProcessing {
    var connectionListener: ConnectionListener? {get set}
    var parserConnector: ParserConnecting? {get set}
    
    var keepAliveUntil: TimeInterval? { get }
    
    func process(data: Data) -> Int
    func connectionClosed()
}
