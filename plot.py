#!/usr/bin/env python3
"""Parse zBench output and emit an HTML file with a log-log plot of the results.

Usage:
    python3 plot.py [results.txt] [-o out.html]

With no input file, the benchmark binary at zig-out/bin/collection_bench is run.
Input may also be piped on stdin.
"""
import sys
import os
import re
import json
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
UNIT_NS = {"ns": 1.0, "us": 1e3, "µs": 1e3, "ms": 1e6, "s": 1e9}
DUR_RE = re.compile(r"^([0-9.]+)\s*(ns|us|µs|ms|s)$")

# name  runs  total  avg ± sigma  (min ... max)  p75  p99  p995
LINE_RE = re.compile(
    r"^(\S+)\s+(\d+)\s+(\S+)\s+(\S+)\s+±\s+(\S+)\s+"
    r"\((\S+)\s+\.\.\.\s+(\S+)\)\s+(\S+)\s+(\S+)\s+(\S+)\s*$"
)


def to_ns(tok):
    m = DUR_RE.match(tok.strip())
    if not m:
        raise ValueError(f"unrecognised duration: {tok!r}")
    return float(m.group(1)) * UNIT_NS[m.group(2)]


def get_output(argv):
    if argv:
        with open(argv[0]) as f:
            return f.read()
    if not sys.stdin.isatty():
        data = sys.stdin.read()
        if data.strip():
            return data
    binary = os.path.join(HERE, "zig-out", "bin", "collection_bench")
    if not os.path.exists(binary):
        sys.exit(f"no input given and {binary} not found; build it first")
    return subprocess.run([binary], capture_output=True, text=True, check=True).stdout


def parse(text):
    """Return {series_name: [(size, avg_ns, min_ns, max_ns), ...]} sorted by size."""
    series = {}
    for raw in text.splitlines():
        line = ANSI_RE.sub("", raw).rstrip()
        m = LINE_RE.match(line)
        if not m:
            continue
        name, _runs, _total, avg, _sigma, mn, mx, *_ = m.groups()
        parts = name.split("/")
        if len(parts) != 3:
            continue
        collection, mode, size = parts
        key = f"{collection} / {mode}"
        series.setdefault(key, []).append(
            (int(size), to_ns(avg), to_ns(mn), to_ns(mx))
        )
    for pts in series.values():
        pts.sort(key=lambda p: p[0])
    return series


def build_traces(series):
    traces = []
    for name, pts in sorted(series.items()):
        xs = [p[0] for p in pts]
        avg = [p[1] for p in pts]
        lo = [p[2] for p in pts]
        hi = [p[3] for p in pts]
        traces.append(
            {
                "type": "scatter",
                "mode": "lines+markers",
                "name": name,
                "x": xs,
                "y": avg,
                "error_y": {
                    "type": "data",
                    "symmetric": False,
                    "array": [h - a for h, a in zip(hi, avg)],
                    "arrayminus": [a - l for a, l in zip(avg, lo)],
                    "thickness": 1,
                    "width": 3,
                },
                "hovertemplate": "%{x} elems<br>%{y:.1f} ns<extra>" + name + "</extra>",
            }
        )
    return traces


HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>appendAssumeCapacity benchmarks</title>
<script src="https://cdn.plot.ly/plotly-2.35.2.min.js" charset="utf-8"></script>
<style>
  body {{ font-family: system-ui, sans-serif; margin: 2rem; }}
  #plot {{ width: 100%; height: 80vh; }}
</style>
</head>
<body>
<h1>Collection build time: assume-capacity vs. not</h1>
<p>Average time per run (with min/max error bars) versus collection size,
for <code>ArrayList</code> and a <code>usize</code>-keyed set. Both axes are logarithmic.</p>
<div id="plot"></div>
<script>
  const traces = {traces};
  const layout = {{
    xaxis: {{ title: "collection size (elements)", type: "log", dtick: 1 }},
    yaxis: {{ title: "time per run (ns)", type: "log" }},
    legend: {{ orientation: "h", y: -0.2 }},
    margin: {{ t: 20 }},
  }};
  Plotly.newPlot("plot", traces, layout, {{responsive: true}});
</script>
</body>
</html>
"""


def main():
    argv = sys.argv[1:]
    out = "benchmark_plot.html"
    if "-o" in argv:
        i = argv.index("-o")
        out = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]

    series = parse(get_output(argv))
    if not series:
        sys.exit("no benchmark rows parsed from input")

    traces = build_traces(series)
    with open(out, "w") as f:
        f.write(HTML.format(traces=json.dumps(traces)))
    n = sum(len(v) for v in series.values())
    print(f"wrote {out} ({len(series)} series, {n} points)")


if __name__ == "__main__":
    main()
