# Pre-Publish Review Findings

This file tracks repository-wide review findings while preparing MLXtra for publication. It intentionally includes low-confidence notes so they are not lost during parallel review.

## Fixed

- Legacy saved messages without `isStreaming` failed to decode, causing chat history load to fall back to an empty list.
- Debounced chat persistence did not clear a previously selected chat when saving `selectedChatId: nil`.
- Model catalog validation rejected duplicate `id` values but allowed duplicate `modelId` values with different profile IDs.
- Required built-in catalog merging only de-duplicated by profile `id`, not by executable `modelId`.
- Remote catalog refresh accepted non-HTTPS URLs and did not fail on non-2xx HTTP responses.
- Remote and built-in catalog validation did not reject malformed parameter metadata before it reached the UI.
- Catalog reads could observe mutable published state without a stable snapshot while refreshes were running.
- Persisted model parameter values could coerce invalid strings into surprising defaults such as `0` or `false`.
- Remembered model selections could return a runtime-incompatible profile.
- Runtime version comparison treated prerelease versions such as `0.2.0-beta` as equal to `0.2.0`.
- Streaming markdown reused `String.Index` values across string instances instead of recovering from a persisted UTF-16 offset.
- Streaming markdown tail slicing could crash if a stored tail range outlived the current buffer length.
- Markdown rendering cache keys relied on weak process-local hashing, making stale rendered output possible after collisions or relaunches.
- Runtime Python import validation drained stdout before stderr, which could deadlock if both pipes filled.
- Runtime archive installation did not reject absolute paths, parent traversal, or symlink escapes from downloaded archives.
- Runtime helper downloads did not reliably terminate subprocesses or resume continuations once when cancelled.
- Download status checks in `ModelDownloadManager` ignored test/cache override paths.
- Rapid duplicate sends could start more than one generation before `isGenerating` flipped.
- Generation cancellation and lifecycle cleanup could leave stale request state attached to later sends.
- The model row overflow menu allowed setting unavailable models as defaults.
- MCP web search prompts could trigger network search without explicit user opt-in.
- Media tool calls did not initialize executor state before dispatching generated media requests.
- Image lightbox force-unwrapped `NSScreen.main`.
- Generated image/audio attachment copies were not atomic and could expose save-panel content type mismatches.
- Audio playback fallback did not keep progress/completion/seek state in sync when `AVAudioPlayer` was unavailable.
- Settings used fixed panel dimensions that could overflow smaller windows.
- User-message cursor animation could leave overlapping tasks after repeated streaming state changes.
- Copy feedback tasks could outlive their message bubble view.
- Composer tool selector had duplicate accessibility identifiers.
- Welcome chips reused tool-based accessibility identifiers for multiple chat actions.
- Top-level bridge smoke tests could report success after import failure or miss current music completion event types.
- Bridge subprocess smoke tests and integration helpers could deadlock by reading stdout and stderr serially.
- Integration probes reported "all tests passed" even when model-dependent checks were skipped.
- Integration probes imported bridge helper logic by slicing implementation files instead of importing the shared helper module.
- Release asset option parsing accepted missing values for flags that require arguments.
- Runtime bundle build accepted a cached Python installer package without verifying its checksum.
- Release documentation did not make strict all-model integration and full runtime validation explicit pre-publish gates.

## Needs Triage

- `stable-channel.json` currently has an empty `runtimes` list. This is acceptable before publishing a remote runtime asset, but should be revisited for the first public release.
- Strict local model integration (`MLXTRA_REQUIRE_ALL_MODELS=1`) is now documented as a release gate, but still needs to be run on a machine with the full model cache before tagging.
- The manual Runtime Validation GitHub workflow was added to build and validate the runtime bundle from scratch, but it should be run once in GitHub Actions before the first public release.

## Review Slices

- `docs/prepublish-review/models-utilities.md`
- `docs/prepublish-review/services-viewmodels.md`
- `docs/prepublish-review/python-scripts-ci.md`
- `docs/prepublish-review/views-ui.md`
- `docs/prepublish-review/swift-tests.md`
