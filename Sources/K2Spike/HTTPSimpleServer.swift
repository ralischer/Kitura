//
//  HTTPSimpleServer.swift
//  K2Spike
//
//  Created by Carl Brown on 5/2/17.
//
//

import Dispatch
import Foundation

import LoggerAPI

import Socket

//import HeliumLogger

#if os(Linux)
    import Signals
#endif


// MARK: HTTPServer

/// An HTTP server that listens for connections on a TCP socket and spawns Listeners to handle them.
public class HTTPSimpleServer : CurrentConnectionCounting {
    
    
    /// Socket to listen on for connections
    private let serverSocket: Socket

    /// Collection of listeners of sockets. Used to kill connections on timeout or shutdown
    private var connectionListenerList = ConnectionListenerCollection()
    
    // Timer that cleans up idle sockets on expire
    private let pruneSocketTimer: DispatchSourceTimer
    
    /// The port we're listening on. Used primarily to query a randomly assigned port during XCTests
    public var port: Int {
        return Int(serverSocket.listeningPort)
    }
    
    public init() {
        #if os(Linux)
            Signals.trap(signal: .pipe) {
                _ in
                print("Receiver closed socket, SIGPIPE ignored")
            }
        #endif
                
        serverSocket = try! Socket.create()
        pruneSocketTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pruneSocketTimer"))
    }
    
    
    /// Starts the server listening on a given port
    ///
    /// - Parameters:
    ///   - port: TCP port. See listen(2)
    ///   - webapp: Function that creates the HTTP Response from the HTTP Request
    /// - Throws: Error (usually a socket error) generated
    public func start(port: Int = 0, webapp: @escaping WebApp) throws {
        try self.serverSocket.listen(on: port, maxBacklogSize: 100)
        pruneSocketTimer.setEventHandler { [weak self] in
            self?.connectionListenerList.prune()
        }
        pruneSocketTimer.scheduleRepeating(deadline: .now() + StreamingParser.keepAliveTimeout, interval: .seconds(Int(StreamingParser.keepAliveTimeout)))
        pruneSocketTimer.resume()
        
        let queueMax = 4
        
        var readQueues = [DispatchQueue]()
        var writeQueues = [DispatchQueue]()
        
        for i in 0..<queueMax {
            readQueues.append(DispatchQueue(label: "Read Queue \(i)"))
            writeQueues.append(DispatchQueue(label: "Write Queue \(i)"))
        }
        
        var listenerCount = 0
        DispatchQueue.global().async {
            repeat {
                do {
                    let clientSocket = try self.serverSocket.acceptClientConnection()
                    let connectionProcessor = HTTPConnectionProcessor(webapp: webapp, connectionCounter: self)
                    let readQueue = readQueues[listenerCount % queueMax]
                    let writeQueue = writeQueues[listenerCount % queueMax]
                    let listener = ConnectionListener(socket:clientSocket, connectionProcessor: connectionProcessor)
                    self.connectionListenerList.add(connectionListener)
                    DispatchQueue.global().async { [weak listener] in
                        listener?.process()
                    }
                    self.connectionListenerList.add(listener)
                
                } catch let error {
                    print("Error accepting client connection: \(error)")
                }
            } while self.serverSocket.isListening
        }
        
    }
    
    
    /// Stop the server and close the sockets
    public func stop() {
        connectionListenerList.closeAll()
        serverSocket.close()
    }
    
    
    /// Count the connections - can be used in XCTests
    public var connectionCount: Int {
        return connectionListenerList.count
    }
    
}


/// Collection of ConnectionListeners, wrapped with weak references, so the memory can be freed when the socket closes
class ConnectionListenerCollection {
    
    /// Weak wrapper class
    class WeakConnectionListener<T: AnyObject> {
        weak var value : T?
        init (_ value: T) {
            self.value = value
        }
    }
    
    let lock = DispatchSemaphore(value: 1)
    
    /// Storage for weak connection listeners
    var storage = [WeakConnectionListener<ConnectionListener>]()
    
    
    /// Add a new connection to the collection
    ///
    /// - Parameter listener: socket manager object
    func add(_ listener:ConnectionListener) {
        lock.wait()
        storage.append(WeakConnectionListener(listener))
        lock.signal()
    }
    
    /// Used when shutting down the server to close all connections
    func closeAll() {
        storage.filter { nil != $0.value }.forEach { $0.value?.close() }
    }
    
    /// Close any idle sockets and remove any weak pointers to closed (and freed) sockets from the collection
    func prune() {
        lock.wait()
        storage.filter { nil != $0.value }.forEach { $0.value?.closeIfIdleSocket() }
        storage = storage.filter { nil != $0.value }.filter { $0.value?.isOpen ?? false}
        lock.signal()
    }
    
    /// Count of collections
    var count: Int {
        return storage.filter { nil != $0.value }.count
    }
}
