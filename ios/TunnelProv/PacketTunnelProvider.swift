//
//  PacketTunnelProvider.swift
//  SelfSign TunnelProv
//
//  Built-in LocalDevVPN reflector. Based on the open-source implementation at
//  https://github.com/SiamSadik/LocalDevVPN (MIT), trimmed to the core packet
//  reflection logic so SelfSign needs no companion App from the App Store.
//
//  Only 10.7.0.1/32 is routed through the utun. Outgoing packets addressed to
//  the fake peer are rewritten so the phone's own RemotePairing service sees
//  them as an inbound connection, and replies are reflected back.
//

import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var tunnelDeviceIp: String = "10.7.0.0"
    private var tunnelFakeIp: String = "10.7.0.1"
    private let tunnelSubnetMask: String = "255.255.255.255"

    private var deviceIpValue: UInt32 = 0
    private var fakeIpValue: UInt32 = 0
    private var isReading = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        if let deviceIp = options?["TunnelDeviceIP"] as? String { tunnelDeviceIp = deviceIp }
        if let fakeIp = options?["TunnelFakeIP"] as? String { tunnelFakeIp = fakeIp }

        deviceIpValue = Self.ipToUInt32(tunnelDeviceIp)
        fakeIpValue = Self.ipToUInt32(tunnelFakeIp)

        NSLog("[SelfSign] reflector active dev=\(tunnelDeviceIp) fake=\(tunnelFakeIp)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelDeviceIp)
        let ipv4 = NEIPv4Settings(addresses: [tunnelDeviceIp], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: tunnelFakeIp, subnetMask: "255.255.255.255")
        ]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self, error == nil else {
                completionHandler(error)
                return
            }
            self.isReading = true
            self.readPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isReading = false
        NSLog("[SelfSign] reflector stopped: \(reason.rawValue)")
        completionHandler()
    }

    /// Read a batch, swap source/destination IPv4 for the two tunnel addresses,
    /// write back, then recurse. This is the whole LocalDevVPN trick.
    private func readPackets() {
        guard isReading else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.isReading else { return }
            var modified = packets
            for i in modified.indices
            where protocols[i].int32Value == AF_INET && modified[i].count >= 20 {
                modified[i].withUnsafeMutableBytes { bytes in
                    guard let ptr = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
                    let src = UInt32(bigEndian: ptr[3])
                    let dst = UInt32(bigEndian: ptr[4])
                    if src == self.deviceIpValue { ptr[3] = self.fakeIpValue.bigEndian }
                    if dst == self.fakeIpValue { ptr[4] = self.deviceIpValue.bigEndian }
                }
            }
            self.packetFlow.writePackets(modified, withProtocols: protocols)
            self.readPackets()
        }
    }

    private static func ipToUInt32(_ ip: String) -> UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}
