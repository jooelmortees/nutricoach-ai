import Foundation
import KeychainAccess
import Supabase

enum SharedConfiguration {
    static let appGroupIdentifier = "group.com.joelmortees.nutricoach"
    static let keychainService = "supabase.gotrue.swift"

    static var keychainAccessGroup: String {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "NutriCoachKeychainAccessGroup"
        ) as? String,
        !value.isEmpty,
        !value.contains("$(") else {
            preconditionFailure("Falta NutriCoachKeychainAccessGroup en Info.plist")
        }
        return value
    }
}

struct SharedAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let sharedStorage: Keychain
    private let legacyStorage: Keychain

    private var isAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    init() {
        sharedStorage = Keychain(
            service: SharedConfiguration.keychainService,
            accessGroup: SharedConfiguration.keychainAccessGroup
        ).accessibility(.afterFirstUnlock)
        legacyStorage = Keychain(
            service: SharedConfiguration.keychainService
        ).accessibility(.afterFirstUnlock)
    }

    func store(key: String, value: Data) throws {
        try sharedStorage.set(value, key: key)
        if !isAppExtension {
            try legacyStorage.set(value, key: key)
        }
    }

    func retrieve(key: String) throws -> Data? {
        if let sharedValue = try sharedStorage.getData(key) {
            return sharedValue
        }

        guard !isAppExtension,
              let legacyValue = try legacyStorage.getData(key) else {
            return nil
        }

        try sharedStorage.set(legacyValue, key: key)
        return legacyValue
    }

    func remove(key: String) throws {
        if isAppExtension {
            try sharedStorage.remove(key)
            return
        }
        try sharedStorage.remove(key)
        try legacyStorage.remove(key)
    }
}
