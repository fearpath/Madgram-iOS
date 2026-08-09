import Foundation
import SwiftSignalKit
import TelegramCore

private struct HiddenGiftsCatalogResponse: Decodable {
    let data: [HiddenGiftCatalogItem]
}

private struct HiddenGiftCatalogItem: Decodable {
    struct Title: Decodable {
        let ru: String?
        let en: String?
    }

    struct Asset: Decodable {
        let tgsUrl: String
        let pngUrl: String
        let mimeType: String
    }

    let id: String
    let title: Title
    let emoji: String
    let stars: String
    let status: String
    let asset: Asset
}

struct HiddenGiftsCatalogStrings {
    let tabTitle: String
    let description: String

    init(languageCode: String) {
        let normalizedLanguageCode = languageCode
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? "en"

        switch normalizedLanguageCode {
        case "ru":
            self.tabTitle = "Скрытые"
            self.description = "Подарки, скрытые из обычного каталога. Доступность проверяется перед отправкой."
        case "uk":
            self.tabTitle = "Приховані"
            self.description = "Подарунки, приховані зі звичайного каталогу. Доступність перевіряється перед надсиланням."
        default:
            self.tabTitle = "Hidden"
            self.description = "Gifts hidden from the regular catalog. Availability is checked before sending."
        }
    }
}

private func validatedCatalogUrl(_ value: String, expectedPathSuffix: String) -> URL? {
    guard let url = URL(string: value), url.scheme == "https", url.host == "gifts.mad.tg", url.path.hasSuffix(expectedPathSuffix) else {
        return nil
    }
    return url
}

private func makeHiddenStarGifts(data: Data, languageCode: String) -> [StarGift] {
    guard let response = try? JSONDecoder().decode(HiddenGiftsCatalogResponse.self, from: data) else {
        return []
    }

    let normalizedLanguageCode = languageCode
        .lowercased()
        .split(whereSeparator: { $0 == "-" || $0 == "_" })
        .first
        .map(String.init) ?? "en"
    var giftIds = Set<Int64>()
    var result: [StarGift] = []

    for item in response.data.prefix(1000) {
        guard item.status == "hidden", item.asset.mimeType == "application/x-tgsticker", let id = Int64(item.id), let stars = Int64(item.stars), stars > 0, giftIds.insert(id).inserted else {
            continue
        }
        guard let tgsUrl = validatedCatalogUrl(item.asset.tgsUrl, expectedPathSuffix: "/original"), let pngUrl = validatedCatalogUrl(item.asset.pngUrl, expectedPathSuffix: "/preview.png") else {
            continue
        }

        let localizedTitle: String
        if normalizedLanguageCode == "ru", let title = item.title.ru, !title.isEmpty {
            localizedTitle = title
        } else if let title = item.title.en, !title.isEmpty {
            localizedTitle = title
        } else if let title = item.title.ru, !title.isEmpty {
            localizedTitle = title
        } else {
            localizedTitle = item.emoji
        }

        let previewRepresentation = TelegramMediaImageRepresentation(
            dimensions: PixelDimensions(width: 512, height: 512),
            resource: HttpReferenceMediaResource(url: pngUrl.absoluteString, size: nil),
            progressiveSizes: [],
            immediateThumbnailData: nil
        )
        let file = TelegramMediaFile(
            fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: id),
            partialReference: nil,
            resource: HttpReferenceMediaResource(url: tgsUrl.absoluteString, size: nil),
            previewRepresentations: [previewRepresentation],
            videoThumbnails: [],
            immediateThumbnailData: nil,
            mimeType: item.asset.mimeType,
            size: nil,
            attributes: [
                .FileName(fileName: "\(id).tgs"),
                .Sticker(displayText: item.emoji, packReference: nil, maskData: nil),
                .ImageSize(size: PixelDimensions(width: 512, height: 512))
            ],
            alternativeRepresentations: []
        )
        let gift = StarGift.Gift(
            id: id,
            title: String(localizedTitle.prefix(128)),
            file: file,
            price: stars,
            convertStars: stars * 85 / 100,
            availability: nil,
            soldOut: nil,
            flags: [],
            upgradeStars: nil,
            releasedBy: nil,
            perUserLimit: nil,
            lockedUntilDate: nil,
            auctionSlug: nil,
            auctionGiftsPerRound: nil,
            auctionStartDate: nil,
            upgradeVariantsCount: nil,
            background: nil
        )
        result.append(.generic(gift))
    }

    return result
}

func hiddenStarGiftsCatalog(languageCode: String) -> Signal<[StarGift], NoError> {
    return Signal { subscriber in
        guard let url = URL(string: "https://gifts.mad.tg/v1/gifts") else {
            subscriber.putNext([])
            subscriber.putCompletion()
            return EmptyDisposable
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = 15.0
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let gifts: [StarGift]
            if let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode), let data {
                gifts = makeHiddenStarGifts(data: data, languageCode: languageCode)
            } else {
                gifts = []
            }
            Queue.mainQueue().async {
                subscriber.putNext(gifts)
                subscriber.putCompletion()
            }
        }
        task.resume()

        return ActionDisposable {
            task.cancel()
        }
    }
}
