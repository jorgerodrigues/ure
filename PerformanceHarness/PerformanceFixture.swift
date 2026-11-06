import CoreGraphics
import CryptoKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

nonisolated enum PerformanceFixture {
    static let version = "W031-v1"
    static let date = 1_700_000_000.0

    static func id(_ kind: Int, _ index: Int) throws -> UUID {
        let text = String(format: "00000000-0000-4000-%04d-%012d", kind, index)
        guard let value = UUID(uuidString: text) else { throw PerformanceError.invalidFixture }
        return value
    }

    @concurrent
    static func seed(_ coordinator: LibraryCoordinator, directory: URL) async throws {
        let templates = try makeImages(in: directory)
        try await coordinator.mutate { db, originals, _ in
            for index in 0..<50 {
                try db.execute(
                    sql: """
                        INSERT INTO caliber (id, designation, createdAt, updatedAt, archivedAt)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        try id(1, index).uuidString, "Synthetic caliber \(index)", date, date,
                        index >= 45 ? date : nil,
                    ])
            }
            for index in 0..<500 {
                let watchID = try id(2, index).uuidString
                try db.execute(
                    sql: """
                        INSERT INTO watch (id, name, brand, serial, caliberID, createdAt, updatedAt, archivedAt)
                        VALUES (?, ?, 'Ühren', ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        watchID, "Synthetic watch \(index)", String(format: "00.%03d_%%'", index),
                        try id(1, index % 50).uuidString, date, date, index >= 450 ? date : nil,
                    ])
                for history in 0..<2 {
                    let jobIndex = index * 2 + history
                    let jobID = try id(3, jobIndex).uuidString
                    let open = history == 0 && index < 450
                    let stages = ["In progress", "Waiting"]
                    let stage = open ? stages[index % 2] : "Done"
                    try db.execute(
                        sql: """
                            INSERT INTO job (id, watchID, title, stage, problem, waitingFor, doneAt,
                                createdAt, updatedAt)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            jobID, watchID, "Synthetic job \(jobIndex)", stage,
                            "Loses time on the bench.", stage == "Waiting" ? "A mainspring" : nil,
                            open ? nil : date, date, date + Double(jobIndex),
                        ])
                    for position in 0..<10 {
                        try db.execute(
                            sql: """
                                INSERT INTO checklistStep (id, jobID, position, text, isHeading,
                                    isTicked, createdAt, updatedAt)
                                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                                """,
                            arguments: [
                                try id(4, jobIndex * 10 + position).uuidString, jobID, position,
                                position % 5 == 0
                                    ? "Stage \(position / 5)" : "Inspect movement \(position)",
                                position % 5 == 0, position % 5 >= 3, date,
                                date + Double(jobIndex + position),
                            ])
                    }
                    try seedChildren(db, jobID: jobID, index: jobIndex)
                }
            }
            for index in 0..<5_000 {
                let template = templates[index % templates.count]
                let assetID = try id(5, index)
                let key = assetID.uuidString + ".original"
                try FileManager.default.copyItem(
                    at: template.url, to: originals.appending(path: key))
                try FileAsset(
                    id: assetID, storageKey: key, originalFilename: "synthetic-\(index).jpg",
                    detectedType: .jpeg, byteCount: template.byteCount, sha256: template.sha256,
                    importedAt: Date(timeIntervalSince1970: date), pixelWidth: template.width,
                    pixelHeight: template.height, orientation: 1
                ).insert(db)
                let item = LibraryItem(
                    id: try id(6, index), owner: .job(try id(3, index / 5)), kind: .photo,
                    title: "Synthetic photo \(index) · Ühren movement, before cleaning", url: nil,
                    fileAssetID: assetID, createdAt: Date(timeIntervalSince1970: date),
                    updatedAt: Date(timeIntervalSince1970: date))
                try LibraryItemQueries.insert(item, in: db)
            }
            try db.execute(
                sql: """
                    UPDATE watch SET coverPhotoID = (
                        SELECT libraryItem.id FROM libraryItem JOIN job ON job.id = libraryItem.jobID
                        WHERE job.watchID = watch.id ORDER BY libraryItem.id LIMIT 1)
                    """)
            for table in SearchKey.Table.allCases { try SearchKey.backfill(table, in: db) }
        }
    }

    private static func seedChildren(_ db: Database, jobID: String, index: Int) throws {
        try db.execute(
            sql: "UPDATE job SET notes = ? WHERE id = ?",
            arguments: [
                "Synthetic notes \(index)\n"
                    + String(repeating: "Ühren inspection notes. ", count: 50), jobID,
            ])
        let partID = try id(8, index).uuidString
        try db.execute(
            sql: """
                INSERT INTO part (id, jobID, name, description, quantity, stage, createdAt,
                    updatedAt)
                VALUES (?, ?, ?, '00.A_%', 7, 'Needed', ?, ?)
                """,
            arguments: [partID, jobID, "Synthetic part \(index)", date, date + Double(index)])
        for position in 0..<2 {
            try db.execute(
                sql: """
                    INSERT INTO partLink (id, partID, position, url, createdAt, updatedAt)
                    VALUES (?, ?, ?, 'https://example.com/part', ?, ?)
                    """,
                arguments: [
                    try id(9, index * 2 + position).uuidString, partID, position, date, date,
                ])
        }
    }

    private struct Template: Sendable {
        let url: URL
        let width: Int
        let height: Int
        let byteCount: Int64
        let sha256: String
    }

    private static func makeImages(in directory: URL) throws -> [Template] {
        try [(640, 480), (2400, 1600), (6000, 4000)].enumerated().map { index, size in
            let (width, height) = size
            let url = directory.appending(path: "template-\(index).jpg")
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw PerformanceError.invalidFixture }
            for row in 0..<height {
                let shade = CGFloat(row % 251) / 250
                context.setFillColor(red: shade, green: 1 - shade, blue: 0.5, alpha: 1)
                context.fill(CGRect(x: 0, y: row, width: width, height: 1))
            }
            guard let image = context.makeImage(),
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw PerformanceError.invalidFixture }
            CGImageDestinationAddImage(
                destination, image,
                [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw PerformanceError.invalidFixture
            }
            let bytes = try Data(contentsOf: url)
            return Template(
                url: url, width: width, height: height, byteCount: Int64(bytes.count),
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }
    }
}
