import FTPKit
import Foundation

// Smoke test against a live server:
//   ftpcheck <ftp|ftpes|ftps|sftp> <host> <port> <user> <pass> [keyfile] [ssh -o options...]
let args = CommandLine.arguments
guard args.count >= 6, let proto = ServerProtocol(scheme: args[1]), let port = UInt16(args[3]) else {
    print("Kullanım: ftpcheck <ftp|ftpes|ftps|sftp> <host> <port> <user> <pass> [keyfile] [ssh seçenekleri…]")
    exit(2)
}

let config = FTPConfig(host: args[2], port: port, user: args[4], password: args[5], serverProtocol: proto,
                       keyFile: args.count > 6 ? args[6] : "", sshOptions: Array(args.dropFirst(7)))
let client = makeRemoteClient(config: config, log: { kind, text in
    print("[\(kind)] \(text)")
}, trust: { info in
    print("[trust] \(info.subject) \(info.fingerprint) — kabul edildi (test)")
    return true
})

func check(_ ok: Bool, _ what: String) {
    print(ok ? "✅ \(what)" : "❌ \(what)")
    if !ok { exit(1) }
}

do {
    try await client.connect()
    let home = client.homeDirectory
    let dir = RemotePath.join(home, "maczilla test ğüşİ")
    try? await client.removeDirectory(dir, recursive: true)
    try await client.makeDirectory(dir)

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ftpcheck-\(UUID().uuidString)")
    let payload = Data((0..<3_000_000).map { UInt8($0 % 251) })
    try payload.write(to: tmp)
    let remoteFile = RemotePath.join(dir, "büyük dosya.bin")
    try await client.upload(tmp, to: remoteFile) { _ in }
    check(try await client.size(remoteFile) == Int64(payload.count), "upload + SIZE")

    let back = tmp.appendingPathExtension("back")
    try await client.download(remoteFile, to: back) { _ in }
    check(try Data(contentsOf: back) == payload, "download roundtrip")

    // Timestamps: set one, read it back, and see it in the listing.
    let stamp = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
    if try await client.setModified(remoteFile, to: stamp) {
        check(try await client.modified(remoteFile) == stamp, "set/get modified time")
    } else {
        print("— sunucu dosya tarihi ayarlamayı desteklemiyor (MFMT yok)")
    }

    let listing = try await client.list(dir)
    check(listing.files.contains { $0.name == "büyük dosya.bin" && $0.size == Int64(payload.count) }, "list (\(listing.path))")

    try await client.makeDirectory(RemotePath.join(dir, "alt"))
    try await client.rename(remoteFile, to: RemotePath.join(dir, "alt/taşındı.bin"))
    check(try await client.list(RemotePath.join(dir, "alt")).files.map(\.name) == ["taşındı.bin"], "rename")

    // Parallel calls must serialize cleanly.
    async let a = client.list(dir)
    async let b = client.list(RemotePath.join(dir, "alt"))
    let (ra, rb) = try await (a, b)
    check(ra.files.count == 1 && rb.files.count == 1, "concurrent list")

    try await client.removeDirectory(dir, recursive: true)
    check(try await !client.list(home).files.contains { $0.name == "maczilla test ğüşİ" }, "recursive delete")
    await client.disconnect()
    print("Tüm testler geçti.")
} catch {
    print("HATA: \(error.localizedDescription)")
    exit(1)
}
