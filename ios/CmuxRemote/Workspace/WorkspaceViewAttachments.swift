import Foundation
import PhotosUI
import SwiftUI
import UIKit

extension WorkspaceView {
    func attachPhoto(_ item: PhotosPickerItem) async {
        attachmentInFlight = true
        defer {
            attachmentInFlight = false
            selectedPhotoItem = nil
        }
        do {
            guard let rawData = try await item.loadTransferable(type: Data.self) else { return }
            let prepared = prepareImageAttachment(rawData)
            let uploaded = try await surfaceStore.uploadFile(
                data: prepared.data,
                filename: prepared.filename,
                mimeType: prepared.mimeType
            )
            await MainActor.run {
                appendPathToDraft(uploaded.path)
                commandFieldFocused = true
                composer.clearError()
            }
        } catch {
            await MainActor.run { composer.failSubmit(error) }
        }
    }

    func prepareImageAttachment(_ data: Data) -> (data: Data, filename: String, mimeType: String) {
        let timestamp = Self.attachmentTimestamp()
        if let image = UIImage(data: data) {
            let preparedImage = image.cmuxDownscaled(maxDimension: Self.attachmentMaxDimension)
            var fallbackJPEG: Data?
            for quality in Self.attachmentJPEGQualities {
                guard let jpeg = preparedImage.jpegData(compressionQuality: quality) else { continue }
                fallbackJPEG = jpeg
                if jpeg.count <= Self.preferredAttachmentMaxBytes {
                    return (jpeg, "iphone-image-\(timestamp).jpg", "image/jpeg")
                }
            }
            if let fallbackJPEG {
                return (fallbackJPEG, "iphone-image-\(timestamp).jpg", "image/jpeg")
            }
        }
        return (data, "iphone-image-\(timestamp).jpg", "image/jpeg")
    }

    func appendPathToDraft(_ path: String) {
        if composer.draft.isEmpty || composer.draft.hasSuffix(" ") || composer.draft.hasSuffix("\n") {
            composer.insert(path)
        } else {
            composer.insert(" \(path)")
        }
    }

    static func attachmentTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
