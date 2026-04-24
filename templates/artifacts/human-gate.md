---
title: "{{brief_id}} {{flavor}} — {{brief_title_short}}"
brief: {{brief_id}}
category: {{flavor_category}}
escalated_at: {{iso_timestamp}}
status: awaiting-mattie
recommendation: {{recommendation_slug}}
---

# {{flavor_heading}} — {{brief_title}}

!!! abstract "TL;DR"
    **What shipped:** {{product_description_one_sentence}}

    **Target moment:** {{target_experience_and_emotion}}

    **Your part:** {{mattie_ask_with_time_estimate}}

<!-- If there's a long background download/process, add a tip block here: -->
<!-- !!! tip "Start this first (~X min background)"
    {{background_task_command}} -->

!!! success "Why it matters"
    {{why_this_matters_product_terms}}

## What shipped

| # | Task | Landed as |
|---|---|---|
{{shipped_tasks_table_rows}}

{{branch_status_line}}

## What's gated on you

{{gated_actions_bullet_list}}

Worker can't {{why_worker_cant_complete}}.

## Prerequisites

<!-- Use admonitions: warning = hardware/soft gates, danger = hard blockers, info = nice-to-know -->
!!! warning "{{gate_label}}"
    {{gate_description}}

!!! info "Tooling"
    {{tooling_prereqs}}

## Runbook

<!-- Tag each phase: `blocking` / `background` / `requires_focus` -->
### Phase 1 — {{phase_1_name}}

**{{phase_1_tag}}.** {{phase_1_time_estimate}}

```bash
{{phase_1_commands}}
```

### Phase 2 — {{phase_2_name}}

**{{phase_2_tag}}.** {{phase_2_time_estimate}}

{{phase_2_body}}

<!-- Add more phases as needed for this specific brief -->

## What "works" looks like

{{concrete_success_signals_bullet_list}}

## Alternatives if a gate fails

<!-- Use !!! note blocks for each alternative path -->
!!! note "If {{gate_failure_scenario}}"
    {{alternative_action}}

## Resolution options

| Option | When to pick | Action |
|---|---|---|
| **Approve** | {{approve_condition}} | `{{approve_command}}` |
| **Iterate** | {{iterate_condition}} | {{iterate_action}} |
| **Reject** | {{reject_condition}} | `{{reject_command}}` |

## Scav recommendation

**{{recommendation_headline}}**

{{recommendation_reasoning}}

## What you should feel

{{emotional_frame_if_works}}

{{emotional_frame_if_doesnt_work}}

## If something breaks mid-runbook

Capture what you can and stop:

{{break_capture_checklist}}

Drop it in `wiki/briefs/cards/{{brief_id}}/{{flavor}}-failure-YYYY-MM-DD.md` + ping me. I'll diagnose.

## References

- [Brief index](index.md)
- [plan.md](plan.md)
- [closeout.md](closeout.md) — written at completion
{{additional_references}}
