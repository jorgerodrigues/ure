"""Run W029 against disposable libraries through the command-line storage worker."""

import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import uuid


REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "RecoveryHarness/Fixtures"
WORKER = Path(sys.argv[1]).resolve()
RUN = REPO / ".build/recovery-runs" / str(uuid.uuid4())
GENERATION = "00000000-0000-4000-8000-000000000001"
VERSIONS = ("v10-documents", "v15-part-procurement")
RESULTS = []


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def active(case):
    pointer = json.loads((case / "library/active-library.json").read_text())
    return case / "library/generations" / pointer["generationID"]


def seed(name, version="v15-part-procurement"):
    case = RUN / name
    case.mkdir(parents=True)
    (case / ".ure-recovery-case").write_text("isolated W029 library")
    generation = case / "library/generations" / GENERATION
    (generation / "originals").mkdir(parents=True)
    shutil.copyfile(FIXTURES / "manifest.json", generation / "manifest.json")
    (case / "library/active-library.json").write_text(
        json.dumps(dict(formatVersion=1, generationID=GENERATION))
    )
    with sqlite3.connect(generation / "library.sqlite") as db:
        db.executescript((FIXTURES / (version + ".sql")).read_text())
        assets = db.execute("SELECT storageKey, detectedType FROM fileAsset").fetchall()
    photo = base64.b64decode((FIXTURES / "photo.base64").read_text(), validate=False)
    pdf = base64.b64decode((FIXTURES / "technical.pdf.base64").read_text())
    for key, kind in assets:
        data = pdf if kind == "com.adobe.pdf" else photo
        (generation / "originals" / key).write_bytes(data)
    sources = case / "sources"
    sources.mkdir()
    (sources / "photo.png").write_bytes(photo)
    # More than two copy chunks, while keeping a valid PDF and its original bytes.
    (sources / "technical.pdf").write_bytes(pdf + b"% W029 padding\n" * 160_000)
    return case


def worker(case, operation="open", checkpoint="none", expected=0):
    marker = case / "reached.txt"
    marker.unlink(missing_ok=True)
    environment = dict(
        os.environ, URE_TESTING="1", URE_TEST_LIBRARY_PATH=str(case / "library")
    )
    result = subprocess.run(
        [str(WORKER), operation, str(case), checkpoint],
        env=environment, capture_output=True, text=True, timeout=60,
    )
    log = case / (operation + "-" + checkpoint + ".log")
    log.write_text(result.stdout + result.stderr)
    require(result.returncode == expected, f"{case.name}: expected exit {expected}, got {result.returncode}: {result.stderr}")
    if expected == -signal.SIGKILL:
        require(marker.read_text() == checkpoint, f"{case.name}: wrong interruption boundary")


def inspect(generation):
    with sqlite3.connect((generation / "library.sqlite").as_uri() + "?mode=ro", uri=True) as db:
        require(db.execute("PRAGMA integrity_check").fetchone() == ("ok",), "SQLite integrity")
        require(not db.execute("PRAGMA foreign_key_check").fetchall(), "Foreign keys")
        db.row_factory = sqlite3.Row
        names = [row[0] for row in db.execute(
            "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name"
        )]
        tables = {}
        for name in names:
            quoted = name.replace('"', '""')
            rows = [dict(row) for row in db.execute(f'SELECT * FROM "{quoted}"')]
            tables[name] = sorted(rows, key=lambda row: json.dumps(row, sort_keys=True))
        migrations = [row[0] for row in db.execute("SELECT identifier FROM grdb_migrations ORDER BY rowid")]
    originals = {}
    for asset in tables["fileAsset"]:
        data = (generation / "originals" / asset["storageKey"]).read_bytes()
        require(len(data) == asset["byteCount"], "Complete original size")
        require(hashlib.sha256(data).hexdigest() == asset["sha256"], "Complete original hash")
        originals[asset["id"]] = base64.b64encode(data).decode()
    asset_ids = set(originals)
    for item in tables["libraryItem"]:
        if item["kind"] != "Link":
            require(item["fileAssetID"] in asset_ids, "Visible file has a complete original")
    backup_file = generation / "backup.json"
    if backup_file.exists():
        manifest = json.loads(backup_file.read_text())
        require(manifest["counts"] == {name: len(rows) for name, rows in tables.items()}, "Backup counts")
        require(manifest["migrations"] == migrations, "Backup migration history")
        declared = {file["path"] for file in manifest["files"]}
        require(declared == set(tree(generation)) - {"backup.json"}, "Exact backup payload inventory")
        for file in manifest["files"]:
            data = (generation / file["path"]).read_bytes()
            require(len(data) == file["byteCount"], "Backup declared size")
            require(hashlib.sha256(data).hexdigest() == file["sha256"], "Backup declared hash")
    return dict(tables=tables, originals=originals, migrations=migrations)


def preserved(before, after):
    require(before["originals"] == after["originals"], "Original and technical PDF bytes preserved")
    for table, rows in before["tables"].items():
        require(len(rows) == len(after["tables"][table]), f"{table}: record count")
        old_columns = set(rows[0]) if rows else set()
        projected = [{key: row[key] for key in old_columns} for row in after["tables"][table]]
        require(sorted(rows, key=lambda row: json.dumps(row, sort_keys=True)) == sorted(projected, key=lambda row: json.dumps(row, sort_keys=True)), f"{table}: IDs and saved values")


def reopen_twice(case):
    worker(case)
    first = inspect(active(case))
    pointer = (case / "library/active-library.json").read_bytes()
    generations = sorted(path.name for path in (case / "library/generations").iterdir())
    worker(case)
    require(inspect(active(case)) == first, "Repeated open and cleanup do not duplicate data")
    require((case / "library/active-library.json").read_bytes() == pointer, "Repeated open keeps the generation")
    require(sorted(path.name for path in (case / "library/generations").iterdir()) == generations, "Repeated open creates no additional generation")
    return first


def record(case):
    RESULTS.append(case.name)
    print("PASS " + case.name, flush=True)


def prepare_current(name):
    case = seed(name)
    worker(case)
    return case, inspect(active(case))


def import_matrix():
    for kind in ("photo", "pdf"):
        for step in ("copiedChunk", "beforeRename", "afterRename", "beforeCommit", "afterCommit", "beforeCleanup"):
            case, before = prepare_current(f"import-{kind}-{step}")
            source = case / "sources" / ("technical.pdf" if kind == "pdf" else "photo.png")
            source_bytes = base64.b64encode(source.read_bytes()).decode()
            worker(case, "import-" + kind, "import." + step, -signal.SIGKILL)
            shutil.rmtree(case / "sources")
            after = reopen_twice(case)
            if step == "afterCommit":
                for table, rows in before["tables"].items():
                    added = int(table in ("fileAsset", "libraryItem"))
                    require(len(after["tables"][table]) == len(rows) + added, "Committed import count")
                    for row in rows:
                        require(row in after["tables"][table], "Existing records survive committed import")
                added_ids = set(after["originals"]) - set(before["originals"])
                require(len(added_ids) == 1, "Exactly one complete new original")
                require(after["originals"][added_ids.pop()] == source_bytes, "Imported bytes survive source removal")
            else:
                require(before == after, "Uncommitted import rolls back")
            generation = active(case)
            require(not list((generation / "imports").iterdir()), "Abandoned partial imports removed")
            require(len(list((generation / "originals").iterdir())) == len(after["originals"]), "Unreferenced originals removed")
            record(case)


def backup_matrix():
    for existing in (False, True):
        for step in ("copiedDatabase", "copiedChunk", "beforeValidation", "beforePublish"):
            case, before = prepare_current(f"backup-{'replace' if existing else 'new'}-{step}")
            package = case / "export.watchbackup"
            saved = None
            worker(case, "import-pdf")
            before = inspect(active(case))
            if existing:
                worker(case, "export")
                saved = tree(package)
                change_current(case)
                before = inspect(active(case))
            worker(case, "export", "backup." + step, -signal.SIGKILL)
            if existing:
                require(tree(package) == saved, "Interrupted export keeps prior successful backup")
            else:
                require(not package.exists(), "Interrupted export is not published")
            require(reopen_twice(case) == before, "Interrupted export keeps the library")
            worker(case, "export")
            require(inspect(package) == before, "Retry publishes a complete backup")
            record(case)


def tree(directory):
    return {str(path.relative_to(directory)): path.read_bytes() for path in directory.rglob("*") if path.is_file()}


def change_current(case):
    with sqlite3.connect(active(case) / "library.sqlite") as db:
        db.execute("UPDATE watch SET name = 'Newer current watch – 時計', updatedAt = 30.125")
        db.execute("UPDATE note SET body = 'Newer current finding', updatedAt = 31.25")
    worker(case, "import-pdf")


def upgrade_matrix():
    for version in VERSIONS:
        for step in ("afterRecovery", "beforeMigration", "transaction", "afterMigration", "beforeSwitch", "afterSwitch"):
            case = seed(f"upgrade-{version}-{step}", version)
            original = active(case)
            before = inspect(original)
            original_files = tree(original)
            pointer = (case / "library/active-library.json").read_bytes()
            worker(case, checkpoint="upgrade." + step, expected=-signal.SIGKILL)
            if step != "afterSwitch":
                require((case / "library/active-library.json").read_bytes() == pointer, "Interrupted upgrade retains pointer")
            require(tree(original) == original_files, "Interrupted upgrade never changes retained generation")
            after = reopen_twice(case)
            preserved(before, after)
            require(after["migrations"][-1] == "v17-search", "Current schema after retry")
            recoveries = list((case / "library/recovery").iterdir())
            complete = [path for path in recoveries if (path / "snapshot.json").is_file()]
            require(bool(complete), "Pre-upgrade recovery copy retained")
            for copy in complete:
                require(inspect(copy) == before, "Pre-upgrade copy preserves schema, IDs and bytes")
            record(case)


def legacy_package(case):
    source = seed(case.name + "-package", "v10-documents")
    generation = active(source)
    package = case / "export.watchbackup"
    shutil.copytree(generation, package)
    snapshot = inspect(package)
    files = [dict(path=path, byteCount=len(data), sha256=hashlib.sha256(data).hexdigest()) for path, data in tree(package).items()]
    manifest = json.loads((package / "manifest.json").read_text())
    (package / "backup.json").write_text(json.dumps(dict(
        formatVersion=1, exportedAt=0, libraryID=manifest["libraryID"], applicationVersion="retained-v10",
        migrations=snapshot["migrations"], counts={name: len(rows) for name, rows in snapshot["tables"].items()}, files=files,
    )))
    worker(source)
    return inspect(active(source))


def restore_matrix():
    for legacy in (False, True):
        for step in ("beforeRecovery", "afterRecovery", "beforeSwitch", "afterSwitch", "beforeFirstOpen", "afterFirstOpen", "beforeRollback"):
            case, backup = prepare_current(f"restore-{'legacy' if legacy else 'current'}-{step}")
            if legacy:
                backup = legacy_package(case)
            else:
                worker(case, "export")
            package_bytes = tree(case / "export.watchbackup")
            change_current(case)
            current = inspect(active(case))
            retained = active(case)
            recovery_before = set((case / "library/recovery").iterdir())
            worker(case, "restore", "restore." + step, -signal.SIGKILL)
            expected = current if step in ("beforeRecovery", "afterRecovery", "beforeSwitch") else backup
            require(reopen_twice(case) == expected, "Restore interruption selects one complete generation")
            require(inspect(retained) == current, "Old generation retained in full")
            require(tree(case / "export.watchbackup") == package_bytes, "Restore never changes source package")
            copies = set((case / "library/recovery").iterdir()) - recovery_before
            if step != "beforeRecovery":
                require(len(copies) == 1, "Exactly one complete pre-restore recovery")
                require(inspect(copies.pop()) == current, "Pre-restore recovery preserves current data")
            record(case)
    for operation, prefix, steps in (
        ("stage", "stage.", ("copiedChunk", "beforeMigration", "beforePublish")),
        ("restore", "backup.", ("copiedDatabase", "beforePublish")),
    ):
        for step in steps:
            case, backup = prepare_current(f"{operation}-{prefix}{step}")
            worker(case, "export")
            change_current(case)
            current = inspect(active(case))
            worker(case, operation, prefix + step, -signal.SIGKILL)
            require(reopen_twice(case) == current, "Interrupted staging/recovery never switches")
            worker(case, "restore")
            require(reopen_twice(case) == backup, "Retry activates complete backup")
            record(case)


def damaged_matrix():
    for damage in ("pointer", "missing-pointer", "database", "missing-database", "manifest", "future-schema", "blocked-recovery"):
        case = seed("damaged-" + damage)
        generation = active(case)
        pointer = case / "library/active-library.json"
        database = generation / "library.sqlite"
        if damage == "missing-pointer":
            pointer.unlink()
        elif damage == "missing-database":
            database.unlink()
        elif damage == "pointer":
            pointer.write_text("damaged pointer")
        elif damage == "database":
            database.write_bytes(database.read_bytes()[:100])
        elif damage == "manifest":
            (generation / "manifest.json").write_text("damaged manifest")
        elif damage == "future-schema":
            with sqlite3.connect(database) as db:
                db.execute("INSERT INTO grdb_migrations VALUES ('v999-future')")
        elif damage == "blocked-recovery":
            (case / "library/recovery").write_text("Cannot create recovery directory")
        before = tree(case / "library")
        for _ in range(2):
            worker(case, expected=1)
            require(tree(case / "library") == before, "Failed open preserves all files without an empty replacement")
        record(case)


def main():
    require(WORKER.is_file(), "Build UreRecoveryHarness before running the matrix")
    RUN.mkdir(parents=True)
    for matrix in (import_matrix, backup_matrix, upgrade_matrix, restore_matrix, damaged_matrix):
        matrix()
    (RUN / "summary.json").write_text(json.dumps(dict(passed=RESULTS, count=len(RESULTS)), indent=2))
    print(f"Passed {len(RESULTS)} recovery scenarios. Evidence: {RUN}")


if __name__ == "__main__":
    main()
