// ============================================================
// PlusMenuSheet - bottom sheet que abre el botón "+".
//
// Contiene ÚNICAMENTE:
//   1. Cabecera: X (cerrar) a la izquierda, "Todas las fotos" a la derecha.
//   2. Fila horizontal desplazable: botón cuadrado "Cámara" + miniaturas
//      de las fotos recientes de la galería (mismo tamaño que el botón cámara).
//   3. Fila inferior: icono globo + "Búsqueda web" + toggle iOS azul.
//
// Fondo oscuro semitransparente, esquinas superiores redondeadas.
// Sin opciones de ficheros/proyectos/herramientas.
// ============================================================

import SwiftUI
import Photos

struct PlusMenuSheet: View {
    /// Toggle de búsqueda web (binding bidireccional con la vista padre).
    @Binding var webSearchEnabled: Bool
    /// Service de galería (observable para re-renderizar al cargar miniaturas).
    @ObservedObject var photoLibrary: PhotoLibraryService
    /// Se invoca al pulsar el botón "Cámara".
    var onOpenCamera: () -> Void
    /// Se invoca al pulsar "Todas las fotos" (abre PhotosPicker completo).
    var onOpenFullGallery: () -> Void
    /// Se invoca al tocar una miniatura reciente (devuelve el PHAsset).
    var onPickRecent: (PHAsset) -> Void
    /// Se invoca al pulsar la X de cerrar.
    var onClose: () -> Void

    private let fondoOscuro = Color(red: 0.10, green: 0.10, blue: 0.10)   // carbón opaco
    private let textoClaro = Color(red: 0.90, green: 0.90, blue: 0.90)   // #e5e5e5
    private let grisMedio = Color(red: 0.54, green: 0.54, blue: 0.54)    // #8a8a8a
    private let tarjetaFondo = Color(red: 0.18, green: 0.18, blue: 0.18)

    private let tileSize: CGFloat = 72
    private let tileRadius: CGFloat = 14

    var body: some View {
        VStack(spacing: 16) {
            // 1. Cabecera
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(textoClaro)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Cerrar")
                Spacer()
                Button(action: onOpenFullGallery) {
                    Text("Todas las fotos")
                        .font(.subheadline)
                        .foregroundStyle(grisMedio)
                }
                .accessibilityLabel("Abrir galería completa")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            // 2. Fila horizontal: cámara + miniaturas recientes
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Botón cámara (cuadrado, esquinas redondeadas)
                    Button(action: onOpenCamera) {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: tileRadius)
                                    .fill(tarjetaFondo)
                                    .frame(width: tileSize, height: tileSize)
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(textoClaro)
                            }
                            Text("Cámara")
                                .font(.caption2)
                                .foregroundStyle(grisMedio)
                        }
                    }
                    .accessibilityLabel("Abrir cámara")

                    // Miniaturas recientes
                    ForEach(photoLibrary.recentPhotos) { photo in
                        Button {
                            onPickRecent(photo.asset)
                        } label: {
                            Image(uiImage: photo.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: tileSize, height: tileSize)
                                .clipShape(RoundedRectangle(cornerRadius: tileRadius))
                        }
                        .accessibilityLabel("Foto reciente")
                    }

                    // Estado vacío (sin permisos o galería vacía)
                    if photoLibrary.recentPhotos.isEmpty {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: tileRadius)
                                    .fill(tarjetaFondo)
                                    .frame(width: tileSize, height: tileSize)
                                if photoLibrary.isLoading {
                                    ProgressView()
                                        .tint(textoClaro)
                                } else {
                                    Image(systemName: "photo")
                                        .font(.system(size: 22))
                                        .foregroundStyle(grisMedio)
                                }
                            }
                            Text("Sin fotos")
                                .font(.caption2)
                                .foregroundStyle(grisMedio)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            // 3. Separador
            Rectangle()
                .fill(grisMedio.opacity(0.25))
                .frame(height: 0.5)
                .padding(.horizontal, 20)

            // 4. Fila inferior: búsqueda web con toggle iOS
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 18))
                    .foregroundStyle(textoClaro)
                Text("Búsqueda web")
                    .font(.subheadline)
                    .foregroundStyle(textoClaro)
                Spacer()
                Toggle("", isOn: $webSearchEnabled)
                    .labelsHidden()
                    .tint(.blue)
                    .accessibilityLabel("Activar búsqueda web")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(fondoOscuro)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}