# Factory KPIs

Ledger: 15 events, 2026-01-01T10:00:00Z to 2026-01-01T12:05:00Z.

## Flow

| KPI | Value |
| --- | --- |
| Tickets merged per day | 2 |
| Lead time (median) | 57m 30s |
| Frontier size | n/a |
| Active agents | 0 |
| Stalls | 0 |

## Quality

| KPI | Value |
| --- | --- |
| First-try gate pass rate | 50% |
| Rework (extra builder runs) | 0 |
| Escalations | 0 |
| CI pass rate | 67% |
| CI duration (median) | 3m 00s |
| Tests added | 7 |
| Review findings per ticket | 2 |

## Cost

| KPI | Value |
| --- | --- |
| Agent runs | 3 |
| Tokens: input | 1,600,000 |
| Tokens: output | 320,000 |
| Tokens: cache read | 12,000,000 |
| Tokens: cache creation | 750,000 |
| Cache-read share | 84% |
| Estimated cost (low to high) | $9.48 to $10.60 |
| Runs without a price | 0 |
| Plan usage, 5 hours | 42.5% |
| Plan usage, 7 days | 18% |

### Cost per ticket

| Ticket | Runs | Cost (low to high) |
| --- | --- | --- |
| #3 | 1 | $6.05 to $6.80 |
| #4 | 2 | $3.43 to $3.80 |

### Cost per spec

| Spec | Tickets | Cost (low to high) |
| --- | --- | --- |
| #1 | 2 | $9.48 to $10.60 |

Prices: https://platform.claude.com/docs/en/about-claude/pricing (retrieved 2026-11-12).

## Health

| KPI | Value |
| --- | --- |
| Free disk on / | 10 GB |
| Free temporary space | 2 GB |
