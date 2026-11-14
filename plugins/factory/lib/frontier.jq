# Computes the frontier from open ready-for-agent issues.
# Arguments:
#   $issues  `gh issue list --state open --label <ready> --json number,title,state,createdAt,labels,
#            milestone,assignees,parent,blockedBy,blocking,subIssues,subIssuesSummary`
#   $state   .factory/state.json (assignments, merged, integration)
#   $runs    `gh run list --branch <default> --json workflowName,status,conclusion,url,createdAt` or null
#   $default the default branch name or null
#   $roles   the role table from the agent definitions (factory_roles in lib/common.sh)
#   $settings .factory/settings.json ({} when absent); roles override a role's model or effort,
#            deep_when overrides when a ticket goes to implementer-deep
# A ticket goes to implementer-deep when it (or its spec) is security work, carries a
# foundational label, or unblocks at least three open issues; every other ticket to implementer.
# A spec is an issue without a parent that has sub-issues, or is marked as a spec (a `Spec:` or `PRD:`
# title, a `spec` or `prd` label, or a `## User Stories` heading in its body, as `/to-spec` writes;
# factory-frontier turns the body into .body_marks_spec). A ticket is a sub-issue of a spec, or a
# standalone ticket: an issue without a parent or sub-issues that is not marked as a spec. A
# standalone ticket is its own unit of integration: its `spec` is its own number, its integration
# branch is ticket/<n>-<slug>, and it is listed in `specs` as a one-ticket entry with
# standalone: true. A ticket merged into its
# integration branch stays open until the spec's pull request merges, so the state's merged tickets
# count as done: they are not offered again and they no longer block.
# A ticket's own native blockers decide its readiness. A spec-level link (its spec is blocked by
# another spec) holds a ticket only when the ticket has no blocker of its own inside the blocking
# spec's work (the spec and its sub-issues, open or closed); such a ticket is `spec-blocked`, with
# `blocked_by_spec` naming the spec. A ticket with its own link there is held by that blocker alone.

def lc: ascii_downcase;
def names: [.labels[]?.name];
def slug($n): lc | sub("^spec\\s*:\\s*"; "") | gsub("[^a-z0-9]+"; "-") | .[0:$n] | sub("^-+"; "") | sub("-+$"; "");
def key: tostring;
def nsubs: .subIssuesSummary.total // ((.subIssues.nodes // []) | length);
def marks_spec:
  (.title // "" | test("^\\s*(\\[\\s*(spec|prd)\\s*\\]|(spec|prd)\\s*:)"; "i"))
  or any(.labels[]?.name; ascii_downcase | test("^((type|kind)[:/ -]?)?(spec|prd)$"))
  or (.body_marks_spec // false);
def is_standalone: .parent == null and nsubs == 0 and (marks_spec | not);

($settings.roles // {}) as $role_over
| ($roles * $role_over) as $R
| ({security: true, labels: ["foundation", "foundational", "architecture", "breaking-change"], unblocks_at_least: 3}
   * ($settings.deep_when // {})) as $deep
| ($state.merged // {}) as $merged
| ($state.assignments // {}) as $assigned
| ($settings.factory_assignee // null) as $me
| ($issues | map({key: (.number | key), value: .}) | from_entries) as $by
| def done($n): ($merged | has($n | key));
  def is_security: any(names[]; lc | test("(^|[^a-z])security([^a-z]|$)"));
  # priority of one label: its index in settings.priority_labels (highest first), else the
  # built-in tiers; null when the label is not a priority label
  def label_tier:
    if ($settings.priority_labels | type) == "array" then (. as $n | $settings.priority_labels | index([$n]))
    else lc
      | if test("^(p0|critical|urgent)$|^priority[:/ -]?(critical|urgent|p0)$") then 0
        elif test("^(p1|high)$|^priority[:/ -]?(high|p1)$") then 1
        elif test("^(p2|medium|normal)$|^priority[:/ -]?(medium|normal|p2)$") then 2
        elif test("^(p3|p4|low)$|^priority[:/ -]?(low|p3|p4)$") then 4
        else null end
    end;
  # unlabelled: after every listed label, or between medium and low for the built-in tiers
  def no_tier: if ($settings.priority_labels | type) == "array" then ($settings.priority_labels | length) else 3 end;
  # {tier, label} of an issue's highest priority label
  def prio: ([names[] | {label: ., tier: label_tier} | select(.tier != null)] | min_by(.tier)) // {tier: no_tier, label: null};
  # open blockers that are not merged; null when GitHub listed fewer nodes than it counted
  def open_blockers:
    [(.blockedBy.nodes // [])[] | select(.state == "OPEN" and (done(.number) | not)) | .number] as $b
    | if ((.blockedBy.totalCount // 0) > ((.blockedBy.nodes // []) | length)) then $b + ["more"] else $b end;
  # the work of a blocking spec: the spec itself and its sub-issues (as it lists them, and as listed here)
  def spec_work($b): ([$b] + [($by[$b | key].subIssues.nodes // [])[] | .number] + [$issues[] | select(.parent.number == $b) | .number]) | unique;
  # the spec-level blockers that hold this ticket: a spec-level link holds a ticket only when the
  # ticket has no blocker of its own (open or finished) inside the blocking spec's work
  def held_by_spec($spec_blockers):
    [(.blockedBy.nodes // [])[] | .number] as $own
    | [$spec_blockers[] | . as $b
       | if $b == "more" then $b
         elif (spec_work($b) as $w | $own | any(. as $o | $w | index($o))) then empty
         else $b end];
  def assignee_ok: ((.assignees // []) | length == 0) or ($me != null and all(.assignees[]; .login == $me));

  # blocking graph over open issues: number -> numbers it blocks
  ($issues | map({key: (.number | key), value: [(.blocking.nodes // [])[] | select(.state == "OPEN") | .number]}) | from_entries) as $g
  | def unblocks($start):
      {seen: [], todo: [$start]}
      | until(.todo | length == 0;
          .todo[0] as $n | .todo |= .[1:]
          | reduce (($g[$n | key] // [])[]) as $m (.;
              if $m == $start or (.seen | index($m)) then . else .seen += [$m] | .todo += [$m] end))
      | .seen | length;

  # standalone tickets: parent-less, no sub-issues, not marked as a spec
  ([$issues[] | select(is_standalone) | .number]) as $alone
  # specs: other parent-less issues in the list, and parents of listed tickets
  | ([$issues[] | select(.parent == null and (is_standalone | not)) | .number] + [$issues[] | .parent.number // empty] | unique) as $spec_nums
  | ($spec_nums | map(. as $s | {key: ($s | key), value: (
      ($by[$s | key]) as $i
      | ([$issues[] | select(.parent.number == $s)][0].parent) as $p
      | {number: $s, title: ($i.title // $p.title // ""),
         listed: ($i != null),
         labels: (if $i then ($i | names) else [] end),
         security: (if $i then ($i | is_security) else false end),
         prio: (if $i then ($i | prio) else {tier: no_tier, label: null} end),
         milestone: ($i.milestone // null),
         blockers: (if $i then ($i | open_blockers) else [] end),
         branch: ($state.integration[$s | key].branch // ("spec/\($s)-" + (($i.title // $p.title // "") | slug(40))))}
    )}) | from_entries) as $S

  # a standalone ticket stands in for its own spec: no spec-level labels, milestone or blockers
  | ($alone | map(. as $n | {key: ($n | key), value: (
      {number: $n, title: $by[$n | key].title, listed: true, standalone: true, labels: [], security: false,
       prio: {tier: no_tier, label: null}, milestone: null, blockers: [],
       branch: ($state.integration[$n | key].branch // ("ticket/\($n)-" + ($by[$n | key].title | slug(40))))}
    )}) | from_entries) as $A

  # tickets in the list
  | [$issues[] | select(.parent != null or is_standalone) | . as $t
      | (.parent == null) as $standalone
      | (if $standalone then $A[.number | key] else $S[.parent.number | key] end) as $sp
      | (.milestone // $sp.milestone) as $ms
      | (open_blockers) as $ob
      | (held_by_spec($sp.blockers)) as $held
      | (unblocks(.number)) as $ub
      | (is_security or $sp.security) as $sec
      | ([names[] | lc] as $l | $sec and $deep.security
         or any($deep.labels[]; . as $d | $l | index($d))
         or $ub >= $deep.unblocks_at_least) as $is_deep
      | (if $is_deep then "implementer-deep" else "implementer" end) as $role
      | {number, title, spec: $sp.number, standalone: $standalone, spec_branch: $sp.branch,
         branch: ("t\(.number)-" + (.title | slug(30))),
         labels: names, security: $sec,
         priority: ([prio, $sp.prio] | min_by(.tier) | .tier),
         priority_label: ([prio, $sp.prio] | min_by(.tier) | .label),
         milestone: (if $ms then {title: $ms.title, due_on: ($ms.dueOn // null), number: ($ms.number // null)} else null end),
         unblocks: $ub, created_at: .createdAt,
         role: $role, agent: "factory:\($role)", model: $R[$role].model, effort: $R[$role].effort,
         status: (if done(.number) then "merged"
                  elif $assigned | has($t.number | key) then "running"
                  elif ($ob | length) > 0 then "blocked"
                  elif ($held | length) > 0 then "spec-blocked"
                  elif (assignee_ok | not) then "assigned-elsewhere"
                  else "ready" end),
         blocked_by: $ob, blocked_by_spec: $held, assignees: [(.assignees // [])[].login]}] as $tickets

  # default branch health: latest completed run of each workflow
  | ([($runs // []) | group_by(.workflowName)[] | map(select(.status == "completed")) | sort_by(.createdAt) | last // empty
      | select(.conclusion as $c | ["failure", "timed_out", "startup_failure"] | index($c))
      | {workflow: .workflowName, conclusion, url}]) as $red

  | ($tickets | map(select(.status == "ready"))
      | sort_by([(if .security then 0 else 1 end), .priority,
                 (.milestone.due_on // "9999-12-31"), (.milestone.number // 1000000000),
                 (- .unblocks), .created_at, .number])
      | to_entries | map(.value + {rank: (.key + 1)})) as $ready

  | {
    default_branch: (if $default == null then null else {name: $default, red: ($red | length > 0), failing: $red} end),
    alerts: (if ($red | length) > 0 then [{kind: "default-branch-red", branch: $default, failing: $red}] else [] end),
    ready: $ready,
    running: ([$tickets[] | select(.status == "running") | {number, spec, standalone, title}]
      + [$assigned[] | select(.ticket as $n | $tickets | map(.number) | index($n) | not) | {number: .ticket, spec, title: null}]),
    blocked: [$tickets[] | select(.status == "blocked" or .status == "spec-blocked" or .status == "assigned-elsewhere")
      | {number, spec, standalone, title, status, blocked_by: (if .status == "spec-blocked" then .blocked_by_spec else .blocked_by end), blocked_by_spec, assignees}],
    specs: [($spec_nums[] | $S[key]), ($alone[] | $A[key]) | . as $sp | .number
      | (if $sp.standalone then [{number: $sp.number, state: "OPEN"}]
         elif $sp.listed then [($by[key].subIssues.nodes // [])[] | {number, state}]
         else [$tickets[] | select(.spec == $sp.number) | {number, state: "OPEN"}] end) as $subs
      | (if $sp.standalone then 1 elif $sp.listed then ($by[key] | nsubs) else ($subs | length) end) as $total
      | [$subs[] | select(.state == "OPEN" and (done(.number) | not)) | .number] as $open
      | [$tickets[] | select(.spec == $sp.number)] as $mine
      | {number: $sp.number, title: $sp.title, standalone: ($sp.standalone // false), branch: $sp.branch, tickets: $total,
         merged: ([$subs[] | select(done(.number))] | length),
         closed: ([$subs[] | select(.state == "CLOSED")] | length),
         open: ($open | length),
         ready: ([$mine[] | select(.status == "ready")] | length),
         running: ([$mine[] | select(.status == "running")] | length),
         not_for_agents: [$open[] | . as $n | select($mine | map(.number) | index($n) | not)],
         status: (if $total == 0 then "needs-tickets"
                  elif ($open | length) == 0 then "complete"
                  elif ([$mine[] | select(.status == "running")] | length) > 0 then "running"
                  elif ([$mine[] | select(.status == "ready")] | length) > 0 then "ready"
                  else "blocked" end)}],
    needs_tickets: [$spec_nums[] | $S[key] as $sp | select($sp.listed and ($by[key] | nsubs) == 0) | .]
  }
