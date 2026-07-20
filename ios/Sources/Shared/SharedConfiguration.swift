import Foundation
import KeychainAccess
import Supabase

enum SharedConfiguration {
    static let appGroupIdentifier = "group.com.joelmortees.nutricoach"
    static let keychainService = "supabase.gotrue.swift"
    static let authStorageKey = "sb-oqkctjzaojyevdxvavaj-auth-token"

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

enum NutriCoachWidgetKind {
    static let macros = "com.joelmortees.nutricoach.macros"
    static let water = "com.joelmortees.nutricoach.water"
    static let dailyTracking = [macros, water]
}

struct SharedAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let sharedStorage: Keychain
    private let legacyStorage: Keychain

    private func signOutMarkerKey(for key: String) -> String {
        "\(key).signed-out"
    }

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
        let markerKey = signOutMarkerKey(for: key)
        if isAppExtension {
            if try sharedStorage.getData(markerKey) != nil {
                return
            }
            try sharedStorage.set(value, key: key)
            return
        }

        try legacyStorage.set(value, key: key)
        try? legacyStorage.remove(markerKey)

        do {
            try sharedStorage.set(value, key: key)
            try sharedStorage.remove(markerKey)
        } catch {
            // Si la replica falla, impedir que el widget use una sesion
            // compartida anterior hasta que la app pueda sincronizarla.
            try? sharedStorage.set(Data([1]), key: markerKey)
        }
    }

    func retrieve(key: String) throws -> Data? {
        let markerKey = signOutMarkerKey(for: key)
        if isAppExtension {
            if try sharedStorage.getData(markerKey) != nil {
                return nil
            }
            return try sharedStorage.getData(key)
        }

        if try legacyStorage.getData(markerKey) != nil {
            try? sharedStorage.set(Data([1]), key: markerKey)
            try? legacyStorage.remove(key)
            try? sharedStorage.remove(key)
            return nil
        }

        let legacyValue = try legacyStorage.getData(key)
        let sharedIsSignedOut = (try? sharedStorage.getData(markerKey)) != nil
        let sharedValue = sharedIsSignedOut ? nil : try? sharedStorage.getData(key)

        let preferredValue: Data?
        switch (sharedValue, legacyValue) {
        case let (.some(shared), .some(legacy)):
            let decoder = JSONDecoder()
            let sharedSession = try? decoder.decode(Session.self, from: shared)
            let legacySession = try? decoder.decode(Session.self, from: legacy)
            if let sharedSession, let legacySession {
                if sharedSession.user.id != legacySession.user.id {
                    preferredValue = legacy
                } else if legacySession.expiresAt > sharedSession.expiresAt {
                    preferredValue = legacy
                } else {
                    preferredValue = shared
                }
            } else {
                preferredValue = shared
            }
        case let (.some(shared), .none):
            preferredValue = shared
        case let (.none, .some(legacy)):
            preferredValue = legacy
        case (.none, .none):
            return nil
        }

        guard let preferredValue else { return nil }
        try legacyStorage.set(preferredValue, key: key)
        do {
            try sharedStorage.set(preferredValue, key: key)
            try sharedStorage.remove(markerKey)
        } catch {
            try? sharedStorage.set(Data([1]), key: markerKey)
        }
        return preferredValue
    }

    func remove(key: String) throws {
        let markerKey = signOutMarkerKey(for: key)
        if isAppExtension {
            var firstError: Error?
            do {
                try sharedStorage.set(Data([1]), key: markerKey)
            } catch {
                firstError = error
            }
            do {
                try sharedStorage.remove(key)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
            if let firstError {
                throw firstError
            }
            return
        }

        var firstError: Error?
        let operations: [() throws -> Void] = [
            { try legacyStorage.set(Data([1]), key: markerKey) },
            { try sharedStorage.set(Data([1]), key: markerKey) },
            { try legacyStorage.remove(key) },
            { try sharedStorage.remove(key) }
        ]

        for operation in operations {
            do {
                try operation()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    func isSharedSessionCleared(key: String) throws -> Bool {
        if try sharedStorage.getData(signOutMarkerKey(for: key)) != nil {
            return true
        }
        return try sharedStorage.getData(key) == nil
    }
}
