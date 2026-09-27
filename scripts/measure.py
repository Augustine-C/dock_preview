#!/usr/bin/env python3
"""Read-only process CPU/RSS sampling. Does not launch apps or change permissions."""
import argparse
import json
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--pid', type=int, required=True)
parser.add_argument('--seconds', type=int, default=30)
parser.add_argument('--mode', default='idle')
parser.add_argument('--output')
args = parser.parse_args()
samples = []
for index in range(max(2, args.seconds + 1)):
    raw = subprocess.check_output(['ps', '-p', str(args.pid), '-o', 'time=,rss='], text=True).split()
    if len(raw) < 2:
        raise SystemExit('Target process exited')
    parts = raw[0].split(':')
    cpu_seconds = float(parts[-1]) + 60 * float(parts[-2])
    if len(parts) > 2:
        cpu_seconds += 3600 * float(parts[-3])
    samples.append({'monotonic': time.monotonic(), 'cpuSeconds': cpu_seconds, 'rssKiB': int(raw[1])})
    if index < max(2, args.seconds + 1) - 1:
        time.sleep(1)
duration = samples[-1]['monotonic'] - samples[0]['monotonic']
result = {
    'mode': args.mode, 'pid': args.pid, 'durationSeconds': duration,
    'averageCpuPercent': 100 * (samples[-1]['cpuSeconds'] - samples[0]['cpuSeconds']) / duration,
    'maxRssMiB': max(sample['rssKiB'] for sample in samples) / 1024,
    'samples': samples,
}
output = json.dumps(result, indent=2)
print(output)
if args.output:
    with open(args.output, 'w', encoding='utf-8') as handle:
        handle.write(output + '\n')
