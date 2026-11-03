// Khoá ký bản cập nhật iMessenger (Ed25519, CryptoKit). Khoá BÍ MẬT cất trong Keychain đăng nhập của máy (dịch vụ "imessenger-ky-cap-nhat"),
// KHÔNG nằm trong mã nguồn / GitHub. App mang sẵn khoá CÔNG KHAI để kiểm chữ ký trước khi tự cài bản mới.
// swift phat-hanh/khoa.swift tao            → tạo khoá (1 lần), in khoá công khai
// swift phat-hanh/khoa.swift cong-khai      → in khoá công khai
// swift phat-hanh/khoa.swift ky <file>      → ghi <file>.sig (chữ ký base64)
// swift phat-hanh/khoa.swift kiem <file>    → kiểm <file>.sig bằng khoá công khai (như app làm)
import Foundation
import CryptoKit
let dv = "imessenger-ky-cap-nhat", tk = "iMessenger"
func chay(_ a: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security"); p.arguments = a
    let o = Pipe(); p.standardOutput = o; p.standardError = Pipe(); try! p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines))
}
func khoaBiMat() -> Curve25519.Signing.PrivateKey {
    let (ma, b64) = chay(["find-generic-password", "-s", dv, "-a", tk, "-w"])
    guard ma == 0, let d = Data(base64Encoded: b64), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) else {
        FileHandle.standardError.write("⛔ không có khoá trong Keychain (chạy: swift phat-hanh/khoa.swift tao)\n".data(using: .utf8)!); exit(1) }
    return k
}
let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "tao":
    if chay(["find-generic-password", "-s", dv, "-a", tk]).0 == 0 { print("đã có khoá – không tạo lại (tạo lại thì bản cũ không nhận cập nhật)"); exit(1) }
    let k = Curve25519.Signing.PrivateKey()
    let (ma, _) = chay(["add-generic-password", "-s", dv, "-a", tk, "-w", k.rawRepresentation.base64EncodedString(), "-j", "Khoá ký bản cập nhật iMessenger – mất khoá thì người dùng phải tự cài lại bản mới"])
    guard ma == 0 else { print("⛔ không ghi được Keychain"); exit(1) }
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "cong-khai": print(khoaBiMat().publicKey.rawRepresentation.base64EncodedString())
case "ky":
    let f = URL(fileURLWithPath: a[2]), cks = try! khoaBiMat().signature(for: Data(contentsOf: f))
    try! cks.base64EncodedString().write(to: URL(fileURLWithPath: a[2] + ".sig"), atomically: true, encoding: .utf8)
    print("đã ký → \(f.lastPathComponent).sig")
case "kiem":
    let pub = khoaBiMat().publicKey, sig = Data(base64Encoded: try! String(contentsOfFile: a[2] + ".sig", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    if pub.isValidSignature(sig, for: try! Data(contentsOf: URL(fileURLWithPath: a[2]))) { print("chữ ký khớp") } else { print("⛔ chữ ký KHÔNG khớp"); exit(1) }
default: print("dùng: tao | cong-khai | ky <file> | kiem <file>")
}
