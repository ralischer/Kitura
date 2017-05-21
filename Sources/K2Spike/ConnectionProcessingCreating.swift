//
//  ConnectionProcessorCreator.swift
//  K2Spike
//
//  Created by Samuel Kallner on 11/05/2017.
//
//

import Foundation

import HTTPSketch

public protocol ConnectionProcessorCreator {
    var name: String {get}
    
    func createConnectionProcessor(request: HTTPRequest, responseWriter: HTTPResponseWriter, webapp: WebApp) -> ConnectionProcessor?
}


public class ConnectionProcessorCreatorRegistry {
    static let instance = ConnectionProcessorCreatorRegistry()
    
    private(set) var registry = Dictionary<String, ConnectionProcessorCreator>()
    
    static public func register(creator: ConnectionProcessorCreator) {
        instance.registry[creator.name.lowercased()] = creator
    }
    
    /// Determine if any upgraders have been registered
    var upgradersExist: Bool {
        return registry.count != 0
    }
    
    /// Clear the `ConnectionProcessorCreator` registry. Used in testing.
    static func clear() {
        instance.registry.removeAll()
    }
}
