# Budget decisions from plan usage and spec cost estimates (factory-budget, spawn-gate).
# Arguments: $usage (.factory/usage.json or null), $state (.factory/state.json or null),
# $now (Unix seconds), $t ({five_hour_pct, seven_day_pct, spec_ratio}).
# A window that has already reset (resets_at not after $now) is stale: its recorded
# percentage no longer holds, so it counts as ok. A window absent from the file is unknown.
def num: if type == "number" then . else null end;
def round2: . * 100 | round / 100;
def stamp: if . == null then null else todate end;
def window($k):
  (($usage // {}) | (.rate_limits // .) | .[$k] // null) as $w
  | if ($w | type) != "object" or ($w.used_percentage | num) == null
    then {pct: null, resets_at: null, status: "unknown", stale: false}
    else {pct: $w.used_percentage, resets_at: ($w.resets_at | num)}
      | .stale = (.resets_at != null and .resets_at <= $now)
    end;
def over($w; $limit; $status):
  if $w.status == "unknown" then $w
  elif $w.stale or $w.pct <= $limit then $w + {status: "ok"}
  else $w + {status: $status} end;
def at($w): if $w.resets_at == null then "" else "; the window resets at \($w.resets_at | stamp)" end;

over(window("five_hour"); $t.five_hour_pct; "pause") as $five
| over(window("seven_day"); $t.seven_day_pct; "ask") as $seven
| [(($state // {}).estimates // {}) | to_entries | sort_by(.key | tonumber? // 0)[]
    | select((.value.first | num) != null and (.value.current | num) != null)
    | {spec: (.key | tonumber? // .key), first: .value.first, current: .value.current,
       ratio: (if .value.first > 0 then (.value.current / .value.first) else null end)}
    | .status = (if .ratio != null and .ratio > $t.spec_ratio then "ask" else "ok" end)
    | .ratio = (if .ratio == null then null else .ratio | round2 end)] as $specs
| [
    (select($five.status == "pause")
      | "5-hour plan usage is \($five.pct)%, above the \($t.five_hour_pct)% limit: start no new builders until it resets"
        + (if $five.resets_at == null then "" else " at \($five.resets_at | stamp)" end)),
    (select($seven.status == "ask")
      | "7-day plan usage is \($seven.pct)%, above the \($t.seven_day_pct)% limit: ask the user before continuing" + at($seven)),
    ($specs[] | select(.status == "ask")
      | "spec #\(.spec) estimated cost $\(.current) passes \($t.spec_ratio) times its first estimate $\(.first): report and ask the user before continuing")
  ] as $messages
| {
    thresholds: $t,
    five_hour: $five,
    seven_day: $seven,
    specs: $specs,
    builders: (if $five.status == "pause" then "paused" else "ok" end),
    resume_at: (if $five.status == "pause" then ($five.resets_at | stamp) else null end),
    continue: (if $seven.status == "ask" or ([$specs[] | select(.status == "ask")] | length) > 0 then "ask" else "ok" end),
    messages: $messages
  }
