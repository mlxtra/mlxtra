# MLXtra Models and Utilities Pre-Publish Review

## Scope

Reviewed every code file under `MLXtra/Models`, `MLXtra/Utilities`, and `Package.swift`.

Files reviewed: 18

- `Package.swift`
- `MLXtra/Models/AIModel.swift`
- `MLXtra/Models/Chat.swift`
- `MLXtra/Models/ModelCapabilityProfile.swift`
- `MLXtra/Models/ModelCatalog.swift`
- `MLXtra/Models/ModelStores.swift`
- `MLXtra/Models/PromptConfiguration.swift`
- `MLXtra/Models/Tool.swift`
- `MLXtra/Models/VersionComparator.swift`
- `MLXtra/Utilities/AudioPlayerCache.swift`
- `MLXtra/Utilities/ImageCache.swift`
- `MLXtra/Utilities/MarkdownAttributedRenderer.swift`
- `MLXtra/Utilities/MarkdownBlock.swift`
- `MLXtra/Utilities/MarkdownBlockRenderer.swift`
- `MLXtra/Utilities/MarkdownCache.swift`
- `MLXtra/Utilities/StreamingMarkdownInstrumentation.swift`
- `MLXtra/Utilities/StreamingMarkdownSplitter+Parsing.swift`
- `MLXtra/Utilities/StreamingMarkdownSplitter.swift`

## Counts By Severity

- P0: 0
- P1: 3
- P2: 7
- P3: 5
- Low-confidence notes: 3

Total findings: 15

## P0

No P0 findings.

## P1

### P1: Remote catalog/runtime state is marked `@unchecked Sendable` without synchronization

- File: `MLXtra/Models/ModelCatalog.swift:64`
- Confidence: high
- Why it matters: `ModelCatalogService` owns mutable `@Published` state and is globally shared, but the type opts out of sendability checking and is not `@MainActor` isolated. `refreshFromStableChannel` mutates `catalog` on the main actor while `profiles`, `profile(modelId:)`, and model-selection code can read it from nonisolated contexts. That is a real data-race risk under Swift strict concurrency and can produce inconsistent model lists or UI/state crashes.
- Concrete fix: Make `ModelCatalogService` `@MainActor` as a whole, or replace `@unchecked Sendable` with an actor/lock-backed immutable snapshot API. Keep all `catalog` reads and writes on the same isolation boundary.

### P1: Execution parameters are not clamped or rejected before reaching runtimes

- File: `MLXtra/Models/ModelStores.swift:72`
- Confidence: high
- Why it matters: `executionParameters(for:)` trusts persisted strings and preset values, then forwards typed values directly. `ModelParameterDefinition.typedValue(from:)` also converts invalid integers to `0` at `MLXtra/Models/ModelCapabilityProfile.swift:161`. Corrupt `UserDefaults`, stale presets, future catalog values, or manual settings edits can bypass declared ranges and send invalid sizes, durations, token counts, or seeds to Python runtimes. That can cause runtime errors, excessive memory use, or bad generation requests.
- Concrete fix: Add a validated typed conversion API that returns `nil` for invalid numeric strings and clamps numeric values to `range`. Use it in `executionParameters(for:)`, `setValue`, and `applyPreset`; add tests for out-of-range width, duration, max tokens, invalid integer strings, and invalid option values.

### P1: Runtime compatibility defaults to compatible when no manifest exists

- File: `MLXtra/Models/ModelCapabilityProfile.swift:415`
- Confidence: high
- Why it matters: `ModelRuntimeRequirement.isSatisfied(by:)` returns `true` when the manifest is nil at `MLXtra/Models/ModelCapabilityProfile.swift:309`, and `isRuntimeCompatible` also treats a missing manifest as supporting every backend. On a first launch, missing runtime, broken bundle, or failed manifest read, future catalog models can still appear selectable/recommended even though the runtime may not support them. That is publish-risky because users can be guided into downloads or runs that cannot work.
- Concrete fix: Separate "unknown runtime" from "compatible". For selection/recommendation, require a manifest when a model declares runtime requirements or backend support. If nil must remain allowed for tests, pass an explicit compatibility policy into recommendation APIs and default production paths to conservative filtering.

## P2

### P2: Catalog refresh accepts a catalog URL without validating the channel response status or URL scheme

- File: `MLXtra/Models/ModelCatalog.swift:103`
- Confidence: high
- Why it matters: `refreshFromStableChannel` does not check HTTP status for either the channel or catalog response and does not restrict `channel.catalog.url` to HTTPS. Runtime updates do status checks elsewhere, but catalog updates do not. Bad gateway/error bodies currently become generic decode failures, and a compromised/malformed channel can point catalog loading at a non-HTTPS URL while still providing a matching checksum in the same unsigned manifest.
- Concrete fix: Mirror `RuntimeUpdateManager.refreshStableChannel`: require 2xx responses, require `https` for release asset URLs, and surface a specific error. For stronger publish readiness, sign the channel manifest or pin catalog assets to the expected GitHub release host.

### P2: Streaming splitter ignores `committedEndIndex` unless a UTF-16 offset is also supplied

- File: `MLXtra/Utilities/StreamingMarkdownSplitter.swift:301`
- Confidence: high
- Why it matters: `splitStablePrefix` exposes both `committedEndIndex` and `committedUTF16Offset`, but `validatedStart` returns `rawText.startIndex` whenever the offset is absent, even if a valid `committedEndIndex` is provided. Any caller using the documented index-based API will rescan from the beginning and emit duplicate stable blocks.
- Concrete fix: Validate and use `committedEndIndex` when it belongs to `rawText`; keep UTF-16 offset only as a recovery fallback. Add a regression test that calls `splitStablePrefix` twice with only `newCommittedEndIndex`.

### P2: `StreamingMarkdownState.tailRange` can produce invalid `NSRange` locations

- File: `MLXtra/Utilities/StreamingMarkdownSplitter.swift:29`
- Confidence: medium
- Why it matters: The range length is clamped, but `location` is not. If text storage is reset, truncated, or replaced while `stableStorageEndLocation` is still larger than the current storage length, this returns `NSRange(location: oldLargeValue, length: 0)`. Passing that to `NSTextStorage` mutation APIs can raise an out-of-bounds exception.
- Concrete fix: Clamp the location too: `let location = min(stableStorageEndLocation, storageLength)`, then calculate length from that location. Add a small unit test for `stableStorageEndLocation > storageLength`.

### P2: Markdown cache keys can collide and render the wrong content

- File: `MLXtra/Utilities/MarkdownCache.swift:70`
- Confidence: medium
- Why it matters: Block caching uses a 64-bit djb2 hash of the raw markdown, and attributed caching uses Swift's `hashValue` at `MLXtra/Utilities/MarkdownCache.swift:82`. Neither key includes the original string, so collisions can return blocks or attributed strings for different messages. In chat history, that means user-visible content can be wrong until cache eviction.
- Concrete fix: Use the full text as part of the key, or use SHA-256 plus length and renderer/style fields. Avoid `hashValue` for cache identity because it is intentionally not a stable identity primitive.

### P2: Model catalog validation does not validate parameter definitions

- File: `MLXtra/Models/ModelCatalog.swift:179`
- Confidence: high
- Why it matters: Remote catalogs can define parameters with duplicate keys, invalid ranges, defaults outside ranges, option defaults not present in options, zero/negative steps, or unsupported combinations. The UI and runtime parameter store assume definitions are coherent. Bad catalog data can create broken controls or invalid runtime requests.
- Concrete fix: Extend `validate(_:)` to check unique parameter keys per profile, `range.lowerBound <= range.upperBound`, positive step for numeric controls, defaults parse for declared type, numeric defaults fit ranges, and option defaults are contained in `options` when options are non-empty.

### P2: `DownloadableModel.isRuntimeCompatible` reads the active runtime manifest twice

- File: `MLXtra/Models/ModelStores.swift:169`
- Confidence: medium
- Why it matters: The property calls `RuntimeManager.activeRuntimeManifest()` twice. If the active runtime changes or the manifest read is transiently unavailable between calls, the version check and backend check can evaluate different snapshots. It also duplicates I/O or parsing cost if the runtime manager reads from disk.
- Concrete fix: Capture once: `let manifest = RuntimeManager.activeRuntimeManifest()` and evaluate both checks against that same value. Prefer delegating to one shared compatibility helper to avoid drift from `ModelCapabilityProfile.isRuntimeCompatible`.

### P2: Final markdown rendering drops nested structure in lists and quotes

- File: `MLXtra/Utilities/MarkdownBlockRenderer.swift:53`
- Confidence: medium
- Why it matters: `plainText(item)` flattens each list item, and block quotes collect only direct child text. Nested lists, paragraphs inside list items, code blocks in quotes, and mixed block content are collapsed or lost. For model outputs, this can silently corrupt formatted instructions, code snippets, or citations in the final non-streaming render.
- Concrete fix: Convert nested block children recursively instead of flattening all list/quote content to strings, or keep raw markdown slices for complex list/quote nodes and pass them through the attributed markdown renderer.

## P3

### P3: `ModelCapabilityProfile.swift` mixes schema models, ranking logic, legacy catalog data, and parameter defaults in one large file

- File: `MLXtra/Models/ModelCapabilityProfile.swift:328`
- Confidence: high
- Why it matters: The file is large and carries several ownership boundaries: Codable schema types, hardware-fit logic, sort ranking, legacy built-ins, and parameter templates. That makes catalog changes high-risk because unrelated behavior is easy to touch accidentally.
- Concrete fix: Split into narrow files such as `ModelCapabilityProfile.swift`, `ModelParameterDefinition.swift`, `ModelRecommendation.swift`, and `LegacyModelCatalog.swift`. Keep this as a mechanical split with no behavior changes.

### P3: `PromptConfiguration` uses untyped `[String: Any]` for built-in tool definitions

- File: `MLXtra/Models/PromptConfiguration.swift:32`
- Confidence: high
- Why it matters: The current shape is easy to mistype and hard to validate. It also spreads JSON schema assumptions through dictionaries, so future tool additions can pass compile-time checks while failing at runtime.
- Concrete fix: Introduce small `Codable` structs for tool/function/parameter schema and generate dictionaries only at the API boundary. Add tests that encode the built-ins and validate required fields.

### P3: `MarkdownCacheKey` is dead code except for its version constant

- File: `MLXtra/Utilities/MarkdownCache.swift:6`
- Confidence: high
- Why it matters: The struct fields imply a richer cache identity, but the cache actually builds ad hoc string keys. This is confusing during renderer changes and makes it easy to forget to include style fields.
- Concrete fix: Either use `MarkdownCacheKey` as the actual cache key payload or replace it with a simple `enum MarkdownCacheVersion { static let current = 2 }`.

### P3: `Package.swift` imports Foundation only for manifest-time filesystem checks

- File: `Package.swift:2`
- Confidence: medium
- Why it matters: The package manifest dynamically checks for generated excludes. This works, but it makes the manifest behavior depend on local generated files. Publish/release builds can differ depending on whether `Resources/__pycache__` happens to exist.
- Concrete fix: Prefer a static `exclude` entry for generated directories if SwiftPM accepts missing excludes in this project, or document why the dynamic check is required. Add a package-resolution smoke test in clean checkout CI.

### P3: Instrumentation globals are always compiled into production

- File: `MLXtra/Utilities/StreamingMarkdownInstrumentation.swift:6`
- Confidence: medium
- Why it matters: The signpost wrappers are useful, but they add global production surface and subsystem strings even when profiling is not needed. It is low risk, but pre-publish cleanup should make intentional diagnostics boundaries clear.
- Concrete fix: Gate signpost calls behind a compile-time flag or a small runtime `isEnabled` check, unless production profiling is explicitly desired.

## Low-Confidence Notes

### Possible mutation-during-enumeration issue in attributed renderer

- File: `MLXtra/Utilities/MarkdownAttributedRenderer.swift:280`
- Confidence: low
- Why it matters: The code mutates `nsAttr` inside `enumerateAttributes`. This may be safe in practice for this API, but mutation while enumerating attributed string runs is easy to get wrong and could skip runs or behave differently across OS versions.
- Concrete fix: Collect missing-attribute ranges first, then apply mutations after enumeration, or use `addAttributes` over the full range before/after markdown parsing with explicit override rules.

### Full-text cache keys may retain large chat messages longer than desired

- File: `MLXtra/Utilities/MarkdownCache.swift:25`
- Confidence: low
- Why it matters: Fixing hash collisions by using full raw text as a key would increase memory retention. Current `NSCache` count limits help, but large messages can still stay alive.
- Concrete fix: If moving away from hashes, use SHA-256 plus length rather than the full text, and consider `totalCostLimit` based on string and attributed-string sizes.

### Version parser may accept malformed versions too leniently

- File: `MLXtra/Models/VersionComparator.swift:55`
- Confidence: low
- Why it matters: `ParsedVersion` maps nonnumeric components to `0` by taking numeric prefixes. Values like `fallback`, `1.x`, or `2beta` can compare as valid versions, which may hide bad catalog/runtime metadata.
- Concrete fix: Add a strict parser for catalog/runtime metadata validation and keep the tolerant comparator only where backward compatibility requires it.
