//
//  ConnectionListener.swift
//  K2Spike
//
//  Created by Carl Brown on 5/2/17.
//
//

import Foundation

import LoggerAPI
import SwiftServerHttp
import Socket

#if os(Linux)
    import Signals
    import Dispatch
#endif


/// The Interface between the StreamingParser class and IBM's BlueSocket wrapper around socket(2).
// MARK: HTTPServer

/// You hopefully should be able to replace this with any network library/engine.
public class ConnectionListener: ParserConnecting {
    var socket: Socket?
    var connectionProcessor: ConnectionProcessing?
/// An HTTP server that listens for connections on a socket.
public class ConnectionListener {
    var socket : Socket
    var connectionProcessor: ConnectionProcessor

    
    let socketReaderQueue: DispatchQueue
    ///Save the socket file descriptor so we can loook at it for debugging purposes
    let socketWriterQueue: DispatchQueue
    let readBuffer = NSMutableData()
    var socketFD: Int32
    var readBufferPosition = 0
    
    /// Queues for managing access to the socket without blocking the world
    weak var socketReaderQueue: DispatchQueue?
    let writeBuffer = NSMutableData()
    var writeBufferPosition = 0
    weak var socketWriterQueue: DispatchQueue?
    
    ///Event handler for reading from the socket
    private var readerSource: DispatchSourceRead?
    
    ///Flag to track whether we're in the middle of a response or not (with lock)
    private let _responseCompletedLock = DispatchSemaphore(value: 1)
    private var writerSource: DispatchSourceWrite?
    private var _responseCompleted: Bool = false
    var responseCompleted: Bool {
        get {
            _responseCompletedLock.wait()
            defer {
                _responseCompletedLock.signal()
            }
            return _responseCompleted
        }
        set {
            _responseCompletedLock.wait()
            defer {
                _responseCompletedLock.signal()
            }
            _responseCompleted = newValue
        }
    }
    
    ///Flag to track whether we've received a socket error or not (with lock)

    // Timer that cleans up idle sockets on expire
    private let _errorOccurredLock = DispatchSemaphore(value: 1)
    private var _errorOccurred: Bool = false
    var errorOccurred: Bool {
        get {
            _errorOccurredLock.wait()
            defer {
                _errorOccurredLock.signal()
            }
            return _errorOccurred
        }
        set {
            _errorOccurredLock.wait()
            defer {
                _errorOccurredLock.signal()
            }
            _errorOccurred = newValue
        }
    }
    
    
    /// initializer
    ///
    /// - Parameters:
    ///   - socket: Socket object from BlueSocket library wrapping a socket(2)
    ///   - connectionProcessor: The ConnectionProcessing implementation that will process data read from the socket
    ///   - readQueue: The DispatchQueue to use for reading from the socket
    ///   - writeQueue The DispaltchQueue to use for writing to the socket
    public init(socket: Socket, connectionProcessor: ConnectionProcessing, readQueue: DispatchQueue, writeQueue:  DispatchQueue) {
        self.socket = socket
        socketFD = socket.socketfd
        socketReaderQueue = readQueue
        socketWriterQueue = writeQueue

        self.connectionProcessor = connectionProcessor
        self.connectionProcessor?.parserConnector = self
        self.connectionProcessor?.connectionListener = self
        self.connectionProcessor.writeToConnection = self.queueSocketWrite

        idleSocketTimer = makeIdleSocketTimer()
    }
    
    
    /// Check if socket is still open. Used to decide whether it should be closed/pruned after timeout
    public var isOpen: Bool {
        guard let socket = self.socket else {
            return false
        }
        return (socket.isActive || socket.isConnected)
        return timer
    }
    
    
    /// Close the socket and free up memory unless we're in the middle of a request
    func close() {
        let now = Date().timeIntervalSinceReferenceDate
        if !self.responseCompleted && !self.errorOccurred {
            return
        }
        self.readerSource?.cancel()
    }

    private func cleanupIdleSocketTimer() {
        idleSocketTimer?.cancel()
        idleSocketTimer = nil
    }
    
    public func close() {
        self.readerSource?.cancel()
        self.writerSource?.cancel()
        self.socket.close()
        self.connectionProcessor.connectionClosed()
    }
    
    /// Called by the parser to let us know that it's done with this socket
    public func closeWriter() {
        self.socketWriterQueue?.async { [weak self] in
        if let readerSource = self.readerSource {
            if (self?.readerSource?.isCancelled ?? true) {
                self.socket.close()
                self?.close()
            }
        }
    }
    
    /// Check if the socket is idle, and if so, call close()
    func closeIfIdleSocket() {
        let now = Date().timeIntervalSinceReferenceDate
        if let keepAliveUntil = connectionProcessor?.keepAliveUntil, now >= keepAliveUntil {
            print("Closing idle socket \(socketFD)")
            close()
        }
    }
    
    
    /// Called by the parser to let us know that a response has started being created
    public func responseBeginning() {
        self.socketWriterQueue?.async { [weak self] in
            self?.responseCompleted = false
        }
    }
    
    
    /// Called by the parser to let us know that a response is complete, and we can close after timeout
    public func responseComplete() {
        self.socketWriterQueue?.async { [weak self] in
            self?.responseCompleted = true
            if (self?.readerSource?.isCancelled ?? true) {
                self?.close()
            }
        } else {
            //No writer source, we're good to close
            self.socket.close()
            self.connectionProcessor.connectionClosed()
        }
    }
    
    
    /// Starts reading from the socket and feeding that data to the parser
    public func process() {
        do {
            try! socket?.setBlocking(mode: true)
            
            let tempReaderSource = DispatchSource.makeReadSource(fileDescriptor: socket?.socketfd ?? -1,
                                                             queue: socketReaderQueue)
            
            tempReaderSource.setEventHandler { [weak self] in
                
                guard let strongSelf = self else {
                    return
                }
                guard strongSelf.socket?.socketfd ?? -1 > 0 else {
                    self?.readerSource?.cancel()
                    return
                }
                
                var length = 1 //initial value
                    // The event handler gets called with readerSource.data == 0 continually even when there
                do {
                    repeat {
                        if strongSelf.socket?.socketfd ?? -1 > 0 {
                        length = try strongSelf.socket?.read(into: readBuffer) ?? -1
                        if length > 0 {
                            self?.responseCompleted = false
                            return
                            let readBuffer:NSMutableData = NSMutableData()
                        let data = Data(bytes:readBuffer.bytes.assumingMemoryBound(to: Int8.self), count:readBuffer.length)
                            length = try strongSelf.socket?.read(into: readBuffer) ?? -1
                        let numberParsed = strongSelf.connectionProcessor?.process(data: data) ?? 0
                            var length = 1
                            while  length > 0  {
                                length = try self.socket.read(into: self.readBuffer)
                            }
                        if numberParsed != data.count {
                            print("Error: wrong number of bytes consumed by parser (\(numberParsed) instead of \(data.count)")
                                let length = self.readBuffer.length - self.readBufferPosition
                                let numberParsed = self.connectionProcessor.process(bytes: bytes, length: length)
                            let data = Data(bytes:readBuffer.bytes.assumingMemoryBound(to: Int8.self), count:readBuffer.length)
                            
                            let numberParsed = strongSelf.connectionProcessor?.process(data: data) ?? 0
                            

                                self.readBufferPosition += numberParsed
                                
                            if numberParsed != data.count {
                                print("Error: wrong number of bytes consumed by parser (\(numberParsed) instead of \(data.count)")
                            }
                        } else {
                            print("bad socket FD while reading")
                            length = -1
                        }
                        
                    } while length > 0
                } catch {
                    print("ReaderSource Event Error: \(error)")
                    self?.errorOccurred = true
                    self?.close()
                }
                if (length == 0) {
                    self?.close()
                }
                if (length < 0) {
                    self?.errorOccurred = true
                    self?.close()
                }
            }
            
            tempReaderSource.setCancelHandler { [ weak self] in
                if (self?.socket?.socketfd ?? -1) > 0 {
                    self?.socket?.close()
                }
                self?.connectionProcessor?.connectionClosed()
                
                //In a perfect world, we wouldn't have to clean this all up explicitly,
                // but KDE/heaptrack informs us we're in far from a perfect world
                self?.readerSource?.setEventHandler(handler: nil)
                self?.readerSource?.setCancelHandler(handler: nil)
                self?.readerSource = nil
                self?.socket = nil
                self?.connectionProcessor?.parserConnector = nil //allows for memory to be reclaimed
                self?.connectionProcessor?.connectionListener = nil //allows for memory to be reclaimed
                self?.connectionProcessor = nil
                self?.socketReaderQueue = nil
                self?.socketWriterQueue = nil
            }
            
            self.readerSource = tempReaderSource
            self.readerSource?.resume()
        }
        
    }
    
    
    /// Called by the parser to give us data to send back out of the socket
        if Log.isLogging(.debug) {
    ///
    /// - Parameter bytes: Data object to be queued to be written to the socket
            let byteStringToPrint = String(data:byteDataToPrint, encoding:.utf8)
            if let byteStringToPrint = byteStringToPrint {
    public func queueSocketWrite(_ bytes: Data) {
            } else {
        self.socketWriterQueue?.async { [ weak self ] in
            }
        }
        self.socketWriterQueue.async {
            bytes.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
            self?.write(bytes)
            }
        }
    }
    
    
    /// Write data to a socket. Should be called in an `async` block on the `socketWriterQueue`
            if length > 0 {
    ///
    /// - Parameter data: data to be written
                if let byteStringToPrint = byteStringToPrint {
                    Log.debug("\(#function) called with '\(byteStringToPrint)' to \(length)")
                } else {
    public func write(_ data:Data) {
                }
            } else {
                Log.debug("\(#function) called empty")
            }
        }

        guard self.socket.isActive && socket.socketfd > -1 else {
            Log.warning("Socket write() called after socket \(socket.socketfd) closed")
            self.closeWriter()
            return
        }
        
        do {
            var written: Int = 0
            var offset = 0
            
            while written < data.count && !errorOccurred {
                written = try socket.write(from: bytes, bufSize: length)
            }
            else {
                written = 0
            }
            
            if written != length {
                try data.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
                
                if writerSource == nil {
                    writerSource = DispatchSource.makeWriteSource(fileDescriptor: socket.socketfd,
                                                                  queue: socketWriterQueue)
                    
                    writerSource!.setEventHandler() {
                        if  self.writeBuffer.length != 0 {
                            defer {
                                if self.writeBuffer.length == 0, let writerSource = self.writerSource {
                                    writerSource.cancel()
                                }
                            }
                            
                            guard self.socket.isActive && self.socket.socketfd > -1 else {
                                Log.warning("Socket closed with \(self.writeBuffer.length - self.writeBufferPosition) bytes still to be written")
                                self.writeBuffer.length = 0
                                self.writeBufferPosition = 0
                                
                                return
                            }
                            
                            do {
                    let result = try socket?.write(from: ptr + offset, bufSize:
                                
                                let written: Int
                                
                                if amountToWrite > 0 {
                                    written = try self.socket.write(from: self.writeBuffer.bytes + self.writeBufferPosition,
                                                                    bufSize: amountToWrite)
                        data.count - offset) ?? -1
                                else {
                    if (result < 0) {
                        print("Recived broken write socket indication")
                        errorOccurred = true
                                    
                                    written = amountToWrite
                    } else {
                                
                        written += result
                                    self.writeBufferPosition += written
                                }
                                else {
                                    self.writeBuffer.length = 0
                                    self.writeBufferPosition = 0
                                }
                            }
                            catch let error {
                                if let error = error as? Socket.Error, error.errorCode == Int32(Socket.SOCKET_ERR_CONNECTION_RESET) {
                                    Log.debug("Write to socket (file descriptor \(self.socket.socketfd)) failed. Error = \(error).")
                                } else {
                                    Log.error("Write to socket (file descriptor \(self.socket.socketfd)) failed. Error = \(error).")
                                }
                                
                                // There was an error writing to the socket, close the socket
                                self.writeBuffer.length = 0
                                self.writeBufferPosition = 0
                                self.closeWriter()
                                
                            }
                        }
                    }
                    writerSource!.setCancelHandler() {
                        self.closeWriter()
                        self.writerSource = nil
                    }
                    writerSource!.resume()
                }
                offset = data.count - written
            }
            if (errorOccurred) {
        catch let error {
            if let error = error as? Socket.Error, error.errorCode == Int32(Socket.SOCKET_ERR_CONNECTION_RESET) {
                close()
            } else {
                return
            }
        } catch {
            print("Recived write socket error: \(error)")
            errorOccurred = true
            close()
        }
    }

}
