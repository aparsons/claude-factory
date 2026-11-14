# Computes the KPI object from the ledger (stdin, raw text, JSON lines).
# Arguments: $prices, $runs (gh run list JSON or null), $usage (usage.json or null),
#            $merges (array of {ts, subject} from a git log, or null), $health ({root_kb, tmp_kb}).
# First-try: a ticket is first-try only if no gate event with result fail exists for it, whatever came before or after.
# Rework per ticket: failed_gates (failures before the ticket's first pass), review_send_backs (failures after a pass),
# escalations. The ledger itself is never rewritten.
# CI: the ledger's `ci` events when there are any (green and failed; a red already on the default branch, an
# infrastructure failure, a timeout and no checks say nothing about the ticket), else the runs given with --runs.
# A KPI that cannot be computed from what is recorded is null (printed as n/a), never 0.

def ts2s:
  capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$") as $c
  | ($c.d + "Z" | fromdateiso8601) as $base
  | if $c.z == "Z" then $base
    else (($c.z[1:3] | tonumber) * 3600 + ($c.z[4:6] | tonumber) * 60) as $o
      | if $c.z[0:1] == "+" then $base - $o else $base + $o end end;
def median: if length == 0 then null else sort | (.[((length - 1) / 2 | floor)] + .[(length / 2 | floor)]) / 2 end;
def sumnn: [.[] | select(type == "number")] | if length == 0 then null else add end;
def round1: if . == null then null else (. * 10 | round) / 10 end;
def round2: if . == null then null else (. * 100 | round) / 100 end;
def rate($n; $d): if $d == 0 then null else $n / $d end;
def types: ["input", "output", "cache_read", "cache_creation"];

(split("\n") | map(fromjson? // empty) | map(select(type == "object"))) as $ev
| ($ev | length > 0) as $recorded
| ([$ev[] | select(.event == "agent_launch" and .tool_use_id != null) | {key: (.tool_use_id | tostring), value: .}] | from_entries) as $launch
| ([$ev[] | select(.event == "agent_launch_result" and .agent_id != null)
    | (.tool_use_id | tostring) as $t
    | {key: .agent_id, value: {model: .model, ticket: ($launch[$t].ticket // null)}}] | from_entries) as $byagent
| (def price($model):
     if $model == null then null else
       [$prices.models[] | . as $m | ($m.match[] | select(. as $p | $model | startswith($p))) as $p | {len: ($p | length), m: $m}]
       | if length == 0 then null else max_by(.len).m end
     end;
   def cc($p; $tok): [types[] as $t | (($tok // {})[$t] // 0) * $p[$t] / 1000000] | add;
   [$ev[] | select(.event == "agent_stop") | . as $s
    | ($byagent[$s.agent_id // ""] // {}) as $j
    | ($s + {ticket: ($s.ticket // $j.ticket), model: ($s.model // $j.model)})
    | . + {cost: (price(.model) as $p | if $p == null then null else {low: cc($p.low; .tokens), high: cc($p.high; .tokens)} end)}]) as $stops
| ([$ev[] | select(.event == "agent_start") | .agent_id] ) as $started
| ([$stops[] | .agent_id]) as $stopped
| ([$ev[] | select(.ticket != null and .spec != null) | {key: (.ticket | tostring), value: .spec}] | from_entries) as $specof
| ([$ev[] | .ts | select(type == "string") | ts2s] | sort) as $times
| (if ($times | length) > 0 then ([(($times[-1] - $times[0]) / 86400), 1] | max) else null end) as $days
| ([$merges // [] | .[] | . + {s: (.ts | ts2s), ticket: ((.subject | capture("(^|[^A-Za-z0-9])t(?<n>[0-9]+)-") // null) | if . == null then null else .n | tonumber end)}
    | select(.ticket != null)]) as $merged
| ([$merged[] | .ticket] | unique) as $merged_tickets
| ([$merged_tickets[] | . as $t
    | ([$ev[] | select(.ticket == $t and (.event == "agent_start" or .event == "agent_launch" or .event == "agent_stop")) | .ts | ts2s] | min) as $first
    | ([$merged[] | select(.ticket == $t) | .s] | min) as $m
    | select($first != null and $m >= $first) | $m - $first]) as $leads
| ([$ev[] | select(.event == "merge" and (.duration_s | type) == "number")]) as $timed_merges
| ([$ev[] | select(.event == "gate" and .ticket != null)] | sort_by(.ts) | group_by(.ticket)) as $gates
| ([$ev[] | select(.event == "escalation" and .ticket != null)]) as $escs
| ([$gates[] | .[0].ticket] + [$escs[] | .ticket] | unique) as $rework_tickets
| ([$rework_tickets[] | . as $t
    | ([$gates[] | select(.[0].ticket == $t)] | first // []) as $g
    | ([$g | to_entries[] | select(.value.result == "pass") | .key] | min) as $firstpass
    | ([$g | to_entries[] | select(.value.result == "fail") | .key] | map(select($firstpass != null and . > $firstpass)) | length) as $sent_back
    | ([$g[] | select(.result == "fail")] | length) as $failed
    | {ticket: $t, failed_gates: ($failed - $sent_back), review_send_backs: $sent_back,
       escalations: ([$escs[] | select(.ticket == $t)] | length)}
    | . + {total: (.failed_gates + .review_send_backs + .escalations)}]) as $rework
| ([$stops[] | select(.ticket != null and (.role == "implementer" or .role == "implementer-deep"))] | group_by(.ticket)) as $builds
| ([$ev[] | select(.event == "ci" and (.result == "green" or .result == "failed"))
    | {conclusion: (if .result == "green" then "success" else "failure" end), duration_s: .duration_s}]) as $ci_events
| (if ($ci_events | length) > 0 then $ci_events
   else [($runs // [])[] | select(.conclusion == "success" or .conclusion == "failure")] end) as $ci
| ([$ci[] | if .duration_s != null then .duration_s
            elif .startedAt != null and .updatedAt != null then (.updatedAt | ts2s) - (.startedAt | ts2s)
            else empty end]) as $ci_dur
| ((($usage // {}) | (.rate_limits // .)) as $u | {
    five_hour_pct: ($u.five_hour.used_percentage // null), five_hour_resets_at: ($u.five_hour.resets_at // null),
    seven_day_pct: ($u.seven_day.used_percentage // null), seven_day_resets_at: ($u.seven_day.resets_at // null)}) as $plan
| (types | map(. as $t | {key: $t, value: ([$stops[] | .tokens[$t]] | sumnn)}) | from_entries) as $tok
| ([$stops[] | select(.cost != null)]) as $priced
| ($stops | group_by(.ticket) | map({
    ticket: .[0].ticket, spec: (if .[0].ticket == null then null else $specof[.[0].ticket | tostring] end), runs: length,
    tokens: (. as $g | types | map(. as $t | {key: $t, value: ([$g[] | .tokens[$t]] | sumnn)}) | from_entries),
    usd_low: (map(.cost.low) | sumnn | round2), usd_high: (map(.cost.high) | sumnn | round2),
    unpriced_runs: ([.[] | select(.cost == null)] | length)})) as $by_ticket
| {
  ledger: {events: ($ev | length), first_ts: (if $recorded then ([$ev[] | .ts | select(type == "string")] | sort | first) else null end),
           last_ts: (if $recorded then ([$ev[] | .ts | select(type == "string")] | sort | last) else null end)},
  flow: {
    tickets_merged_per_day: (if $days == null or $merges == null then null else rate($merged_tickets | length; $days) | round1 end),
    lead_time_median_s: ($leads | median),
    merge_time_median_s: ([$timed_merges[] | .duration_s] | median),
    merge_time_total_s: ([$timed_merges[] | .duration_s] | sumnn),
    merge_wait_total_s: (if ($timed_merges | length) == 0 then null else ([$timed_merges[] | .waited_s] | sumnn // 0) end),
    frontier_size: null,
    active_agents: (if $recorded then [$started[] | select(. as $a | $stopped | index($a) | not)] | length else null end),
    stalls: (if $recorded then [$ev[] | select(.event == "stall")] | length else null end)},
  quality: {
    first_try_gate_pass_rate: (rate([$gates[] | select(all(.[]; .result != "fail"))] | length; $gates | length) | round2),
    rework_by_ticket: (if ($rework | length) == 0 then null else $rework end),
    rework_runs: (if ($builds | length) == 0 then null else [$builds[] | length - 1] | add end),
    escalations: (if $recorded then [$ev[] | select(.event == "escalation")] | length else null end),
    ci_pass_rate: (rate([$ci[] | select(.conclusion == "success")] | length; $ci | length) | round2),
    ci_median_duration_s: ($ci_dur | median),
    tests_added: ([$ev[] | select(.event == "gate") | .tests_added] | sumnn),
    review_findings_per_ticket: (([$ev[] | select(.event == "review" and .ticket != null)] | group_by(.ticket)) as $r
      | rate([$r[] | .[-1].findings | select(type == "number")] | add // 0; $r | length) | round2)},
  cost: {
    runs: ($stops | length),
    tokens: (if ($stops | length) == 0 then null else $tok end),
    cache_read_share: (if $tok.cache_read == null then null
      else rate($tok.cache_read; ($tok.input // 0) + $tok.cache_read + ($tok.cache_creation // 0)) | round2 end),
    usd_low: (if ($priced | length) == 0 then null else [$priced[] | .cost.low] | add | round2 end),
    usd_high: (if ($priced | length) == 0 then null else [$priced[] | .cost.high] | add | round2 end),
    unpriced_runs: ([$stops[] | select(.cost == null)] | length),
    by_ticket: $by_ticket,
    by_spec: (if ($by_ticket | map(select(.spec != null)) | length) == 0 then null
      else $by_ticket | map(select(.spec != null)) | group_by(.spec) | map({spec: .[0].spec, tickets: length,
        usd_low: (map(.usd_low) | sumnn | round2), usd_high: (map(.usd_high) | sumnn | round2)}) end),
    plan_usage: $plan,
    prices: {source: $prices.source, retrieved: $prices.retrieved}},
  health: {
    free_root_gb: ($health.root_kb / 1048576 | round1),
    free_tmp_gb: ($health.tmp_kb / 1048576 | round1)}}
