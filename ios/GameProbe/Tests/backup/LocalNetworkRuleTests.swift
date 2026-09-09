import XCTest

@testable import GameProbe

final class LocalNetworkRuleTests: XCTestCase {

    func testPrivateAddressesAndBonjourNamesAskThePermission() {
        for host in [
            "192.168.0.40", "10.0.0.2", "172.16.5.9", "172.31.255.1", "169.254.3.3",
            "Mateos-MacBook-Pro.local", "fe80::1", "fd12:3456::1", "[fe80::1]",
        ] {
            XCTAssertTrue(LocalNetworkRule.asksThePermission(host: host), host)
        }
    }

    func testPublicNamesAndTheLoopbackDoNot() {
        for host in [
            "dav.example.com", "s3.eu-west-1.amazonaws.com", "8.8.8.8", "172.32.0.1",
            "localhost", "127.0.0.1", "fdisk.example.com",
        ] {
            XCTAssertFalse(LocalNetworkRule.asksThePermission(host: host), host)
        }
    }
}
