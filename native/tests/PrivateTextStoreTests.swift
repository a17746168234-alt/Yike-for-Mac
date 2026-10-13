import Foundation

@main
struct PrivateTextStoreTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Yike-PrivateTextStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PrivateTextStore(fileName: "qa-secret", directory: root)
        let emptyValue = try store.load()
        assert(emptyValue == nil)
        try store.save("test-value")
        let savedValue = try store.load()
        assert(savedValue == "test-value")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as! NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("qa-secret").path)[.posixPermissions] as! NSNumber
        assert(directoryMode.intValue & 0o077 == 0)
        assert(fileMode.intValue & 0o077 == 0)
        try store.save("updated-value")
        let updatedValue = try store.load()
        assert(updatedValue == "updated-value")
        try store.delete()
        let deletedValue = try store.load()
        assert(deletedValue == nil)
        print("PrivateTextStore: save, replace, permissions, delete passed")
    }
}
