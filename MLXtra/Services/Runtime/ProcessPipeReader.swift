import Foundation

final class PipeDataReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start(on queue: DispatchQueue, group: DispatchGroup) {
        group.enter()
        queue.async {
            let readData = self.handle.readDataToEndOfFile()
            self.lock.lock()
            self.data = readData
            self.lock.unlock()
            group.leave()
        }
    }

    func collectedData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
