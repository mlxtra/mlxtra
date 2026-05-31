import Foundation

struct RuntimeDownloadSpeedTracker {
    private var samples: [(date: Date, bytes: Int64)] = []

    mutating func bytesPerSecond(for progress: RuntimeDownloadProgress, at date: Date = Date()) -> Double? {
        let downloadedBytes = progress.downloadedBytes
        if let lastSample = samples.last {
            if downloadedBytes < lastSample.bytes || date.timeIntervalSince(lastSample.date) > 12 {
                samples.removeAll()
            }
        }

        if samples.last?.bytes != downloadedBytes {
            samples.append((date, downloadedBytes))
        }

        let cutoff = date.addingTimeInterval(-8)
        while samples.count > 2,
              let secondSample = samples.dropFirst().first,
              secondSample.date < cutoff {
            samples.removeFirst()
        }

        guard let firstSample = samples.first,
              let lastSample = samples.last,
              lastSample.bytes > firstSample.bytes else {
            return nil
        }

        let seconds = lastSample.date.timeIntervalSince(firstSample.date)
        guard seconds >= 0.05 else { return nil }
        return Double(lastSample.bytes - firstSample.bytes) / seconds
    }

    mutating func reset() {
        samples.removeAll()
    }
}
