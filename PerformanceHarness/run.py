"""Measure W031 in an isolated Release worker without starting the native app."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import time
import uuid
import sqlite3


REPO = Path(__file__).resolve().parent.parent
VERSION = "W031-v1"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def record_id(kind, index):
    return f"00000000-0000-4000-{kind:04d}-{index:012d}"


def expected_results():
    expected = {
        "watches": [record_id(2, i) for i in range(500)],
        "jobs": [record_id(3, i) for i in range(1000)],
        "tasks": [record_id(4, i) for i in range(10000)],
        "photos": [record_id(6, i) for i in range(5000)],
        "bench": [record_id(6, i) for i in range(5000)],
        "parts": [record_id(8, i * 2) for i in range(450)],
        "workshop": [record_id(3, i * 2) for i in range(450)],
    }
    for archived in (False, True):
        watches = 500 if archived else 450
        jobs = watches * 2
        calibers = 50 if archived else 45
        groups = {
            "Watch": (2, watches), "Caliber": (1, calibers), "Job": (3, jobs),
            "Note": (7, jobs), "Part": (8, jobs), "Photo": (6, watches * 10),
        }
        keys = {
            kind: [f"{kind}-{record_id(number, i)}" for i in range(count)]
            for kind, (number, count) in groups.items()
        }
        prefix = f"search:{str(archived).lower()}:"
        expected[prefix + "Synthetic"] = sum(keys.values(), [])
        expected[prefix + "ÜHREN"] = keys["Watch"] + keys["Note"] + keys["Photo"]
        expected[prefix + "00.A_%"] = keys["Part"]
        expected[prefix + "00.001_%'"] = [f"Watch-{record_id(2, 1)}"]
        expected[prefix + "no match"] = []
    return expected


def inspect_fixture(case):
    pointer = json.loads((case / "library/active-library.json").read_text())
    generation = case / "library/generations" / pointer["generationID"]
    digest = hashlib.sha256()
    counts = {}
    with sqlite3.connect((generation / "library.sqlite").as_uri() + "?mode=ro", uri=True) as db:
        require(db.execute("PRAGMA integrity_check").fetchone() == ("ok",), "Database integrity")
        require(not db.execute("PRAGMA foreign_key_check").fetchall(), "Foreign keys")
        tables = ["caliber", "watch", "job", "jobTask", "note", "partRequirement", "partLink", "taskPart", "fileAsset", "libraryItem"]
        for table in tables:
            rows = db.execute(f"SELECT * FROM {table} ORDER BY rowid").fetchall()
            counts[table] = len(rows)
            digest.update(json.dumps([table, rows], ensure_ascii=False).encode())
        assets = db.execute("SELECT storageKey, byteCount, sha256 FROM fileAsset ORDER BY id").fetchall()
    require(counts == dict(caliber=50, watch=500, job=1000, jobTask=10000, note=1000,
                           partRequirement=1000, partLink=2000, taskPart=2000, fileAsset=5000, libraryItem=5000), "Fixture counts")
    require(len(list((generation / "originals").iterdir())) == 5000, "Original file count")
    for key, size, sha in assets:
        original = generation / "originals" / key
        require(original.stat().st_size == size, f"Original size: {key}")
        require(hashlib.sha256(original.read_bytes()).hexdigest() == sha, f"Original hash: {key}")
    return dict(version=VERSION, sha256=digest.hexdigest(), counts=counts,
                originalBytes=sum(size for _, size, _ in assets))


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("worker", type=Path)
    parser.add_argument("--fixture", type=Path, help="Reuse this marked fixture for before/after measurements")
    args = parser.parse_args()
    worker = args.worker.resolve(strict=True)
    case = (args.fixture or REPO / ".build/performance-runs" / str(uuid.uuid4())).resolve()
    require(case.is_relative_to(REPO / ".build/performance-runs"), "Fixture must be under .build/performance-runs")
    environment = dict(os.environ, URE_TESTING="1", URE_TEST_LIBRARY_PATH=str(case / "library"))

    def run(operation):
        return subprocess.run([str(worker), operation, str(case)], env=environment,
                              capture_output=True, text=True, timeout=300, check=True)

    if not args.fixture:
        case.mkdir(parents=True)
        (case / ".ure-performance-case").write_text(VERSION)
        run("seed")
    require((case / ".ure-performance-case").read_text() == VERSION, "Wrong fixture version")
    fixture = inspect_fixture(case)
    expected = expected_results()
    reports = []
    process_times = []
    for index in range(3):
        start = time.perf_counter()
        result = run("measure")
        process_times.append((time.perf_counter() - start) * 1000)
        (case / f"measurement-{index}.json").write_text(result.stdout)
        report = json.loads(result.stdout)
        require(report["resultIDs"].keys() == expected.keys(), "Missing measured query")
        for name, ids in report["resultIDs"].items():
            require(len(ids) == len(set(ids)) and set(ids) == set(expected[name]), f"Exact results: {name}")
        reports.append(report)
    require(inspect_fixture(case) == fixture, "Benchmark changed records or originals")
    memory = []
    for report in reports:
        cycles = report["imageCycles"]
        require(len(cycles) == 20, "Missing large-image cycles")
        require(all(cycle["width"] == 6000 and cycle["height"] == 4000 for cycle in cycles), "Original resolution")
        settled = cycles[3:]
        growth = max(cycle["afterBytes"] for cycle in settled) - min(cycle["afterBytes"] for cycle in settled)
        memory.append(dict(settledGrowthBytes=growth, finalResidentBytes=cycles[-1]["afterBytes"]))
    timings = {}
    for name in reports[0]["timings"]:
        samples = sum((report["timings"][name] for report in reports), [])
        timings[name] = dict(samples=len(samples), medianMilliseconds=statistics.median(samples),
                             maximumMilliseconds=max(samples))
    summary = dict(
        fixture=fixture, fixturePath=str(case), buildMode="Release (-O, whole-module)",
        sourceHead=command("git", "rev-parse", "HEAD"),
        sourceStatus=command("git", "status", "--short"),
        workerSHA256=hashlib.sha256(worker.read_bytes()).hexdigest(),
        hardware=command("sysctl", "-n", "hw.model", "hw.memsize", "machdep.cpu.brand_string"),
        os=command("sw_vers"), xcode=command("xcodebuild", "-version"),
        coordinatorOpenMilliseconds=[report["openMilliseconds"] for report in reports],
        firstReadMilliseconds=[report["firstReadMilliseconds"] for report in reports],
        entireBenchmarkProcessMilliseconds=process_times, timings=timings,
        resultCounts={name: len(ids) for name, ids in expected.items()},
        imageCycles=[report["imageCycles"] for report in reports],
        largeImageMemory=memory,
        nativeUsableWindow="pending W032", nativeTaskInputAndScroll="pending W032",
    )
    (case / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(dict(summary=str(case / "summary.json"), timings=timings), indent=2))


if __name__ == "__main__":
    main()
