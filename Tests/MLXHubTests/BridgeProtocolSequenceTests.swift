import XCTest

final class BridgeProtocolSequenceTests: XCTestCase {
    private var tempDirectory: URL!
    private var launcherPath: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        launcherPath = tempDirectory.appendingPathComponent("bridge_launcher.py")
    }

    override func tearDownWithError() throws {
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testImageThenMusicThenChatSameSession() throws {
        try writeLauncherScript()
        let session = try PersistentBridgeSession(scriptURL: launcherPath)
        defer { session.terminate() }

        XCTAssertEqual(session.readMessage()["type"] as? String, "system.ready")

        let imageInitRequestID = "req-image-init"
        session.send([
            "type": "init",
            "backend": "image",
            "model_id": "image-model",
            "request_id": imageInitRequestID
        ])
        XCTAssertEqual(try session.waitForMessage(requestID: imageInitRequestID, type: "model.loaded")["model"] as? String, "image-model")

        let imageRequestID = "req-image-generate"
        session.send([
            "type": "image.generate",
            "model": "image-model",
            "prompt": "make an image",
            "request_id": imageRequestID
        ])
        XCTAssertEqual(try session.waitForMessage(requestID: imageRequestID, type: "image.generated")["request_id"] as? String, imageRequestID)
        XCTAssertEqual(try session.waitForMessage(requestID: imageRequestID, type: "chat.completion.complete")["request_id"] as? String, imageRequestID)

        let musicInitRequestID = "req-music-init"
        session.send([
            "type": "init",
            "backend": "music",
            "model_id": "music-model",
            "request_id": musicInitRequestID
        ])
        XCTAssertEqual(try session.waitForMessage(requestID: musicInitRequestID, type: "model.initialized")["model"] as? String, "music-model")

        let musicRequestID = "req-music-generate"
        session.send([
            "type": "music.generate",
            "model": "music-model",
            "parameters": ["caption": "make music"],
            "request_id": musicRequestID
        ])
        XCTAssertEqual(try session.waitForMessage(requestID: musicRequestID, type: "model.loaded")["model"] as? String, "music-model")
        XCTAssertEqual(try session.waitForMessage(requestID: musicRequestID, type: "audio.generated")["request_id"] as? String, musicRequestID)
        XCTAssertEqual(try session.waitForMessage(requestID: musicRequestID, type: "chat.completion.complete")["request_id"] as? String, musicRequestID)

        let chatInitRequestID = "req-chat-init"
        session.send([
            "type": "init",
            "backend": "vlm",
            "model_id": "chat-model",
            "request_id": chatInitRequestID
        ])
        XCTAssertEqual(try session.waitForMessage(requestID: chatInitRequestID, type: "model.loaded")["model"] as? String, "chat-model")
        XCTAssertEqual(try session.waitForMessage(requestID: chatInitRequestID, type: "model.initialized")["model"] as? String, "chat-model")

        let chatRequestID = "req-chat-complete"
        session.send([
            "type": "chat.completions",
            "model": "chat-model",
            "messages": [["role": "user", "content": "hello"]],
            "request_id": chatRequestID
        ])
        let chunk = try session.waitForMessage(requestID: chatRequestID, type: "chat.completion.chunk")
        XCTAssertEqual(chunk["request_id"] as? String, chatRequestID)
        let complete = try session.waitForMessage(requestID: chatRequestID, type: "chat.completion.complete")
        XCTAssertEqual(complete["request_id"] as? String, chatRequestID)
    }

    func testToolCallThenFollowupCompletionSameSession() throws {
        try writeLauncherScript()
        let session = try PersistentBridgeSession(scriptURL: launcherPath)
        defer { session.terminate() }

        XCTAssertEqual(session.readMessage()["type"] as? String, "system.ready")

        let initRequestID = "req-init"
        session.send([
            "type": "init",
            "backend": "vlm",
            "model_id": "chat-model",
            "request_id": initRequestID
        ])
        _ = try session.waitForMessage(requestID: initRequestID, type: "model.loaded")
        _ = try session.waitForMessage(requestID: initRequestID, type: "model.initialized")

        let toolRequestID = "req-tool-call"
        session.send([
            "type": "chat.completions",
            "model": "chat-model",
            "messages": [["role": "user", "content": "use a tool"]],
            "tools": [["type": "function", "function": ["name": "generate_music"]]],
            "request_id": toolRequestID
        ])
        let toolCallsMessage = try session.waitForMessage(requestID: toolRequestID, type: "chat.completion.tool_calls")
        let toolCalls = toolCallsMessage["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(toolCalls?.first?["id"] as? String, "tool-call-1")

        let followupRequestID = "req-followup"
        session.send([
            "type": "chat.completions",
            "model": "chat-model",
            "messages": [
                ["role": "user", "content": "use a tool"],
                ["role": "assistant", "tool_calls": toolCalls ?? []],
                ["role": "tool", "tool_call_id": "tool-call-1", "content": "done"]
            ],
            "request_id": followupRequestID
        ])

        _ = try session.waitForMessage(requestID: followupRequestID, type: "chat.completion.chunk")
        let complete = try session.waitForMessage(requestID: followupRequestID, type: "chat.completion.complete")
        let choices = complete["choices"] as? [[String: Any]]
        let firstChoice = choices?.first
        let message = firstChoice?["message"] as? [String: Any]
        XCTAssertEqual(message?["content"] as? String, "follow-up complete")
    }

    private func writeLauncherScript() throws {
        let resourcesPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MLXHub/Resources")
            .path
            .replacingOccurrences(of: "\\", with: "\\\\")

        let script = """
        import json
        import sys

        sys.path.insert(0, "\(resourcesPath)")
        import python_bridge

        def fake_load_model_if_needed(model_id, request=None):
            python_bridge.unload_models(keep_registry=python_bridge.MODEL_REGISTRY, keep_key=model_id)
            python_bridge.MODEL_REGISTRY[model_id] = ("model", "processor", {})
            python_bridge.send_json({"type": "model.loaded", "model": model_id}, request=request)
            return python_bridge.MODEL_REGISTRY[model_id]

        def fake_load_image_model_if_needed(model_id, edit=False, request=None):
            cache_key = f"{model_id}:{'edit' if edit else 'txt2img'}"
            python_bridge.unload_models(keep_registry=python_bridge.IMAGE_MODEL_REGISTRY, keep_key=cache_key)
            python_bridge.IMAGE_MODEL_REGISTRY[cache_key] = {"model": model_id, "edit": edit}
            python_bridge.send_json({"type": "model.loaded", "model": model_id}, request=request)
            return python_bridge.IMAGE_MODEL_REGISTRY[cache_key]

        def fake_load_audio_model_if_needed(model_id, request=None):
            python_bridge.unload_models(keep_registry=python_bridge.AUDIO_MODEL_REGISTRY, keep_key=model_id)
            python_bridge.AUDIO_MODEL_REGISTRY[model_id] = {"model": model_id}
            python_bridge.send_json({"type": "model.loaded", "model": model_id}, request=request)
            return python_bridge.AUDIO_MODEL_REGISTRY[model_id]

        def fake_load_music_model_if_needed(model_id, request=None):
            python_bridge.unload_models(keep_registry=python_bridge.MUSIC_MODEL_REGISTRY, keep_key=model_id)
            python_bridge.MUSIC_MODEL_REGISTRY[model_id] = ("dit", "llm")
            python_bridge.send_json({"type": "model.loaded", "model": model_id}, request=request)
            return python_bridge.MUSIC_MODEL_REGISTRY[model_id]

        def fake_handle_chat_completion(request):
            model_id = request.get("model")
            if model_id not in python_bridge.MODEL_REGISTRY:
                python_bridge.send_json({"type": "error", "message": "chat model not loaded"}, request=request)
                return
            if request.get("tools"):
                python_bridge.send_json(
                    {
                        "type": "chat.completion.tool_calls",
                        "tool_calls": [
                            {
                                "id": "tool-call-1",
                                "function": {
                                    "name": "generate_music",
                                    "arguments": json.dumps({"caption": "music please"})
                                }
                            }
                        ]
                    },
                    request=request,
                )
                return
            python_bridge.send_json(
                {
                    "type": "chat.completion.chunk",
                    "choices": [{"delta": {"content": "ok"}}]
                },
                request=request,
            )
            last_message = (request.get("messages") or [{}])[-1]
            content = "follow-up complete" if last_message.get("role") == "tool" else "chat complete"
            python_bridge.send_json(
                {
                    "type": "chat.completion.complete",
                    "choices": [{"message": {"content": content}}],
                    "usage": {"prompt_tokens": 0, "completion_tokens": 0}
                },
                request=request,
            )

        def fake_handle_image_generation(request):
            model_id = request.get("model")
            cache_key = f"{model_id}:txt2img"
            if cache_key not in python_bridge.IMAGE_MODEL_REGISTRY:
                python_bridge.send_json({"type": "error", "message": "image model not loaded"}, request=request)
                return
            python_bridge.send_json({"type": "image.generated", "path": "/tmp/generated-image.png"}, request=request)
            python_bridge.send_json(
                {
                    "type": "chat.completion.complete",
                    "choices": [{"message": {"content": "image complete"}}],
                    "usage": {"prompt_tokens": 0, "completion_tokens": 0}
                },
                request=request,
            )

        def fake_handle_music_generation(request):
            model_id = request.get("model")
            if model_id not in python_bridge.MUSIC_MODEL_REGISTRY:
                fake_load_music_model_if_needed(model_id, request=request)
            python_bridge.send_json({"type": "audio.generated", "path": "/tmp/generated-music.wav"}, request=request)
            python_bridge.send_json(
                {
                    "type": "chat.completion.complete",
                    "choices": [{"message": {"content": "music complete"}}],
                    "usage": {"prompt_tokens": 0, "completion_tokens": 0}
                },
                request=request,
            )

        python_bridge.load_model_if_needed = fake_load_model_if_needed
        python_bridge.load_image_model_if_needed = fake_load_image_model_if_needed
        python_bridge.load_audio_model_if_needed = fake_load_audio_model_if_needed
        python_bridge.load_music_model_if_needed = fake_load_music_model_if_needed
        python_bridge.handle_chat_completion = fake_handle_chat_completion
        python_bridge.handle_image_generation = fake_handle_image_generation
        python_bridge.handle_music_generation = fake_handle_music_generation

        python_bridge.main()
        """

        try script.write(to: launcherPath, atomically: true, encoding: .utf8)
    }
}

private final class PersistentBridgeSession {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private var lineBuffer = ""

    init(scriptURL: URL) throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path]
        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
    }

    func terminate() {
        stdinPipe.fileHandleForWriting.closeFile()
        if process.isRunning {
            process.terminate()
        }
    }

    func send(_ payload: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write("\n".data(using: .utf8)!)
    }

    func readMessage(timeout: TimeInterval = 2.0) -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let message = nextBufferedMessage() {
                return message
            }

            if !process.isRunning {
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                XCTFail("Bridge exited before sending message. stderr: \(stderr)")
                return [:]
            }

            let data = stdoutPipe.fileHandleForReading.availableData
            if data.isEmpty {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            lineBuffer += String(data: data, encoding: .utf8) ?? ""
        }

        XCTFail("Timed out waiting for bridge message")
        return [:]
    }

    func waitForMessage(requestID: String, type: String, timeout: TimeInterval = 2.0) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let message = readMessage(timeout: max(0.1, deadline.timeIntervalSinceNow))
            if message["request_id"] as? String == requestID, message["type"] as? String == type {
                return message
            }
        }

        throw NSError(domain: "BridgeProtocolSequenceTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for \(type) for request \(requestID)"
        ])
    }

    private func nextBufferedMessage() -> [String: Any]? {
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<newlineRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer.removeSubrange(...newlineRange.lowerBound)
            guard !line.isEmpty else { continue }
            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }
        return nil
    }
}
