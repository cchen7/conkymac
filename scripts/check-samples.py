"""Check real emitted samples, including baseline and slow-collector reuse.

Runs in the existing Python installation; needs no dependencies.
"""
import json
import sys
from datetime import datetime
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.startswith("{")]
assert len(rows) >= 2, "Expected at least two samples"
assert "cpuFraction" not in rows[0], "Initial CPU sample must have no fabricated baseline"
assert rows[0].get("network", {}).get("downloadBytesPerSecond") is None
for before, after in zip(rows, rows[1:]):
    assert after["sequence"] == before["sequence"] + 1
    assert datetime.fromisoformat(after["sampledAt"]) > datetime.fromisoformat(before["sampledAt"])
    assert 0 <= after["cpuFraction"] <= 1, "CPU delta unavailable or outside 0...1"
    for key in ("memory", "storage"):
        value = after[key]
        assert 0 <= value["used"] <= value["total"] and value["total"] > 0
    network = after["network"]
    for key in ("uploadBytesPerSecond", "downloadBytesPerSecond"):
        assert network[key] >= 0
    for key in ("sessionUploadBytes", "sessionDownloadBytes"):
        assert network[key] >= before["network"][key], "Session total went backwards"
    assert after["collectionMilliseconds"] >= 0
    temperature = after.get("temperatureCelsius")
    assert temperature is None or 10 <= temperature <= 120, "CPU temperature outside 10...120 C"
    for value in (after.get("frequency") or {}).values():
        assert 300 <= value <= 6000, "Cluster frequency outside 300...6000 MHz"
    cores = after.get("coreFractions")
    assert cores is None or all(0 <= value <= 1 for value in cores)
    processes = after.get("processes")
    if processes is not None:
        assert 0 < len(processes) <= 10, "Process ranking should hold 1...10 entries"
        cpus = [item["cpuPercent"] for item in processes]
        assert cpus == sorted(cpus, reverse=True), "Processes not ranked by CPU"
        assert all(item["name"] and item["memoryBytes"] >= 0 for item in processes)
assert rows[0]["storage"]["sampledAt"] == rows[1]["storage"]["sampledAt"], "Slow sample was repeated at 1 Hz"
issues = sorted({issue for row in rows for issue in row["issues"]})
if issues:
    print("SAMPLE_CHECK_PARTIAL: " + "; ".join(issues))
    sys.exit(2)
assert all(row.get("uptime", -1) > 0 for row in rows)
print(f"SAMPLE_CHECK_OK samples={len(rows)} interface={rows[-1]['network']['interface']}")
