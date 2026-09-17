import Foundation
import Network
import Security

enum TLSFlavor: String {
    /// TLS 1.2 with the RFC 5487 PSK ciphersuite TLS_PSK_WITH_AES_128_GCM_SHA256 (0x00A8).
    case tls12PSK
    /// TLS 1.3 with the TLS_AES_128_GCM_SHA256 (0x1301) ciphersuite; PSK is carried by the pre_shared_key extension if supported.
    case tls13PSK
    /// Informational: PSK suite appended, min TLS 1.2, max left at the system default (TLS 1.3). Does it still negotiate 1.2?
    case tls12PSKNoMaxPin
}

/// The PSK identity string offered by the client and matched by the server.
let pskIdentity = "chauffeur-remote"

/// Builds NWProtocolTLS.Options for a certificate-less, PSK-authenticated TLS session.
/// The same options are used verbatim by both the listener and the client.
func makeTLSOptions(psk: Data, identity: String, flavor: TLSFlavor) -> NWProtocolTLS.Options {
    let tls = NWProtocolTLS.Options()
    let sec = tls.securityProtocolOptions

    let pskDispatchData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
    let identityDispatchData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(sec, pskDispatchData as __DispatchData, identityDispatchData as __DispatchData)

    switch flavor {
    case .tls12PSK:
        // tls_ciphersuite_t has no PSK cases, so build it from the legacy SecureTransport constant (0x00A8).
        // Imported C enums accept any raw value, so the force-unwrap is safe.
        let psk128 = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        sec_protocol_options_append_tls_ciphersuite(sec, psk128)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
    case .tls12PSKNoMaxPin:
        let psk128 = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        sec_protocol_options_append_tls_ciphersuite(sec, psk128)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
    case .tls13PSK:
        sec_protocol_options_append_tls_ciphersuite(sec, .AES_128_GCM_SHA256)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
    }
    return tls
}

func makeParameters(psk: Data, flavor: TLSFlavor) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let params = NWParameters(tls: makeTLSOptions(psk: psk, identity: pskIdentity, flavor: flavor), tcp: tcp)
    return params
}

struct NegotiatedTLS: CustomStringConvertible {
    let versionRaw: UInt16
    let ciphersuiteRaw: UInt16

    var versionName: String {
        switch versionRaw {
        case 0x0303: return "TLSv1.2"
        case 0x0304: return "TLSv1.3"
        default: return String(format: "0x%04x", versionRaw)
        }
    }

    var ciphersuiteName: String {
        switch ciphersuiteRaw {
        case 0x00A8: return "TLS_PSK_WITH_AES_128_GCM_SHA256"
        case 0x00A9: return "TLS_PSK_WITH_AES_256_GCM_SHA384"
        case 0x1301: return "TLS_AES_128_GCM_SHA256"
        case 0x1302: return "TLS_AES_256_GCM_SHA384"
        case 0x1303: return "TLS_CHACHA20_POLY1305_SHA256"
        default: return "unknown"
        }
    }

    var description: String {
        String(format: "%@ (0x%04x) / %@ (0x%04x)", versionName, versionRaw, ciphersuiteName, ciphersuiteRaw)
    }
}

extension NWConnection {
    /// Reads negotiated version and ciphersuite out of the TLS metadata. Only valid after `.ready`.
    func negotiatedTLS() -> NegotiatedTLS? {
        guard let md = metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let v = sec_protocol_metadata_get_negotiated_tls_protocol_version(md.securityProtocolMetadata)
        let cs = sec_protocol_metadata_get_negotiated_tls_ciphersuite(md.securityProtocolMetadata)
        return NegotiatedTLS(versionRaw: v.rawValue, ciphersuiteRaw: cs.rawValue)
    }
}
