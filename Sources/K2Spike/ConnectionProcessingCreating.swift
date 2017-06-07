//
//  ConnectionProcessorCreator.swift
//  K2Spike
//
//  Created by Samuel Kallner on 11/05/2017.
//
//

import Foundation

import SwiftServerHttp

public protocol ConnectionProcessingCreating {
    var name: String {get}
    
    func createConnectionProcessor(request: HTTPRequest, responseWriter: HTTPResponseWriter, webapp: WebApp) -> ConnectionProcessing?
}


public class ConnectionProcessingCreatingRegistry {
    static let instance = ConnectionProcessingCreatingRegistry()
    
    private(set) var registry = Dictionary<String, ConnectionProcessingCreating>()
    
    static public func register(creator: ConnectionProcessingCreating) {
        instance.registry[creator.name.lowercased()] = creator
    }
    
    /// Determine if any upgraders have been registered
    var upgradersExist: Bool {
        return registry.count != 0
    }
    
    /// Clear the `ConnectionProcessingCreating` registry. Used in testing.
    static func clear() {
        instance.registry.removeAll()
    }
}
