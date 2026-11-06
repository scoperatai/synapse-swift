import Foundation
import Testing

@testable import Synapse

@Suite("SynapseValue")
struct SynapseValueTests {
    @Test("every JSON shape round-trips")
    func roundTrip() throws {
        let value = SynapseValue.object([
            "string": "hello",
            "int": 3,
            "double": 1.5,
            "true": true,
            "false": false,
            "null": nil,
            "array": [1, "two", false],
            "nested": ["deep": ["deeper": 1]],
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(SynapseValue.self, from: data)

        #expect(decoded == value)
    }

    @Test("booleans don't decode as numbers")
    func boolIsNotNumber() throws {
        let decoded = try JSONDecoder().decode(SynapseValue.self, from: Data("true".utf8))
        #expect(decoded == .bool(true))
        #expect(decoded.doubleValue == nil)
        #expect(decoded.boolValue == true)
    }

    @Test("whole numbers encode without a decimal point")
    func integersStayIntegral() throws {
        let data = try JSONEncoder().encode(SynapseValue.object(["count": 3]))
        #expect(String(data: data, encoding: .utf8) == #"{"count":3}"#)
    }

    @Test("typed accessors return nil for the wrong case")
    func accessors() {
        #expect(SynapseValue.string("a").stringValue == "a")
        #expect(SynapseValue.string("a").doubleValue == nil)
        #expect(SynapseValue.number(2).doubleValue == 2)
        #expect(SynapseValue.null.boolValue == nil)
    }
}
