#if os(macOS) && swift(>=4)
    import Foundation
    import K2Spike
    import HTTPSketch

    class CacheWebApp: ResponseCreating {
        let cache = NSCache<AnyObject, AnyObject>()
        let encoder = JSONEncoder()

        func serve(request req: HTTPRequest, context: RequestContext, response res: HTTPResponseWriter) -> HTTPBodyProcessing {
            // Assume the router gave us the right request - at least for now
            res.writeResponse(HTTPResponse(httpVersion: req.httpVersion,
                                           status: .ok,
                                           transferEncoding: .chunked,
                                           headers: HTTPHeaders([("X-foo", "bar")])))

            let key = (req.method.rawValue.lowercased() + req.target) as AnyObject

            var userData = Data()
            if let cachedUser = cache.object(forKey: key) {
                userData = cachedUser as! Data
            } else {
                do {
                    let newUser = User(id: UUID().uuidString, name: "Mario", address: Address(number: 123, street: "Mushroom St", type: .apartment))
                    userData = try encoder.encode(newUser)
                    cache.setObject(userData as AnyObject, forKey: key)
                } catch {
                    userData = error.localizedDescription.data(using: .utf8)!
                }
            }

            return .processBody { (chunk, stop) in
                switch chunk {
                case .chunk(_, let finishedProcessing):
                    finishedProcessing()
                case .end:
                    res.writeBody(data: userData) { _ in }
                    res.done()
                default:
                    stop = true /* don't call us anymore */
                    res.abort()
                }
            }
        }
    }

    struct User: Codable, Equatable {
        let id: String
        let name: String
        let address: Address

        static func ==(lhs: User, rhs: User) -> Bool {
            return  lhs.id      == rhs.id &&
                lhs.name    == rhs.name &&
                lhs.address == rhs.address
        }
    }

    struct Address: Codable, Equatable {
        let number: Int
        let street: String
        let type: AddressType

        static func ==(lhs: Address, rhs: Address) -> Bool {
            return  lhs.number  == rhs.number &&
                lhs.street  == rhs.street &&
                lhs.type    == rhs.type
        }
    }

    enum AddressType: String, Codable {
        case home
        case apartment
        case business
    }
#endif
