import SwiftOrcHTTP

// These aliases preserve the 0.1 source surface for applications that imported
// only SwiftOrcOpenAICompatible when configuring its HTTP behavior.
public typealias HTTPModelEndpointSecurityPolicy =
    SwiftOrcHTTP.HTTPModelEndpointSecurityPolicy
public typealias HTTPModelRetryPolicy = SwiftOrcHTTP.HTTPModelRetryPolicy
public typealias HTTPModelProviderEvent = SwiftOrcHTTP.HTTPModelProviderEvent
public typealias HTTPModelProviderEventHandler =
    SwiftOrcHTTP.HTTPModelProviderEventHandler
public typealias HTTPModelTransportResponse =
    SwiftOrcHTTP.HTTPModelTransportResponse
public typealias HTTPModelTransport = SwiftOrcHTTP.HTTPModelTransport
public typealias HTTPModelTransportStream = SwiftOrcHTTP.HTTPModelTransportStream
public typealias HTTPStreamingModelTransport =
    SwiftOrcHTTP.HTTPStreamingModelTransport
public typealias HTTPModelResourceLimits = SwiftOrcHTTP.HTTPModelResourceLimits
public typealias URLSessionHTTPModelTransport =
    SwiftOrcHTTP.URLSessionHTTPModelTransport
public typealias HTTPModelTransportError = SwiftOrcHTTP.HTTPModelTransportError
public typealias HTTPRequestHeaders = SwiftOrcHTTP.HTTPRequestHeaders
public typealias HTTPRequestHeadersError = SwiftOrcHTTP.HTTPRequestHeadersError
