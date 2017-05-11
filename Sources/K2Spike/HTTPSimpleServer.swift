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

#if os(Linux)
    import Signals
#endif


// MARK: HTTPServer

/// An HTTP server that listens for connections on a socket.
public class HTTPSimpleServer {
    
    private let serverSocket: Socket
    private var connectionListenerList = ConnectionListenerCollection()
    
    public var port: Int {
        return Int(serverSocket.listeningPort)
    }
    
    public init() {
        #if os(Linux)
            Signals.trap(signal: .pipe) {
                _ in
                Log.info("Receiver closed socket, SIGPIPE ignored")
            }
        #endif
        
        serverSocket = try! Socket.create()
    }
    
    public func start(port: Int = 0, webapp: @escaping WebApp) throws {
        try self.serverSocket.listen(on: port, maxBacklogSize: 100)
        DispatchQueue.global().async {
            repeat {
                do {
                    let clientSocket = try self.serverSocket.acceptClientConnection()
                    let connectionProcessor = HTTPConnectionProcessor(webapp: webapp)
                    let connectionListener = ConnectionListener(socket:clientSocket, connectionProcessor: connectionProcessor)
                    self.connectionListenerList.add(connectionListener)
                    DispatchQueue.global().async {
                        connectionListener.process()
                    }
                } catch let error {
                    Log.error("Error accepting client connection: \(error)")
                }
            } while self.serverSocket.isListening
        }
        
    }
    
    public func stop() {
        connectionListenerList.closeAll()
        serverSocket.close()
    }
    
    internal var connectionCount: Int {
        return connectionListenerList.count
    }
}

class ConnectionListenerCollection {
    class WeakConnectionListener<T: AnyObject> {
        weak var value : T?
        init (_ value: T) {
            self.value = value
        }
    }
    
    var storage = [WeakConnectionListener<ConnectionListener>]()
    
    func add(_ listener:ConnectionListener) {
        storage.append(WeakConnectionListener(listener))
    }
    
    func closeAll() {
        storage.filter { nil != $0.value }.forEach { $0.value?.close() }
    }
    
    var count: Int {
        return storage.filter { nil != $0.value }.count
    }
}
