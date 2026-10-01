# Automation Command Centre — executive assignment

## What this migration does

Lets **Director, MD/CEO, Chairman, Head of HR and Head of E-business** assign
automation work directly to the automation specialist, and makes the
specialist's reported progress move that department's Command Centre bar.

## The workflow it implements

| Actor | What they can do |
|---|---|
| Automation specialist | Raise automation tasks **for themselves**, file progress/milestones, watch the bar rise to 100% |
| Director / MD/CEO / Chairman / Head of HR / Head of E-business | Raise an automation task **for the specialist**, against a chosen department; it appears in their **My Work** and on that department's **Command Centre** |
| Head of Operations, Area/Branch managers | **No change.** They can review work but cannot assign automation |
| Everyone else's tasks | **No change.** Only HR/Head of HR assigns, exactly as before — and their progress never reaches the Command Centre |

## How to apply

```bash
supabase link --project-ref <ref>
supabase db push
```

## Verifying it

The migration is executed against a real Postgres 16 in CI rather than only
being syntax-checked, because the interesting failures here are runtime ones:

```bash
docker run -d --name sqlcheck -e POSTGRES_PASSWORD=postgres postgres:16-alpine
docker cp supabase/migrations/ci/automation_assignment_test_schema.sql sqlcheck:/tmp/schema.sql
docker cp supabase/migrations/20261001000000_automation_executive_assignment.sql sqlcheck:/tmp/migration.sql
docker cp supabase/migrations/ci/automation_assignment_behaviour.sql        sqlcheck:/tmp/behaviour.sql

docker exec sqlcheck psql -U postgres -v ON_ERROR_STOP=1 -f /tmp/schema.sql
docker exec sqlcheck psql -U postgres -v ON_ERROR_STOP=1 -f /tmp/migration.sql
docker exec sqlcheck psql -U postgres -v ON_ERROR_STOP=1 -f /tmp/behaviour.sql
```

Eight checks run. Any regression fails loudly:

1. A plain staff user cannot assign automation work to another person
2. All five commissioning roles can
3. Head of Operations is still excluded
4. A raised request becomes a visible ACC item for the chosen department,
   linked to the task, assigned to the specialist, tagged `automation_centre`
5. An ACC item cannot be filed against the wrong department
6. The bar follows reported progress 0 → 30 → 100
7. An ordinary HR task never leaks into the Command Centre roll-up
8. Items nobody has filed progress against keep the original status weighting
   (live 100 / in_progress 50 / not started 0), so the existing register renders
   identically

## Design notes worth knowing before you apply this

**A new RPC, not a widened one.** `create_work_task_with_steps` is the general
task path HR uses for everything. Widening its permission check to admit the
executive roles would quietly give them the power to create *any* task for *any*
person. `assign_automation_work_task` is separate and can only ever create a
task sourced to the automation register.

**A separate predicate, not a widened `can_review_work_tasks()`.** Reviewing
progress and assigning work are different powers. `can_assign_automation_task()`
keeps them separate so granting one does not silently grant the other.

**An explicit ACC item must match the department.** Passing an item from one
department while claiming another is rejected, otherwise a progress number could
be parked against a bar it has nothing to do with.

**Progress uses the *pending* percentage, not the approved one.** The Command
Centre is the specialist's own KPI monitor. A self-reported figure that has to
wait for a reviewer is a queue, not a monitor. The review workflow still exists
and still gates payment — it just no longer gates the visible bar.

**`report_seq` exists because `created_at` cannot break ties.** `created_at`
defaults to `now()`, which is the *transaction* timestamp, so two reports filed in
one transaction are indistinguishable by time and "latest claim" becomes
arbitrary. The identity column makes the ordering monotonic. This was a real bug
caught by the CI checks — the bar was freezing on whichever report Postgres
returned first.