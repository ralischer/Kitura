import HTTP

// Protocols related to ResponseCreating

public protocol ResponseCreating {
    func serve(request: HTTPRequest, context: RequestContext, response: HTTPResponseWriter) -> HTTPBodyProcessing
}

public protocol BodylessParameterResponseCreating {
    associatedtype Parameters: BodylessParameterContaining
    func serve(request: HTTPRequest, context: RequestContext, parameters: Parameters, response: HTTPResponseWriter) -> HTTPBodyProcessing
}

public protocol ParameterResponseCreating {
    associatedtype Parameters: ParameterContaining
    func serve(request: HTTPRequest, context: RequestContext, parameters: Parameters, response: HTTPResponseWriter) -> (status: HTTPResponseStatus, headers:HTTPHeaders, responseBody: ResponseObject)
}

public protocol FileResponseCreating {
    func serve(request: HTTPRequest, context: RequestContext, filePath: String, response: HTTPResponseWriter) -> HTTPBodyProcessing
}
