import Foundation

public struct Session: Codable {
   /// A combination of year and code that uniquely identifies the session.
   public let id: String

   /// Example: `2023`
   public let year: Int

   /// Example: `"10187"`
   public let code: String

   /// Example: `"Meet SwiftData"`
   public let title: String

   /// Example: `"SwiftData is a powerful and expressive persistence framework built for Swift. We’ll show you how you can model your data directly from Swift code, use SwiftData to work with your models, and integrate with SwiftUI."`
   public let description: String

   /// Example: `"https://developer.apple.com/wwdc23/10187"`
   public let permalink: URL?

   /// Example: `8`
   public let lengthInMinutes: Int?

   /// Example: `["wwdc2023-10148", "wwdc2023-10149", "wwdc2023-10154"]`
   public let relatedSessionIDs: [String]

   /// Example: `WWDC23-10187-Meet-SwiftData`
   public var fileName: String {
      let yearPrefix = "WWDC\(self.year - 2000)"
      let normalizedTitle = self.title
         .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en-US"))
         .components(separatedBy: .whitespacesAndNewlines)
         .joined(separator: "-")

      return "\(yearPrefix)-\(code)-\(normalizedTitle)"
   }

   public static func allSessionsByID() throws -> [String: Session] {
      let dataSourceURL = Bundle.module.url(forResource: "sessions", withExtension: "json")!
      let sessionsData = try Data(contentsOf: dataSourceURL)
      return try JSONDecoder().decode([String: Session].self, from: sessionsData)
   }
}