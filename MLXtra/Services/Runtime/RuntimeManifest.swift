import Foundation

struct RuntimeImageRuntimes: Codable, Equatable {
    let mflux: RuntimeMFluxCapabilities?

    init(mflux: RuntimeMFluxCapabilities? = nil) {
        self.mflux = mflux
    }
}

struct RuntimeMFluxCapabilities: Codable, Equatable {
    let configs: [String]
    let classes: [String]
    let quantizeBits: [Int]

    init(configs: [String] = [], classes: [String] = [], quantizeBits: [Int] = []) {
        self.configs = configs
        self.classes = classes
        self.quantizeBits = quantizeBits
    }

    func supports(_ options: MFluxRuntimeOptions) -> Bool {
        if !configs.isEmpty && !configs.contains(options.config) {
            return false
        }
        if !classes.isEmpty {
            guard classes.contains(options.textToImageClass),
                  classes.contains(options.editClass) else {
                return false
            }
        }
        if let quantize = options.quantize,
           !quantizeBits.isEmpty,
           !quantizeBits.contains(quantize) {
            return false
        }
        return true
    }
}

struct RuntimeAudioRuntimes: Codable, Equatable {
    let adapters: [String]

    init(adapters: [String] = []) {
        self.adapters = adapters
    }

    func supports(_ options: AudioRuntimeOptions) -> Bool {
        adapters.isEmpty || adapters.contains(options.adapter)
    }
}

struct RuntimeManifest: Codable, Equatable {
    let runtimeVersion: String
    let compatibilityApi: Int
    let platform: String
    let arch: String
    let channel: String?
    let pythonVersion: String?
    let pythonPath: String?
    let executables: [String: String]?
    let packages: [String]
    let isolatedPackages: [String]
    let supportedModels: [String]?
    let supportedBackends: [RuntimeBackend]
    let capabilities: [String]
    let imageRuntimes: RuntimeImageRuntimes?
    let audioRuntimes: RuntimeAudioRuntimes?

    init(
        runtimeVersion: String,
        compatibilityApi: Int,
        platform: String = "macos",
        arch: String = "arm64",
        channel: String? = "stable",
        pythonVersion: String? = nil,
        pythonPath: String? = nil,
        executables: [String: String]? = nil,
        packages: [String] = [],
        isolatedPackages: [String] = [],
        supportedModels: [String]? = nil,
        supportedBackends: [RuntimeBackend] = [],
        capabilities: [String] = [],
        imageRuntimes: RuntimeImageRuntimes? = nil,
        audioRuntimes: RuntimeAudioRuntimes? = nil
    ) {
        self.runtimeVersion = runtimeVersion
        self.compatibilityApi = compatibilityApi
        self.platform = platform
        self.arch = arch
        self.channel = channel
        self.pythonVersion = pythonVersion
        self.pythonPath = pythonPath
        self.executables = executables
        self.packages = packages
        self.isolatedPackages = isolatedPackages
        self.supportedModels = supportedModels
        self.supportedBackends = supportedBackends
        self.capabilities = capabilities
        self.imageRuntimes = imageRuntimes
        self.audioRuntimes = audioRuntimes
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeVersion
        case compatibilityApi
        case platform
        case arch
        case channel
        case pythonVersion
        case pythonPath
        case executables
        case packages
        case isolatedPackages
        case supportedModels
        case supportedBackends
        case capabilities
        case imageRuntimes
        case audioRuntimes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtimeVersion = try container.decode(String.self, forKey: .runtimeVersion)
        compatibilityApi = try container.decode(Int.self, forKey: .compatibilityApi)
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? "macos"
        arch = try container.decodeIfPresent(String.self, forKey: .arch) ?? "arm64"
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        pythonVersion = try container.decodeIfPresent(String.self, forKey: .pythonVersion)
        pythonPath = try container.decodeIfPresent(String.self, forKey: .pythonPath)
        executables = try container.decodeIfPresent([String: String].self, forKey: .executables)
        packages = try container.decodeIfPresent([String].self, forKey: .packages) ?? []
        isolatedPackages = try container.decodeIfPresent([String].self, forKey: .isolatedPackages) ?? []
        supportedModels = try container.decodeIfPresent([String].self, forKey: .supportedModels)
        supportedBackends = try container.decodeIfPresent([RuntimeBackend].self, forKey: .supportedBackends) ?? []
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        imageRuntimes = try container.decodeIfPresent(RuntimeImageRuntimes.self, forKey: .imageRuntimes)
        audioRuntimes = try container.decodeIfPresent(RuntimeAudioRuntimes.self, forKey: .audioRuntimes)
    }

    func supports(backend: RuntimeBackend) -> Bool {
        if supportedBackends.isEmpty {
            return true
        }
        return supportedBackends.contains(backend)
    }

    func supports(profile: ModelCapabilityProfile) -> Bool {
        profile.runtime.isSatisfied(by: self)
            && supports(backend: profile.backend)
            && supports(runtimeOptions: profile.runtimeOptions)
            && (supportedModels?.contains(profile.modelId) ?? true)
    }

    func supports(runtimeOptions: ModelRuntimeOptions?) -> Bool {
        guard let runtimeOptions else {
            return true
        }
        if let mflux = runtimeOptions.mflux {
            guard let capabilities = imageRuntimes?.mflux else {
                return true
            }
            guard capabilities.supports(mflux) else {
                return false
            }
        }
        if let audio = runtimeOptions.audio,
           let capabilities = audioRuntimes,
           !capabilities.supports(audio) {
            return false
        }
        return true
    }
}
