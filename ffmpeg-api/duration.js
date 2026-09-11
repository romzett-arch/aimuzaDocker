function parseDecodedDuration(progressOutput) {
  const raw = String(progressOutput || '').replace(/\r/g, '');
  const microsecondMatches = [...raw.matchAll(/^out_time_us=(\d+(?:\.\d+)?)$/gm)];
  if (microsecondMatches.length > 0) {
    const microseconds = Number(microsecondMatches[microsecondMatches.length - 1][1]);
    if (Number.isFinite(microseconds) && microseconds > 0) return microseconds / 1_000_000;
  }

  const timestampMatches = [...raw.matchAll(/^out_time=(\d+):(\d+):(\d+(?:\.\d+)?)$/gm)];
  if (timestampMatches.length === 0) return null;
  const [, hours, minutes, seconds] = timestampMatches[timestampMatches.length - 1];
  const duration = Number(hours) * 3600 + Number(minutes) * 60 + Number(seconds);
  return Number.isFinite(duration) && duration > 0 ? duration : null;
}

function durationsMatch(sourceDuration, outputDuration, toleranceSeconds = 2) {
  if (!Number.isFinite(sourceDuration) || sourceDuration <= 0) return false;
  if (!Number.isFinite(outputDuration) || outputDuration <= 0) return false;
  return Math.abs(sourceDuration - outputDuration) <= toleranceSeconds;
}

module.exports = { parseDecodedDuration, durationsMatch };
