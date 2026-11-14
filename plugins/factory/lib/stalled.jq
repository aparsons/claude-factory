# merge_stalled($events; $git_merges; $now; $minutes): the tickets whose latest gate event is a
# pass with nothing after it (no merge or unassign event later in the ledger, no merge in the git
# log at or after the pass) for longer than $minutes, as [{ticket, spec, since, age_min}].
#   $events      ledger events in file order
#   $git_merges  [{ticket, s}] merges seen in the git log (s: epoch seconds), or null
#   $now         ISO 8601 time
# A later fail replaces the latest gate event, so it clears the flag too.
include "ts";
def merge_stalled($events; $git_merges; $now; $minutes):
  ($now | ts2s) as $t
  | [$events | to_entries[] | select(.value.event == "gate" and .value.ticket != null and (.value.ts | type) == "string")]
  | group_by(.value.ticket)
  | map(.[-1] | . as $g | select($g.value.result == "pass")
      | ($g.value.ts | ts2s) as $s
      | select(([$events[$g.key + 1:][] | select(.ticket == $g.value.ticket and (.event == "merge" or .event == "unassign"))] | length) == 0
          and ([($git_merges // [])[] | select(.ticket == $g.value.ticket and .s >= $s)] | length) == 0)
      | select($t - $s > $minutes * 60)
      | {ticket: $g.value.ticket, spec: $g.value.spec, since: $g.value.ts, age_min: (($t - $s) / 60 | floor)})
  | sort_by(.ticket);
