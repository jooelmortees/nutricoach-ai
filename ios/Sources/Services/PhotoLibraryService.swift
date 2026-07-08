// ============================================================
// PhotoLibraryService - acceso a la galería del dispositivo.
// Carga las N fotos más recientes como miniaturas (PHAsset + UIImage)
// sin pasar por el PhotosPicker del sistema.
// ============================================================

import Foundation
import Photos
import UIKit

@MainActor
final class PhotoLibraryService: ObservableObject {
    /// Miniatura cargada desde la galería (asset + imagen ya decodificada).
    struct RecentPhoto: Identifiable, Equatable {
        let id: String        // localIdentifier del PHAsset
        let asset: PHAsset
        let thumbnail: UIImage

        static func == (lhs: RecentPhoto, rhs: RecentPhoto) -> Bool {
            lhs.id == rhs.id
        }
    }

    static let shared = PhotoLibraryService()

    @Published private(set) var recentPhotos: [RecentPhoto] = []
    @Published private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var isLoading: Bool = false

    private init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Solicita (si hace falta) permiso de lectura y carga las miniaturas
    /// más recientes. Devuelve true si acabó con acceso (authorized o limited).
    @discardableResult
    func requestAccessAndLoadRecent(limit: Int = 12) async -> Bool {
        var status = authorizationStatus
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            authorizationStatus = status
        }
        switch status {
        case .authorized, .limited:
            await loadRecentPhotos(limit: limit)
            return true
        default:
            return false
        }
    }

    /// Carga las `limit` fotos más recientes como miniaturas.
    /// Ordenadas por creationDate descendente (lo más nuevo primero).
    func loadRecentPhotos(limit: Int = 12) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let options = PHFetchOptions()
        options.fetchLimit = limit
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %ld", PHAssetMediaType.image.rawValue)

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        // Carga cada miniatura en background y actualiza en MainActor.
        // .highQualityFormat garantiza una única entrega con la mejor
        // calidad disponible (evita cuelgues si solo llegase la degradada).
        let manager = PHImageManager.default()
        let targetSize = CGSize(width: 200, height: 200)
        let requestOptions = PHImageRequestOptions()
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.resizeMode = .fast
        requestOptions.isSynchronous = false
        requestOptions.isNetworkAccessAllowed = true

        var loaded: [RecentPhoto] = []
        for asset in assets {
            let image = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                manager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFill,
                    options: requestOptions
                ) { image, _ in
                    continuation.resume(returning: image)
                }
            }
            if let image {
                loaded.append(RecentPhoto(id: asset.localIdentifier, asset: asset, thumbnail: image))
                // Actualización incremental para que la UI pinte conforme llegan
                recentPhotos = loaded
            }
        }
    }

    /// Descarga la imagen original (full-resolution) de un asset para subirla al chat.
    func fetchFullImageData(for asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let image = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .default,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image else { return nil }
        return image.jpegData(compressionQuality: 0.85)
    }
}