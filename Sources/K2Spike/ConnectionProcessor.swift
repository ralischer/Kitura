//
//  ConnectionHandler.swift
//  K2Spike
//
//  Created by Samuel Kallner on 10/05/2017.
//
//

import Foundation
import Dispatch

public typealias ConnectionWriter = (_ from: DispatchData) -> Void
public typealias ConnectionCloser = () -> Void

public protocol ConnectionProcessor {
    var connectionLitener: ConnectionListener? {get set}
    var writeToConnection: ConnectionWriter? {get set}
    var closeConnection: ConnectionCloser? {get set}
    
    var keepAliveUntil: TimeInterval? {get}
    
    func process(bytes: UnsafePointer<Int8>!, length: Int) -> Int
    func connectionClosed()
}
