import XCTest
@testable import K2SpikeTests

XCTMain([
    testCase(K2SpikeTests.allTests),
    testCase(RouterTests.allTests),
    testCase(ParameterParsingTests.allTests),
    testCase(SecurityTests.allTests),
    testCase(FileServerTests.allTests)
])
