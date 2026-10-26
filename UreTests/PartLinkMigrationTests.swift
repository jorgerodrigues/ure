import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct PartLinkMigrationTests {
    @Test
    func migrationKeepsLinkURLsAndRemovesSupplierDetailsAndOrderCopies() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        let before = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.manufacturerReference = "0012.3–Å/04"
        draft.links = [
            PartLinkDraft(url: "https://example.org/parts/0012?variant=A"),
            PartLinkDraft(url: "https://example.net/alternate"),
        ]
        let needed = try await service.save(draft, for: job.id, editing: nil)
        var order = PartDraft(part: needed)
        order.status = .ordered
        order.orderReference = "PO-1"
        let ordered = try await service.save(order, for: job.id, editing: needed.id)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        let snapshot =
            #"{"currency":"DKK","price":"12.3400","supplierName":"Supplier Å時計","supplierStockCode":"STOCK-77","url":"https://example.org/parts/0012?variant=A"}"#
        try await coordinator.mutate { db, _, _ in
            try PartLinkMigrationFixture.restoreSupplierOptions(in: db)
            try db.execute(
                sql: """
                    UPDATE partLink SET title = 'Listing', supplierName = 'Supplier Å時計',
                        supplierStockCode = 'STOCK-77', currency = 'DKK', price = '12.3400',
                        notes = 'Old stock', searchKey = 'stock-77'
                    """)
            try db.execute(sql: "UPDATE partLink SET isSelected = 1 WHERE position = 0")
            try db.execute(
                sql: """
                    UPDATE partRequirement
                    SET supplierSnapshot = ?, searchKey = searchKey || char(10) || 'stock-77'
                    """, arguments: [snapshot])
            for column in ["priorValue", "nextValue"] {
                try db.execute(
                    sql: """
                        UPDATE activityEvent
                        SET \(column) = json_set(\(column), '$.part._0.supplierSnapshot', json(?))
                        WHERE json_type(\(column), '$.part._0.partID') = 'text'
                        """, arguments: [snapshot])
            }
        }
        #expect(try await coordinator.read(eventsWithSupplierCopies) == 1)
        try await coordinator.close()
        let reopened = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        let after = try await reopened.open()
        #expect(after.generationID != before.generationID)
        #expect(try await reopened.read(PartQueries.fetchAll) == [ordered])
        #expect(try await reopened.read(ActivityQueries.fetchAll) == events)
        #expect(try await reopened.read(eventsWithSupplierCopies) == 0)
        let schema = try await reopened.read { db in
            (
                links: try db.columns(in: "partLink").map(\.name),
                linkIndexes: try db.indexes(on: "partLink").map(\.name).filter {
                    !$0.hasPrefix("sqlite_")
                },
                parts: try db.columns(in: "partRequirement").map(\.name)
            )
        }
        #expect(
            schema.links == ["id", "partID", "position", "url", "createdAt", "updatedAt"]
                && schema.linkIndexes == ["partLink_partID_position"])
        #expect(!schema.parts.contains("supplierSnapshot"))
        #expect(try await reopened.read { try SearchQueries.fetch("stock-77", in: $0) }.isEmpty)
        #expect(
            try await reopened.read { try SearchQueries.fetch("0012.3–å/04", in: $0) }.map(
                \.recordID) == [ordered.id])
        var edit = PartDraft(part: ordered)
        edit.links.removeFirst()
        let saved = try await PartService(coordinator: reopened).save(
            edit, for: job.id, editing: ordered.id)
        #expect(saved.links.map(\.id) == [ordered.links[1].id])
        #expect(saved.links.map(\.url) == [ordered.links[1].url])
        try await reopened.close()
    }

    private func eventsWithSupplierCopies(_ db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM activityEvent
                WHERE json_type(priorValue, '$.part._0.supplierSnapshot') IS NOT NULL
                   OR json_type(nextValue, '$.part._0.supplierSnapshot') IS NOT NULL
                """) ?? 0
    }
}

nonisolated enum PartLinkMigrationFixture {
    static func restoreSupplierOptions(in db: Database) throws {
        try db.alter(table: "partLink") { table in
            for column in ["title", "supplierName", "supplierStockCode", "notes"] {
                table.add(column: column, .text)
            }
            table.add(column: "currency", .text)
                .check(
                    sql:
                        "currency IS NULL OR (length(currency) = 3 AND currency NOT GLOB '*[^A-Z]*')"
                )
            table.add(column: "price", .text)
                .check(sql: "price IS NULL OR currency IS NOT NULL")
            table.add(column: "isSelected", .boolean).notNull().defaults(to: false)
                .check(sql: "isSelected IN (0, 1)")
            table.add(column: "searchKey", .text).notNull().defaults(to: "")
        }
        try db.execute(
            sql: "CREATE UNIQUE INDEX partLink_selected ON partLink(partID) WHERE isSelected = 1")
        try db.create(index: "partLink_searchKey", on: "partLink", columns: ["searchKey"])
        try db.alter(table: "partRequirement") { table in
            table.add(column: "supplierSnapshot", .text)
                .check(sql: "supplierSnapshot IS NULL OR json_valid(supplierSnapshot)")
        }
        try db.execute(
            sql: "DELETE FROM grdb_migrations WHERE identifier = 'v18-plain-part-links'")
    }
}
