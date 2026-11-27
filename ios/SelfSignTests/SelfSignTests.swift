import Testing
import Foundation
@testable import SelfSign

@Suite struct SelfSignTests {
    @Test func configJSONKeysMatchRust() throws {
        let config = SessionConfig(
            appleId: "a@b.com", appPassword: "xxxx-xxxx",
            anisetteURL: nil, storageRoot: "/tmp/s", pairingDir: "/tmp/p",
            tunnelHost: "10.7.0.1", machineName: "SelfSign", teamID: nil
        )
        let data = try JSONEncoder().encode(config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["apple_id"] as? String == "a@b.com")
        #expect(json["app_password"] as? String == "xxxx-xxxx")
        #expect(json["tunnel_host"] as? String == "10.7.0.1")
        #expect(json["anisette_url"] == nil)
    }

    @Test func ipToUInt32Reflection() {
        // Mirrors PacketTunnelProvider.ipToUInt32; verify byte order.
        func toUInt(_ ip: String) -> UInt32 {
            let p = ip.split(separator: ".").compactMap { UInt32($0) }
            return (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]
        }
        #expect(toUInt("10.7.0.1") == 0x0A070001)
        #expect(toUInt("10.7.0.0") == 0x0A070000)
    }

    @Test func twoFactorJSONDecode() throws {
        let json = """
        {"lastError":null,"unknown":false,"sms":false,"numbers":[],"selectedNumberId":null}
        """
        let params = try JSONDecoder().decode(TwoFactorParams.self, from: Data(json.utf8))
        #expect(params.sms == false)
        #expect(params.numbers.isEmpty)
    }
}
