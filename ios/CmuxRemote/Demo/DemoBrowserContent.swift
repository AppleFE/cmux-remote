import Foundation

extension DemoBrowserFixture {
    static let demoURL = "https://example.test/cmux-browser"

    static func fixture(url: String = demoURL) -> DemoBrowserFixture {
        DemoBrowserFixture(
            url: url,
            dataBase64: tinyPNGBase64,
            width: 1,
            height: 1,
            capturedAt: "2026-06-21T00:00:00Z"
        )
    }

    func withURL(_ nextURL: String) -> DemoBrowserFixture {
        DemoBrowserFixture(
            url: nextURL,
            dataBase64: dataBase64,
            width: width,
            height: height,
            capturedAt: capturedAt
        )
    }

    private static let tinyPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
}
