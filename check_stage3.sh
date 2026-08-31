#!/bin/bash
cd ~/Documents/sec-restatement-analysis || exit 1

echo "=== performance study ==="
[ -f docs/performance.md ] && echo "  ok   docs/performance.md exists" || echo "  MISSING  docs/performance.md"
if [ -f docs/performance.md ]; then
  echo "  size: $(wc -c < docs/performance.md) bytes"
  grep -c "EXPLAIN" docs/performance.md | xargs -I{} echo "  EXPLAIN blocks: {} (want 6+, before and after per case)"
  grep -ci "brin" docs/performance.md | xargs -I{} echo "  BRIN mentions: {}"
  grep -n "_____\|TODO\|paste\|-- paste" docs/performance.md && echo "  ^^ PLACEHOLDERS REMAIN" || echo "  ok   no placeholders"
fi

echo
echo "=== stage 3 models ==="
for m in fil_lag_by_form fil_lag_trend fil_deadline_filers pit_peer_comparables; do
  [ -f "dbt/models/analysis/$m.sql" ] && echo "  ok   $m.sql" || echo "  MISSING  $m.sql"
done

echo
echo "=== built in database ==="
for m in fil_lag_by_form fil_lag_trend fil_deadline_filers pit_peer_comparables; do
  n=$(docker exec -i sec_pg psql -U sec -d sec -tAc "select count(*) from public_analysis.$m" 2>/dev/null)
  [ -n "$n" ] && echo "  ok   $m: $n rows" || echo "  NOT BUILT  $m"
done

echo
echo "=== findings section 3 ==="
grep -n "^### 3\." docs/findings.md || echo "  NO §3 SECTIONS"
grep -c "3.4" docs/findings.md | xargs -I{} echo "  '3.4' mentions: {}"
grep -ci "percentile.*shift\|quartile\|bucket" docs/findings.md | xargs -I{} echo "  percentile-shift discussed: {}"

echo
echo "=== readme references performance ==="
grep -c "performance.md" README.md | xargs -I{} echo "  links to performance.md: {}"

echo
echo "=== staleness ==="
grep -n "Stage 3\|coming soon\|in progress\|to be written" README.md docs/findings.md | head -5 || echo "  ok   none"

echo
echo "=== git ==="
git status --short
echo "  tags: $(git tag | tr '\n' ' ')"
echo "  unpushed: $(git log origin/main..HEAD --oneline | wc -l | tr -d ' ')"
