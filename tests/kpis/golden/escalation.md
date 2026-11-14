# Factory KPIs

Ledger: 11 events, 2026-02-01T08:00:00Z to 2026-02-01T10:20:00Z.

## Flow

| KPI | Value |
| --- | --- |
| Tickets merged per day | n/a |
| Lead time (median) | n/a |
| Merge time (median) | n/a |
| Merge time (total) | n/a |
| Merge time spent queued (total) | n/a |
| Frontier size | n/a |
| Active agents | 0 |
| Stalls | 1 |

## Quality

| KPI | Value |
| --- | --- |
| First-try gate pass rate | 0% |
| Rework (extra builder runs) | 2 |
| Escalations | 1 |
| CI pass rate | n/a |
| CI duration (median) | n/a |
| Tests added | 6 |
| Review findings per ticket | n/a |

### Escalations

| Ticket | From | To | Reason |
| --- | --- | --- | --- |
| #5 | implementer | implementer-deep | gate failed twice |

### Rework per ticket

| Ticket | Failed gates | Review send-backs | Escalations | Total |
| --- | --- | --- | --- | --- |
| #5 | 2 | 0 | 1 | 3 |

## Cost

| KPI | Value |
| --- | --- |
| Agent runs | 3 |
| Tokens: input | 800,000 |
| Tokens: output | 200,000 |
| Tokens: cache read | 7,500,000 |
| Tokens: cache creation | 300,000 |
| Cache-read share | 87% |
| Estimated cost (low to high) | $6.98 to $7.65 |
| Runs without a price | 0 |
| Plan usage, 5 hours | n/a |
| Plan usage, 7 days | n/a |

### Cost per ticket

| Ticket | Runs | Cost (low to high) |
| --- | --- | --- |
| #5 | 3 | $6.98 to $7.65 |

Cost per spec: n/a

Prices: https://platform.claude.com/docs/en/about-claude/pricing (retrieved 2026-11-12).

## Health

| KPI | Value |
| --- | --- |
| Free disk on / | 10 GB |
| Free temporary space | 2 GB |
