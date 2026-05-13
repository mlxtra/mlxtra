import Foundation
import os.signpost


let streamingMarkdownLog = OSLog(
    subsystem: "com.localstudio.mlxtra",
    category: "StreamingMarkdown"
)


enum StreamingMarkdownInstrumentation {

    @inlinable
    static func beginSplit() -> OSSignpostIntervalState {
        let id = OSSignpostID(log: streamingMarkdownLog)
        os_signpost(.begin, log: streamingMarkdownLog, name: "SplitStablePrefix", signpostID: id)
        return OSSignpostIntervalState(id: id, log: streamingMarkdownLog)
    }

    @inlinable
    static func endSplit(_ state: OSSignpostIntervalState, blockCount: Int) {
        os_signpost(.end, log: state.log, name: "SplitStablePrefix",
                    signpostID: state.id, "blocks=%d", blockCount)
    }

    @inlinable
    static func beginBlockRender(_ blockType: String) -> OSSignpostIntervalState {
        let id = OSSignpostID(log: streamingMarkdownLog)
        os_signpost(.begin, log: streamingMarkdownLog, name: "BlockRender",
                    signpostID: id, "%{public}s", blockType)
        return OSSignpostIntervalState(id: id, log: streamingMarkdownLog)
    }

    @inlinable
    static func endBlockRender(_ state: OSSignpostIntervalState) {
        os_signpost(.end, log: state.log, name: "BlockRender", signpostID: state.id)
    }

    @inlinable
    static func beginTailRender(_ tailType: String) -> OSSignpostIntervalState {
        let id = OSSignpostID(log: streamingMarkdownLog)
        os_signpost(.begin, log: streamingMarkdownLog, name: "TailRender",
                    signpostID: id, "%{public}s", tailType)
        return OSSignpostIntervalState(id: id, log: streamingMarkdownLog)
    }

    @inlinable
    static func endTailRender(_ state: OSSignpostIntervalState) {
        os_signpost(.end, log: state.log, name: "TailRender", signpostID: state.id)
    }

    @inlinable
    static func beginTextStorageMutation(_ mutation: String) -> OSSignpostIntervalState {
        let id = OSSignpostID(log: streamingMarkdownLog)
        os_signpost(.begin, log: streamingMarkdownLog, name: "TextStorageMutation",
                    signpostID: id, "%{public}s", mutation)
        return OSSignpostIntervalState(id: id, log: streamingMarkdownLog)
    }

    @inlinable
    static func endTextStorageMutation(_ state: OSSignpostIntervalState) {
        os_signpost(.end, log: state.log, name: "TextStorageMutation", signpostID: state.id)
    }
}


struct OSSignpostIntervalState {
    let id: OSSignpostID
    let log: OSLog
}
