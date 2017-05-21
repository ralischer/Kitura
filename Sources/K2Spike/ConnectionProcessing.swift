//
//  ConnectionHandler.swift
//  K2Spike
//
//  Created by Samuel Kallner on 10/05/2017.
//
//

import Foundation
import Dispatch

import HTTPSketch

public protocol ConnectionProcessing {
    var connectionListener: ConnectionListener? {get set}
    var parserConnector: ParserConnecting? {get set}
    
    func process(data: Data) -> Int
    func connectionClosed()
}
