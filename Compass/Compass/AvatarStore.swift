//
//  AvatarStore.swift
//  Compass
//
//  Per-person profile images, stored on-device (keyed by the user's id). Images
//  are too large for our JSON dev server, so these stay local for now; a future
//  version could sync them via object storage. Falls back to colored initials.
//

import SwiftUI
import UIKit

@Observable
@MainActor
final class AvatarStore {
    private var cache: [String: UIImage] = [:]
    private let dir: URL

    init() {
        dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func image(for userId: String) -> UIImage? {
        if let img = cache[userId] { return img }
        let url = dir.appendingPathComponent("\(userId).jpg")
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            cache[userId] = img
            return img
        }
        return nil
    }

    func setImage(_ image: UIImage, for userId: String) {
        cache[userId] = image
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: dir.appendingPathComponent("\(userId).jpg"))
        }
    }

    func hasImage(for userId: String) -> Bool {
        image(for: userId) != nil
    }

    /// Remove a custom photo, reverting to the colored initials avatar.
    func removeImage(for userId: String) {
        cache.removeValue(forKey: userId)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(userId).jpg"))
    }
}

/// A circular avatar: the person's photo if set, otherwise their initials on a
/// color derived from their name.
struct AvatarView: View {
    @Environment(AvatarStore.self) private var avatars
    let userId: String
    let name: String
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let img = avatars.image(for: userId) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(color)
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    private var color: Color {
        // Stable hue from the name (Swift's hashValue isn't stable across runs).
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Color(hue: Double(sum % 360) / 360, saturation: 0.55, brightness: 0.75)
    }
}
