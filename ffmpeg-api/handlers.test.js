const test = require('node:test');
const assert = require('node:assert/strict');
const { parseDecodedDuration, durationsMatch } = require('./duration');
const { buildDynamicsFilter, joinAudioFilters } = require('./handlers');

test('full normalization uses conservative dynamics processing before loudness normalization', () => {
  const dynamics = buildDynamicsFilter(true);
  assert.match(dynamics, /dynaudnorm=.*framelen=2000/);
  assert.match(dynamics, /acompressor=.*ratio=2/);
  assert.match(dynamics, /alimiter=.*level=false/);
  assert.equal(buildDynamicsFilter(false), '');
  assert.equal(joinAudioFilters(dynamics, 'loudnorm=I=-14'), `${dynamics},loudnorm=I=-14`);
});

test('parseDecodedDuration uses the last decoded FFmpeg timestamp', () => {
  const progress = [
    'out_time_us=24000000',
    'progress=continue',
    'out_time_us=213552000',
    'progress=end',
  ].join('\n');

  assert.equal(parseDecodedDuration(progress), 213.552);
});

test('parseDecodedDuration supports the timestamp fallback', () => {
  assert.equal(parseDecodedDuration('out_time=00:03:33.552000\nprogress=end\n'), 213.552);
});

test('parseDecodedDuration rejects missing or zero progress', () => {
  assert.equal(parseDecodedDuration(''), null);
  assert.equal(parseDecodedDuration('out_time_us=0\nprogress=end\n'), null);
});

test('durationsMatch allows codec tolerance but rejects truncation', () => {
  assert.equal(durationsMatch(213.552, 213.576), true);
  assert.equal(durationsMatch(242.606, 213.552), false);
  assert.equal(durationsMatch(null, 213.552), false);
});
