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
        let needed = try await service.add(named: "Mainspring", to: job.id)
        _ = try await service.update(needed.id, .description("0012.3–Å/04"))
        let ordered = try await service.setStage(needed.id, to: .ordered).part
        try await coordinator.mutate { db, _, _ in
            for (position, url) in [
                "https://example.org/parts/0012?variant=A", "https://example.net/alternate",
            ].enumerated() {
                try PartOption(
                    id: UUID(), partID: ordered.id, position: position,
                    supplier: BuyingMigration.supplier(for: url), url: url, createdAt: clock,
                    updatedAt: clock
                ).insert(db)
            }
        }
        let links = try await coordinator.read { try PartQueries.options(of: ordered.id, in: $0) }
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
                    SET supplierSnapshot = ?, orderReference = 'PO-1',
                        searchKey = searchKey || char(10) || 'stock-77'
                    """, arguments: [snapshot])
            // The order's history keeps a copy of the supplier, which v18 removes.
            try db.execute(
                sql: """
                    INSERT INTO activityEvent (id, jobID, kind, occurredAt, ordering, priorValue,
                        nextValue)
                    VALUES (?, ?, 'Part status changed', 1, 1,
                        json_object('part', json_object('_0', json_object(
                            'partID', ?, 'description', 'Spring', 'supplierSnapshot', json(?)))),
                        json_object('part', json_object('_0', json_object(
                            'partID', ?, 'description', 'Spring', 'orderReference', 'PO-1'))))
                    """,
                arguments: [
                    UUID().uuidString, job.id.uuidString, ordered.id.uuidString, snapshot,
                    ordered.id.uuidString,
                ])
        }
        #expect(try await coordinator.read(eventsWithSupplierCopies) == 1)
        try await coordinator.close()
        let reopened = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        let after = try await reopened.open()
        #expect(after.generationID != before.generationID)
        // v26 then makes the requirement a part, with its order reference in its notes.
        var kept = ordered
        kept.notes = "From the old record\n\nOrder reference: PO-1"
        #expect(try await reopened.read(PartQueries.fetchAll) == [kept])
        // v27 then makes each link an option again, without a price.
        #expect(
            try await reopened.read { try PartQueries.options(of: ordered.id, in: $0) } == links)
        // v23 then removes the history. The order reference stays with the part, so only the
        // supplier copy that v18 removed is gone.
        #expect(try await reopened.read { try $0.tableExists("activityEvent") } == false)
        #expect(
            try await RecordNotesService(coordinator: reopened).text(for: .job(job.id)).isEmpty)
        let schema = try await reopened.read { db in
            (
                links: try db.columns(in: "partOption").map(\.name),
                linkIndexes: try db.indexes(on: "partOption").map(\.name).filter {
                    !$0.hasPrefix("sqlite_")
                },
                parts: try db.columns(in: "part").map(\.name)
            )
        }
        #expect(
            schema.links == [
                "id", "partID", "position", "supplier", "url", "price", "shipping", "currency",
                "note", "createdAt", "updatedAt",
            ] && schema.linkIndexes == ["partOption_partID_position"])
        #expect(!schema.parts.contains("supplierSnapshot"))
        #expect(try await reopened.read { try SearchQueries.fetch("stock-77", in: $0) }.isEmpty)
        #expect(
            try await reopened.read { try SearchQueries.fetch("0012.3–å/04", in: $0) }.map(
                \.recordID) == [ordered.id])
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
        try RecordNotesMigrationFixture.restoreNoteRecords(in: db)
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
