import Foundation

enum VersionComparator {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsVersion = ParsedVersion(lhs)
        let rhsVersion = ParsedVersion(rhs)
        let count = max(lhsVersion.core.count, rhsVersion.core.count)

        for index in 0..<count {
            let left = index < lhsVersion.core.count ? lhsVersion.core[index] : 0
            let right = index < rhsVersion.core.count ? rhsVersion.core[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }

        return comparePrerelease(lhsVersion.prerelease, rhsVersion.prerelease)
    }

    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        if lhs.isEmpty && rhs.isEmpty { return .orderedSame }
        if lhs.isEmpty { return .orderedDescending }
        if rhs.isEmpty { return .orderedAscending }

        for index in 0..<max(lhs.count, rhs.count) {
            if index >= lhs.count { return .orderedAscending }
            if index >= rhs.count { return .orderedDescending }

            let left = lhs[index]
            let right = rhs[index]
            if left == right { continue }

            let leftNumber = Int(left)
            let rightNumber = Int(right)
            switch (leftNumber, rightNumber) {
            case let (left?, right?):
                if left < right { return .orderedAscending }
                if left > right { return .orderedDescending }
            case (.some, .none):
                return .orderedAscending
            case (.none, .some):
                return .orderedDescending
            case (.none, .none):
                let result = left.compare(right, options: [.caseInsensitive, .numeric])
                if result != .orderedSame { return result }
            }
        }

        return .orderedSame
    }

    private struct ParsedVersion {
        let core: [Int]
        let prerelease: [String]

        init(_ rawVersion: String) {
            let withoutBuildMetadata = rawVersion.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = withoutBuildMetadata.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            core = parts.first?
                .split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 } ?? []
            prerelease = parts.count > 1
                ? parts[1].split(separator: ".").map(String.init)
                : []
        }
    }
}
