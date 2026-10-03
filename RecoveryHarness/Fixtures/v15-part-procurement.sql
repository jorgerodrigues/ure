BEGIN TRANSACTION;
CREATE TABLE "activityEvent" ("id" TEXT PRIMARY KEY, "jobID" TEXT NOT NULL REFERENCES "job"("id") ON DELETE RESTRICT, "kind" TEXT NOT NULL CHECK (kind IN ('Job stage changed', 'Watch condition changed', 'Task status changed', 'Part status changed')), "occurredAt" DOUBLE NOT NULL, "ordering" INTEGER NOT NULL UNIQUE CHECK ("ordering" > 0), "priorValue" TEXT NOT NULL CHECK (json_valid(priorValue)), "nextValue" TEXT NOT NULL CHECK (json_valid(nextValue)));
CREATE TABLE "caliber" ("id" TEXT PRIMARY KEY, "designation" TEXT NOT NULL CHECK (length(trim(designation)) > 0), "manufacturer" TEXT, "variant" TEXT, "specificationNotes" TEXT, "sourceNote" TEXT, "movementType" TEXT NOT NULL CHECK (movementType IN ('Unknown', 'Manual', 'Automatic', 'Quartz', 'Other')), "beatRate" DOUBLE CHECK ("beatRate" > 0) CHECK ("beatRate" <= 1.7976931348623157e+308), "liftAngle" DOUBLE CHECK ("liftAngle" > 0) CHECK ("liftAngle" <= 1.7976931348623157e+308), "jewelCount" DOUBLE CHECK ("jewelCount" >= 0) CHECK ("jewelCount" <= 1.7976931348623157e+308), "powerReserve" DOUBLE CHECK ("powerReserve" >= 0) CHECK ("powerReserve" <= 1.7976931348623157e+308), "createdAt" DOUBLE NOT NULL, "updatedAt" DOUBLE NOT NULL);
INSERT INTO "caliber" VALUES('00000000-0000-4000-8000-000000000004','001.00 – 時計',NULL,NULL,NULL,NULL,'Manual',NULL,NULL,NULL,NULL,1.125,2.25);
CREATE TABLE "fileAsset" ("id" TEXT PRIMARY KEY, "storageKey" TEXT NOT NULL UNIQUE CHECK (storageKey = id || '.original'), "originalFilename" TEXT NOT NULL, "detectedType" TEXT NOT NULL CHECK (detectedType IN ('public.jpeg', 'public.png', 'public.heic', 'com.adobe.pdf')), "byteCount" INTEGER NOT NULL CHECK ("byteCount" > 0), "sha256" TEXT NOT NULL CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'), "importedAt" DOUBLE NOT NULL, "pixelWidth" INTEGER CHECK ("pixelWidth" > 0), "pixelHeight" INTEGER CHECK ("pixelHeight" > 0), "orientation" INTEGER CHECK (orientation BETWEEN 1 AND 8), CHECK ((detectedType = 'com.adobe.pdf' AND pixelWidth IS NULL AND pixelHeight IS NULL
    AND orientation IS NULL)
OR (detectedType != 'com.adobe.pdf' AND pixelWidth IS NOT NULL
    AND pixelHeight IS NOT NULL AND orientation IS NOT NULL)));
INSERT INTO "fileAsset" VALUES('00000000-0000-4000-8000-000000000010','00000000-0000-4000-8000-000000000010.original','photo.png','public.png',68,'628e888c04ba78b72721abd65746d9e88b954d797330295a798bb7e173d1bb75',7.125,1,1,1);
INSERT INTO "fileAsset" VALUES('00000000-0000-4000-8000-000000000011','00000000-0000-4000-8000-000000000011.original','technical.pdf','com.adobe.pdf',604,'c3fd7241590109450b7b6a96bd98772e0da2d30584dc7b1c7599fd5fbe60049d',7.125,NULL,NULL,NULL);
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
INSERT INTO "grdb_migrations" VALUES('v1-library-metadata');
INSERT INTO "grdb_migrations" VALUES('v2-watches');
INSERT INTO "grdb_migrations" VALUES('v3-calibers');
INSERT INTO "grdb_migrations" VALUES('v4-jobs');
INSERT INTO "grdb_migrations" VALUES('v5-job-stages');
INSERT INTO "grdb_migrations" VALUES('v6-notes');
INSERT INTO "grdb_migrations" VALUES('v7-library-links');
INSERT INTO "grdb_migrations" VALUES('v8-file-assets');
INSERT INTO "grdb_migrations" VALUES('v9-photos');
INSERT INTO "grdb_migrations" VALUES('v10-documents');
INSERT INTO "grdb_migrations" VALUES('v11-job-tasks');
INSERT INTO "grdb_migrations" VALUES('v12-task-order');
INSERT INTO "grdb_migrations" VALUES('v13-part-requirements');
INSERT INTO "grdb_migrations" VALUES('v14-supplier-options');
INSERT INTO "grdb_migrations" VALUES('v15-part-procurement');
CREATE TABLE "job" ("id" TEXT PRIMARY KEY, "watchID" TEXT NOT NULL REFERENCES "watch"("id") ON DELETE RESTRICT, "title" TEXT NOT NULL CHECK (length(trim(title)) > 0), "stage" TEXT NOT NULL CHECK (stage IN ('Planned', 'In progress', 'Waiting', 'Ready', 'Completed', 'Cancelled')), "reportedProblem" TEXT, "agreedScope" TEXT, "intakeCondition" TEXT, "ownerName" TEXT, "ownerEmail" TEXT, "ownerPhone" TEXT, "intakeSnapshot" TEXT NOT NULL CHECK (json_valid(intakeSnapshot)), "createdAt" DOUBLE NOT NULL, "updatedAt" DOUBLE NOT NULL, "waitingReason" TEXT, "outcome" TEXT, "recommendations" TEXT, "cancellationReason" TEXT, "startedAt" DOUBLE, "completedAt" DOUBLE, "cancelledAt" DOUBLE, "unfinishedTasksReason" TEXT, "unfinishedPartsReason" TEXT);
INSERT INTO "job" VALUES('00000000-0000-4000-8000-000000000006','00000000-0000-4000-8000-000000000003','Service 001','Planned',NULL,NULL,NULL,NULL,NULL,NULL,'{"version": 1, "watchName": "Retained watch \u2013 \u6642\u8a08", "serial": "000/01-02", "caliberDesignation": "001.00 \u2013 \u6642\u8a08"}',3.125,3.125,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL);
CREATE TABLE "jobTask" ("id" TEXT PRIMARY KEY, "jobID" TEXT NOT NULL REFERENCES "job"("id") ON DELETE RESTRICT, "title" TEXT NOT NULL CHECK (length(trim(title)) > 0), "detail" TEXT, "groupLabel" TEXT, "waitingReason" TEXT, "skippedReason" TEXT, "status" TEXT NOT NULL CHECK (status IN ('To do', 'Doing', 'Waiting', 'Done', 'Skipped')), "createdAt" DOUBLE NOT NULL, "updatedAt" DOUBLE NOT NULL, "position" INTEGER NOT NULL CHECK ("position" >= 0) DEFAULT 0, CHECK (status != 'Waiting' OR (waitingReason IS NOT NULL AND length(trim(waitingReason)) > 0)), CHECK (status != 'Skipped' OR (skippedReason IS NOT NULL AND length(trim(skippedReason)) > 0)));
INSERT INTO "jobTask" VALUES('00000000-0000-4000-8000-000000000007','00000000-0000-4000-8000-000000000006','Inspect train',NULL,NULL,NULL,NULL,'To do',11.125,11.125,0);
CREATE TABLE "libraryItem" ("id" TEXT PRIMARY KEY, "watchID" TEXT REFERENCES "watch"("id") ON DELETE RESTRICT, "jobID" TEXT REFERENCES "job"("id") ON DELETE RESTRICT, "caliberID" TEXT REFERENCES "caliber"("id") ON DELETE RESTRICT, "kind" TEXT NOT NULL CHECK (kind IN ('Link', 'Photo', 'Document')), "title" TEXT NOT NULL CHECK (length(trim(title)) > 0), "sourceURL" TEXT NOT NULL, "sourceDescription" TEXT NOT NULL, "notes" TEXT NOT NULL, "createdAt" DOUBLE NOT NULL, "updatedAt" DOUBLE NOT NULL, "fileAssetID" TEXT REFERENCES "fileAsset"("id") ON DELETE RESTRICT, "photoStage" TEXT, "caption" TEXT, CHECK ((watchID IS NOT NULL) + (jobID IS NOT NULL) + (caliberID IS NOT NULL) = 1), CHECK ((kind = 'Link' AND fileAssetID IS NULL AND photoStage IS NULL)
OR (kind = 'Document' AND fileAssetID IS NOT NULL AND photoStage IS NULL)
OR (kind = 'Photo' AND fileAssetID IS NOT NULL AND photoStage IS NOT NULL
    AND photoStage IN ('Unclassified', 'Before', 'During', 'After'))));
INSERT INTO "libraryItem" VALUES('00000000-0000-4000-8000-000000000012','00000000-0000-4000-8000-000000000003',NULL,NULL,'Photo','photo.png','','Non-sensitive fixture','',8.125,9.25,'00000000-0000-4000-8000-000000000010','Before',NULL);
INSERT INTO "libraryItem" VALUES('00000000-0000-4000-8000-000000000013','00000000-0000-4000-8000-000000000003',NULL,NULL,'Document','technical.pdf','','Non-sensitive fixture','',8.125,9.25,'00000000-0000-4000-8000-000000000011',NULL,NULL);
INSERT INTO "libraryItem" VALUES('00000000-0000-4000-8000-000000000014',NULL,NULL,'00000000-0000-4000-8000-000000000004','Link','Technical source','https://example.com/001','Fixture','',10.125,10.125,NULL,NULL,NULL);
CREATE TABLE "libraryMetadata" ("id" TEXT PRIMARY KEY, "createdAt" DOUBLE NOT NULL);
INSERT INTO "libraryMetadata" VALUES('00000000-0000-4000-8000-000000000002',0.0);
CREATE TABLE "note" ("id" TEXT PRIMARY KEY, "watchID" TEXT REFERENCES "watch"("id") ON DELETE RESTRICT, "jobID" TEXT REFERENCES "job"("id") ON DELETE RESTRICT, "caliberID" TEXT REFERENCES "caliber"("id") ON DELETE RESTRICT, "title" TEXT NOT NULL CHECK (length(trim(title)) > 0), "body" TEXT NOT NULL, "kind" TEXT NOT NULL CHECK (kind IN ('Observation', 'Research', 'Work log', 'Measurement')), "occurredAt" DOUBLE NOT NULL, "createdAt" DOUBLE NOT NULL, "updatedAt" DOUBLE NOT NULL, CHECK ((watchID IS NOT NULL) + (jobID IS NOT NULL) + (caliberID IS NOT NULL) = 1));
INSERT INTO "note" VALUES('00000000-0000-4000-8000-000000000005',NULL,'00000000-0000-4000-8000-000000000006',NULL,'Observation – æøå','Measured 0.12 mm
Keep Unicode: 時計 and æøå.
Measured 0.12 mm
Keep Unicode: 時計 and æøå.
Measured 0.12 mm
Keep Unicode: 時計 and æøå.
Measured 0.12 mm
Keep Unicode: 時計 and æøå.
Measured 0.12 mm
Keep Unicode: 時計 and æøå.
Measured 0.12 mm
Keep Unicode: 時計 and æøå.
Measured 0.12 mm
Keep Unicode: 時計 and æøå.
Measured 0.12 mm
Keep Unicode: 時計 and æøå.
Measured 0.12 mm
Keep Unicode: 時計 and æøå.
Measured 0.12 mm
Keep Unicode: 時計 and æøå.
Measured 0.12 mm
Keep Unicode: 時計 and æøå.
Measured 0.12 mm
Keep Unicode: 時計 and æøå.
','Research',4.125,5.25,6.5);
CREATE TABLE "partLink" ("id" TEXT PRIMARY KEY, "partID" TEXT NOT NULL REFERENCES "partRequirement"("id") ON DELETE RESTRICT, "position" INTEGER NOT NULL CHECK ("position" >= 0), "url" TEXT NOT NULL CHECK (length(trim(url)) > 0), "createdAt" DOUBLE NOT NULL, "updatedAt" DOUBLE NOT NULL, "title" TEXT, "supplierName" TEXT, "supplierStockCode" TEXT, "currency" TEXT CHECK (currency IS NULL OR (length(currency) = 3 AND currency NOT GLOB '*[^A-Z]*')), "price" TEXT CHECK (price IS NULL OR (
    typeof(price) = 'text' AND length(price) > 0 AND
    price NOT GLOB '*[^0-9.]*' AND price GLOB '[0-9]*' AND
    substr(price, -1) GLOB '[0-9]' AND
    length(price) - length(replace(price, '.', '')) <= 1 AND
    currency IS NOT NULL
)), "notes" TEXT, "isSelected" BOOLEAN NOT NULL CHECK (isSelected IN (0, 1)) DEFAULT 0);
INSERT INTO "partLink" VALUES('00000000-0000-4000-8000-000000000009','00000000-0000-4000-8000-000000000008',0,'https://example.com/part/001',13.125,13.125,NULL,NULL,'00/02','DKK','0012.3400',NULL,1);
CREATE TABLE "partRequirement" ("id" TEXT PRIMARY KEY, "jobID" TEXT NOT NULL REFERENCES "job"("id") ON DELETE RESTRICT, "description" TEXT NOT NULL CHECK (length(trim(description)) > 0), "quantity" INTEGER NOT NULL CHECK (typeof(quantity) = 'integer' AND quantity > 0), "manufacturerReference" TEXT, "compatibility" TEXT NOT NULL CHECK (compatibility IN ('Unchecked', 'Confirmed', 'Unsuitable')), "compatibilityNote" TEXT, "status" TEXT NOT NULL CHECK (status IN ('Needed', 'Ordered', 'Arrived', 'Installed', 'Cancelled')), "createdAt" DOUBLE NOT NULL, "updatedAt" DOUBLE NOT NULL, "orderedAt" DOUBLE, "arrivedAt" DOUBLE, "installedAt" DOUBLE, "cancelledAt" DOUBLE, "supplierSnapshot" TEXT CHECK (supplierSnapshot IS NULL OR json_valid(supplierSnapshot)), "orderReference" TEXT, "statusReason" TEXT, CHECK (compatibility != 'Confirmed' OR
(compatibilityNote IS NOT NULL AND length(trim(compatibilityNote)) > 0)));
INSERT INTO "partRequirement" VALUES('00000000-0000-4000-8000-000000000008','00000000-0000-4000-8000-000000000006','Mainspring',1,'000-12','Unchecked',NULL,'Needed',12.125,12.125,NULL,NULL,NULL,NULL,NULL,NULL,NULL);
CREATE TABLE "watch" ("id" TEXT PRIMARY KEY, "name" TEXT NOT NULL CHECK (length(trim(name)) > 0), "brand" TEXT, "model" TEXT, "caseReference" TEXT, "serial" TEXT, "approximateYear" TEXT, "caseMaterial" TEXT, "waterResistance" TEXT, "specificationNotes" TEXT, "caseDiameter" DOUBLE CHECK ("caseDiameter" > 0), "lugWidth" DOUBLE CHECK ("lugWidth" > 0), "createdAt" DOUBLE NOT NULL, "updatedAt" DOUBLE NOT NULL, "caliberID" TEXT REFERENCES "caliber"("id") ON DELETE RESTRICT, "condition" TEXT NOT NULL CHECK (condition IN ('Unknown', 'Running', 'Running poorly', 'Stopped', 'Disassembled')) DEFAULT 'Unknown', "conditionNote" TEXT, "coverPhotoID" TEXT REFERENCES "libraryItem"("id") ON DELETE SET NULL);
INSERT INTO "watch" VALUES('00000000-0000-4000-8000-000000000003','Retained watch – 時計',NULL,NULL,NULL,'000/01-02',NULL,NULL,NULL,NULL,NULL,NULL,1.125,2.25,'00000000-0000-4000-8000-000000000004','Unknown',NULL,'00000000-0000-4000-8000-000000000012');
CREATE INDEX "watch_caliberID" ON "watch"("caliberID");
CREATE INDEX "job_watchID" ON "job"("watchID");
CREATE UNIQUE INDEX job_one_open_per_watch ON job(watchID)
WHERE stage IN ('Planned', 'In progress', 'Waiting', 'Ready');
CREATE INDEX "note_watchID_occurredAt" ON "note"("watchID", "occurredAt");
CREATE INDEX "note_jobID_occurredAt" ON "note"("jobID", "occurredAt");
CREATE INDEX "note_caliberID_occurredAt" ON "note"("caliberID", "occurredAt");
CREATE INDEX "libraryItem_watchID_createdAt" ON "libraryItem"("watchID", "createdAt");
CREATE INDEX "libraryItem_jobID_createdAt" ON "libraryItem"("jobID", "createdAt");
CREATE INDEX "libraryItem_caliberID_createdAt" ON "libraryItem"("caliberID", "createdAt");
CREATE TRIGGER watch_cover_insert BEFORE INSERT ON watch
WHEN NEW.coverPhotoID IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM libraryItem AS item
    LEFT JOIN job ON job.id = item.jobID
    WHERE item.id = NEW.coverPhotoID AND item.kind = 'Photo'
      AND (item.watchID = NEW.id OR job.watchID = NEW.id))
BEGIN SELECT RAISE(ABORT, 'Invalid watch cover'); END;
CREATE TRIGGER watch_cover_update BEFORE UPDATE ON watch
WHEN NEW.coverPhotoID IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM libraryItem AS item
    LEFT JOIN job ON job.id = item.jobID
    WHERE item.id = NEW.coverPhotoID AND item.kind = 'Photo'
      AND (item.watchID = NEW.id OR job.watchID = NEW.id))
BEGIN SELECT RAISE(ABORT, 'Invalid watch cover'); END;
CREATE INDEX "jobTask_jobID" ON "jobTask"("jobID");
CREATE INDEX "jobTask_jobID_position" ON "jobTask"("jobID", "position");
CREATE INDEX "partRequirement_jobID" ON "partRequirement"("jobID");
CREATE INDEX "partLink_partID_position" ON "partLink"("partID", "position");
CREATE UNIQUE INDEX partLink_selected ON partLink(partID) WHERE isSelected = 1;
CREATE INDEX "activityEvent_jobID_ordering" ON "activityEvent"("jobID", "ordering");
COMMIT;
