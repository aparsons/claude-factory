# Renders the KPI object (JSON on stdin) as Markdown. null prints as n/a.
def na(f): if . == null then "n/a" else f end;
def round1: (. * 10 | round) / 10;
def pct: na(. * 100 | round1 | tostring + "%");
def commas: tostring | if length <= 3 then . else (.[:-3] | commas) + "," + .[-3:] end;
def num: na(round | commas);
def two: (. * 100 | round) as $c | "\($c / 100 | floor).\(($c % 100) | tostring | if length < 2 then "0" + . else . end)";
def usd: na("$" + two);
def dur: na(round | . as $s
  | if $s >= 3600 then "\($s / 3600 | floor)h \(($s % 3600) / 60 | floor | tostring | if length < 2 then "0" + . else . end)m"
    elif $s >= 60 then "\($s / 60 | floor)m \($s % 60 | tostring | if length < 2 then "0" + . else . end)s"
    else "\($s)s" end);
def range: if .usd_low == null then "n/a" else "\(.usd_low | usd) to \(.usd_high | usd)" end;
def row($k; $v): "| \($k) | \($v) |";
def gb: na(tostring + " GB");

"# Factory KPIs",
"",
"Ledger: \(.ledger.events) events" + (if .ledger.first_ts == null then "" else ", \(.ledger.first_ts) to \(.ledger.last_ts)" end) + ".",
"",
"## Flow", "", "| KPI | Value |", "| --- | --- |",
row("Tickets merged per day"; .flow.tickets_merged_per_day | na(tostring)),
row("Lead time (median)"; .flow.lead_time_median_s | dur),
row("Merge time (median)"; .flow.merge_time_median_s | dur),
row("Merge time (total)"; .flow.merge_time_total_s | dur),
row("Merge time spent queued (total)"; .flow.merge_wait_total_s | dur),
row("Frontier size"; .flow.frontier_size | num),
row("Active agents"; .flow.active_agents | num),
row("Stalls"; .flow.stalls | num),
"",
"## Quality", "", "| KPI | Value |", "| --- | --- |",
row("First-try gate pass rate"; .quality.first_try_gate_pass_rate | pct),
row("Rework (extra builder runs)"; .quality.rework_runs | num),
row("Escalations"; .quality.escalations | num),
row("CI pass rate"; .quality.ci_pass_rate | pct),
row("CI duration (median)"; .quality.ci_median_duration_s | dur),
row("Tests added"; .quality.tests_added | num),
row("Review findings per ticket"; .quality.review_findings_per_ticket | na(tostring)),
"",
(if .quality.rework_by_ticket == null then "Rework per ticket: n/a" else
  "### Rework per ticket", "", "| Ticket | Failed gates | Review send-backs | Escalations | Total |", "| --- | --- | --- | --- | --- |",
  (.quality.rework_by_ticket[] | "| #\(.ticket) | \(.failed_gates) | \(.review_send_backs) | \(.escalations) | \(.total) |") end),
"",
"## Cost", "", "| KPI | Value |", "| --- | --- |",
row("Agent runs"; .cost.runs | num),
row("Tokens: input"; .cost.tokens.input | num),
row("Tokens: output"; .cost.tokens.output | num),
row("Tokens: cache read"; .cost.tokens.cache_read | num),
row("Tokens: cache creation"; .cost.tokens.cache_creation | num),
row("Cache-read share"; .cost.cache_read_share | pct),
row("Estimated cost (low to high)"; .cost | range),
row("Runs without a price"; .cost.unpriced_runs | num),
row("Plan usage, 5 hours"; .cost.plan_usage.five_hour_pct | na(tostring + "%")),
row("Plan usage, 7 days"; .cost.plan_usage.seven_day_pct | na(tostring + "%")),
"",
(if (.cost.by_ticket | length) == 0 then "Cost per ticket: n/a" else
  "### Cost per ticket", "", "| Ticket | Runs | Cost (low to high) |", "| --- | --- | --- |",
  (.cost.by_ticket[] | "| \(if .ticket == null then "no ticket" else "#\(.ticket)" end) | \(.runs) | \(range) |") end),
"",
(if .cost.by_spec == null then "Cost per spec: n/a" else
  "### Cost per spec", "", "| Spec | Tickets | Cost (low to high) |", "| --- | --- | --- |",
  (.cost.by_spec[] | "| #\(.spec) | \(.tickets) | \(range) |") end),
"",
"Prices: \(.cost.prices.source) (retrieved \(.cost.prices.retrieved)).",
"",
"## Health", "", "| KPI | Value |", "| --- | --- |",
row("Free disk on /"; .health.free_root_gb | gb),
row("Free temporary space"; .health.free_tmp_gb | gb)
