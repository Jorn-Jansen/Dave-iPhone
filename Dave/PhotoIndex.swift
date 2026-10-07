import Photos
import UIKit
import Vision

/// "Find my photos of a dog": what's in each photo, recognised on the iPhone itself with Apple's image recognition
/// (Vision), the kind the Photos app uses. Nothing leaves the phone and it costs no AI. The first search looks at every
/// photo once (about half a minute for a thousand); what's in them is remembered, so later searches only look at new ones.
actor PhotoIndex {
    static let shared = PhotoIndex()

    /// Per photo (its id in the library): the things recognised in it, with how sure (0…1).
    private var labels: [String: [String: Float]] = [:]
    private var loaded = false
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("photo-labels.json")

    struct Match {
        let asset: PHAsset
        let sureness: Float
    }

    /// Photos showing one of [terms] ("dog", "puppy"), best and newest first. [progress] reports (done, total) while
    /// photos that weren't looked at before are being looked at.
    func search(_ terms: [String], progress: @escaping @Sendable (Int, Int) -> Void) async -> [Match] {
        load()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let all = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        all.enumerateObjects { asset, _, _ in assets.append(asset) }

        // Look at the photos that are new since last time
        let missing = assets.filter { labels[$0.localIdentifier] == nil }
        var done = 0
        for chunk in stride(from: 0, to: missing.count, by: 8).map({ Array(missing[$0..<min($0 + 8, missing.count)]) }) {
            if Task.isCancelled { break }
            let found = await withTaskGroup(of: (String, [String: Float]).self) { group in
                for asset in chunk { group.addTask { (asset.localIdentifier, await Self.recognise(asset)) } }
                var results: [(String, [String: Float])] = []
                for await result in group { results.append(result) }
                return results
            }
            for (id, things) in found { labels[id] = things }
            done += chunk.count
            progress(done, missing.count)
            if done % 200 < 8 { save() }
        }
        if !missing.isEmpty { save() }

        // Photos showing one of the terms ("dog" also finds "dog_breed"-style labels)
        let wanted = terms.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var matches: [Match] = []
        for asset in assets {
            guard let things = labels[asset.localIdentifier] else { continue }
            let best = things.filter { label, _ in wanted.contains { label == $0 || label.hasPrefix($0 + "_") || label.hasSuffix("_" + $0) } }
                .values.max() ?? 0
            if best >= 0.35 { matches.append(Match(asset: asset, sureness: best)) }
        }
        return matches // already newest first
    }

    /// What's in one photo: Apple's image recognition on a small version of it.
    private static func recognise(_ asset: PHAsset) async -> [String: Float] {
        guard let image = await thumbnail(asset), let cgImage = image.cgImage else { return [:] }
        let request = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch { return [:] }
        var things: [String: Float] = [:]
        for observation in request.results ?? [] where observation.confidence >= 0.2 {
            things[observation.identifier] = observation.confidence
        }
        return things
    }

    private static func thumbnail(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { done in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat // one answer, not a blurry one first
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true // photos that are only in iCloud
            options.isSynchronous = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 360, height: 360), contentMode: .aspectFit,
                                                  options: options) { image, _ in done.resume(returning: image) }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: [String: Float]].self, from: data) { labels = saved }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(labels) { try? data.write(to: file, options: .atomic) }
    }
}
