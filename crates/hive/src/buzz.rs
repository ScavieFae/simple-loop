use crate::state::{load_daemon_log_events, parse_log_ts, RawLogLine};
use chrono::{DateTime, Utc};
use ratatui::{
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span, Text},
};
use serde::Deserialize;
use std::{
    fs,
    io::{BufRead, BufReader},
    path::Path,
    time::Duration,
};

// Color constants — mirrors main.rs verbatim per brief anti-pattern
const AMBER: Color = Color::from_u32(0x00F5A623);
const GOLD: Color = Color::from_u32(0x00FFCE5C);
const CORAL: Color = Color::from_u32(0x00FF6B6B);
const MUTED: Color = Color::from_u32(0x006A6A6A);
const INDIGO: Color = Color::from_u32(0x007B8FD4);
const LAVENDER: Color = Color::from_u32(0x00B894E6);
const POP_GREEN: Color = Color::from_u32(0x0039FF80);
const ORANGE: Color = Color::from_u32(0x00FF8C00);
const TEAL: Color = Color::from_u32(0x005DADE2);

// Ceremonial gold for merge events — distinct from STAMP_GREEN and GOLD.
pub const SHINY_GOLD: Color = Color::from_u32(0x00FFD700);

// When a log event has no matching metrics entry, assign a fallback cost in
// the median bucket range ($0.05–$0.30) so unfatributed events stay visible
// at base intensity rather than rendering faint.
const FALLBACK_COST: f64 = 0.10;

// Maximum timestamp delta (seconds) to consider a metrics entry a match for
// a log event when joining by proximity (session_id absent).
const METRICS_MATCH_WINDOW_SECS: i64 = 1800;

fn actor_color(actor: Option<&str>) -> Color {
    match actor {
        Some("queen") | Some("conductor") => LAVENDER,
        Some("daemon") => AMBER,
        Some("worker") => POP_GREEN,
        Some("validator") => ORANGE,
        Some("reviewer") => INDIGO,
        Some("scout") => TEAL,
        Some("builder") | Some("coder") | Some("researcher") => GOLD,
        _ => MUTED,
    }
}

// Returns CORAL for reject-class events, SHINY_GOLD for merge-class events,
// None for everything else. Applied after actor_color, before intensity.
fn event_color_override(action: Option<&str>) -> Option<Color> {
    let action = action?;
    let lower = action.to_lowercase();
    if lower.contains("error")
        || lower.contains("escalate")
        || lower.contains("fail")
        || lower.contains("reject")
    {
        return Some(CORAL);
    }
    if lower.contains("merge") || lower.contains("approve") {
        return Some(SHINY_GOLD);
    }
    None
}

// Map cost_usd to a 0–4 intensity bucket per the log-scale table in the brief.
pub fn cost_to_bucket(cost: f64) -> u8 {
    if cost < 0.005 {
        0
    } else if cost < 0.05 {
        1
    } else if cost < 0.30 {
        2
    } else if cost < 1.00 {
        3
    } else {
        4
    }
}

// Adjust color brightness based on bucket. Returns (adjusted_color, bold).
// Bucket 0–1 dim by multiplying channels. Bucket 3–4 brighten by blending
// toward white. Bucket 4 also signals bold.
fn apply_intensity(color: Color, bucket: u8) -> (Color, bool) {
    let Color::Rgb(r, g, b) = color else {
        return (color, bucket >= 4);
    };
    let (r, g, b, bold) = match bucket {
        0 => (
            (r as f32 * 0.50) as u8,
            (g as f32 * 0.50) as u8,
            (b as f32 * 0.50) as u8,
            false,
        ),
        1 => (
            (r as f32 * 0.70) as u8,
            (g as f32 * 0.70) as u8,
            (b as f32 * 0.70) as u8,
            false,
        ),
        2 => (r, g, b, false),
        3 => (
            (r as f32 + (255.0 - r as f32) * 0.30) as u8,
            (g as f32 + (255.0 - g as f32) * 0.30) as u8,
            (b as f32 + (255.0 - b as f32) * 0.30) as u8,
            false,
        ),
        _ => (
            (r as f32 + (255.0 - r as f32) * 0.60) as u8,
            (g as f32 + (255.0 - g as f32) * 0.60) as u8,
            (b as f32 + (255.0 - b as f32) * 0.60) as u8,
            true,
        ),
    };
    (Color::Rgb(r, g, b), bold)
}

// ── metrics.jsonl ─────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct RawMetricLine {
    timestamp: Option<String>,
    session_id: Option<String>,
    cost_usd: Option<f64>,
    duration_ms: Option<u64>,
}

struct MetricEntry {
    ts: DateTime<Utc>,
    session_id: Option<String>,
    cost_usd: f64,
    duration_ms: Option<u64>,
}

fn load_metrics(path: &Path) -> Vec<MetricEntry> {
    let mut entries: Vec<MetricEntry> = Vec::new();
    let Ok(file) = fs::File::open(path) else {
        return entries;
    };
    let reader = BufReader::new(file);
    for line in reader.lines() {
        let Ok(line) = line else { continue };
        if line.trim().is_empty() {
            continue;
        }
        let Ok(raw) = serde_json::from_str::<RawMetricLine>(&line) else {
            continue;
        };
        let Some(ts_str) = raw.timestamp.as_deref() else { continue };
        let Some(ts) = parse_log_ts(ts_str) else { continue };
        entries.push(MetricEntry {
            ts,
            session_id: raw.session_id,
            cost_usd: raw.cost_usd.unwrap_or(0.0),
            duration_ms: raw.duration_ms,
        });
    }
    entries.sort_by_key(|e| e.ts);
    entries
}

// Try session_id join first; fall back to nearest-timestamp within window.
fn find_metric(
    metrics: &[MetricEntry],
    event_ts: DateTime<Utc>,
    event_session_id: Option<&str>,
) -> (f64, Option<u64>) {
    if let Some(sid) = event_session_id {
        if let Some(m) = metrics.iter().find(|m| m.session_id.as_deref() == Some(sid)) {
            return (m.cost_usd, m.duration_ms);
        }
    }
    let best = metrics.iter().min_by_key(|m| {
        (m.ts - event_ts).num_seconds().unsigned_abs()
    });
    if let Some(m) = best {
        if (m.ts - event_ts).num_seconds().abs() <= METRICS_MATCH_WINDOW_SECS {
            return (m.cost_usd, m.duration_ms);
        }
    }
    (FALLBACK_COST, None)
}

// ── data model ────────────────────────────────────────────────────────────────

pub struct BuzzEvent {
    pub ts: Option<DateTime<Utc>>,
    pub actor: Option<String>,
    pub action: Option<String>,
    pub brief: Option<String>,
    pub cost_usd: f64,
    pub intensity_bucket: u8,
    pub duration_ms: Option<u64>,
}

pub struct BuzzState {
    pub events: Vec<BuzzEvent>,
}

// ── loader ────────────────────────────────────────────────────────────────────

pub fn load_buzz_state(window: Duration, offset_from_now_secs: i64) -> BuzzState {
    let log_path = Path::new(".loop/state/log.jsonl");
    let metrics_path = Path::new(".loop/state/metrics.jsonl");
    let window_end = Utc::now() - chrono::Duration::seconds(offset_from_now_secs);
    let cutoff = window_end - chrono::Duration::seconds(window.as_secs() as i64);

    let metrics = load_metrics(metrics_path);
    let mut events: Vec<BuzzEvent> = Vec::new();

    if let Ok(file) = fs::File::open(log_path) {
        let reader = BufReader::new(file);
        for line in reader.lines() {
            let Ok(line) = line else { continue };
            if line.trim().is_empty() {
                continue;
            }
            let Ok(entry) = serde_json::from_str::<RawLogLine>(&line) else { continue };

            let ts = entry.ts_str().and_then(parse_log_ts);

            // Filter: skip events outside the time window
            if let Some(event_ts) = ts {
                if event_ts < cutoff {
                    continue;
                }
            }

            let (cost_usd, duration_ms) = if let Some(event_ts) = ts {
                find_metric(&metrics, event_ts, entry.session_id.as_deref())
            } else {
                (FALLBACK_COST, None)
            };
            let intensity_bucket = cost_to_bucket(cost_usd);

            events.push(BuzzEvent {
                ts,
                actor: entry.derived_actor(),
                action: entry.event.or(entry.action),
                brief: entry.brief,
                cost_usd,
                intensity_bucket,
                duration_ms,
            });
        }
    }

    // Workers and validators write to daemon.log, not log.jsonl — include
    // them so worker events appear as POP_GREEN hexes.
    let daemon_log_path = Path::new(".loop/logs/daemon.log");
    let max_age = window.as_secs() as i64 + offset_from_now_secs + 60;
    for ev in load_daemon_log_events(daemon_log_path, max_age) {
        if let Some(ts) = ev.ts {
            if ts < cutoff || ts > window_end {
                continue;
            }
        }
        let (cost_usd, duration_ms) = ev
            .ts
            .map(|t| find_metric(&metrics, t, None))
            .unwrap_or((FALLBACK_COST, None));
        let intensity_bucket = cost_to_bucket(cost_usd);
        events.push(BuzzEvent {
            ts: ev.ts,
            actor: ev.actor,
            action: ev.event,
            brief: ev.brief,
            cost_usd,
            intensity_bucket,
            duration_ms,
        });
    }

    // Chronological order (oldest → newest); newest displayed top-left in renderer
    events.sort_by(|a, b| match (a.ts, b.ts) {
        (Some(at), Some(bt)) => at.cmp(&bt),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    });

    BuzzState { events }
}

// ── renderer ──────────────────────────────────────────────────────────────────

/// Paint the Buzz hex grid.
///
/// Layout: offset honeycomb rows, newest event top-left, scanning left→right
/// then top→bottom. Each hex = ⬢ (U+2B22) + trailing space = 2 display cols.
/// Odd rows are indented 1 space for the honeycomb offset.
///
/// NOTE: ⬢ renders as 1 column in unicode-width but some terminal fonts
/// (e.g. certain Nerd Font variants in Warp) paint it at 2 columns, which
/// shifts subsequent glyphs. If the grid looks misaligned, that's the
/// escalation trigger noted in the brief — don't paper over it here.
pub fn render_buzz<'a>(state: &BuzzState, area: Rect, cursor: usize) -> Text<'a> {
    if state.events.is_empty() {
        return Text::from(Line::from(vec![
            Span::styled("⬡ ", Style::default().fg(MUTED)),
            Span::styled("no buzz yet", Style::default().fg(MUTED)),
        ]));
    }

    // inner_width excludes the 2-column border (1 left + 1 right)
    let inner_width = area.width.saturating_sub(2) as usize;
    // Each hex slot: 1 glyph col + 1 space = 2 cols per slot
    let slot = 2usize;
    let hexes_per_even = (inner_width / slot).max(1);
    // Odd rows start with 1 leading space → 1 fewer slot fits
    let hexes_per_odd = (inner_width.saturating_sub(1) / slot).max(1);

    let event_count = state.events.len();
    let mut lines: Vec<Line<'a>> = Vec::new();
    let mut consumed = 0usize;
    let mut row = 0usize;

    while consumed < event_count {
        let is_odd = row % 2 == 1;
        let row_cap = if is_odd { hexes_per_odd } else { hexes_per_even };
        let row_end = (consumed + row_cap).min(event_count);

        let mut spans: Vec<Span<'a>> = Vec::new();
        if is_odd {
            spans.push(Span::raw(" "));
        }

        for ev_idx in consumed..row_end {
            // Reverse index: newest event (highest index) → leftmost hex
            let ev = &state.events[event_count - 1 - ev_idx];

            // Event-type override takes priority over actor base color
            let base_color = event_color_override(ev.action.as_deref())
                .unwrap_or_else(|| actor_color(ev.actor.as_deref()));

            let (color, bold) = apply_intensity(base_color, ev.intensity_bucket);
            let is_cursor = ev_idx == cursor;
            let style = {
                let s = Style::default().fg(color);
                let s = if bold { s.add_modifier(Modifier::BOLD) } else { s };
                if is_cursor { s.add_modifier(Modifier::UNDERLINED) } else { s }
            };
            spans.push(Span::styled("⬢ ", style));
        }

        lines.push(Line::from(spans));
        consumed = row_end;
        row += 1;
    }

    Text::from(lines)
}

/// Render the detail line for the currently-selected hex.
/// Shows: actor · action · brief · cost · wall-time · timestamp
pub fn render_buzz_detail<'a>(state: &BuzzState, cursor: usize) -> Text<'a> {
    if state.events.is_empty() {
        return Text::from(Line::from(Span::styled("—", Style::default().fg(MUTED))));
    }
    let count = state.events.len();
    let idx = cursor.min(count - 1);
    let ev = &state.events[count - 1 - idx]; // newest-first: cursor 0 = newest event

    let actor_str = ev.actor.as_deref().unwrap_or("?").to_string();
    let action_str = ev.action.as_deref().unwrap_or("?").to_string();
    let brief_str = ev.brief.as_deref().unwrap_or("—").to_string();
    let cost_str = format!("${:.4}", ev.cost_usd);
    let wall_str = ev
        .duration_ms
        .map(|ms| {
            if ms >= 1000 {
                format!("{:.1}s", ms as f64 / 1000.0)
            } else {
                format!("{}ms", ms)
            }
        })
        .unwrap_or_else(|| "—".to_string());
    let ts_str = ev
        .ts
        .map(|t| t.format("%H:%M:%S UTC").to_string())
        .unwrap_or_else(|| "?".to_string());

    let ev_color = event_color_override(ev.action.as_deref())
        .unwrap_or_else(|| actor_color(ev.actor.as_deref()));

    let line1 = Line::from(vec![
        Span::styled(actor_str, Style::default().fg(ev_color)),
        Span::styled(" · ", Style::default().fg(MUTED)),
        Span::styled(action_str, Style::default().fg(Color::White)),
        Span::styled(" · brief: ", Style::default().fg(MUTED)),
        Span::styled(brief_str, Style::default().fg(GOLD)),
    ]);
    let line2 = Line::from(vec![
        Span::styled("cost: ", Style::default().fg(MUTED)),
        Span::styled(cost_str, Style::default().fg(AMBER)),
        Span::styled("  wall: ", Style::default().fg(MUTED)),
        Span::styled(wall_str, Style::default().fg(Color::White)),
        Span::styled("  ts: ", Style::default().fg(MUTED)),
        Span::styled(ts_str, Style::default().fg(MUTED)),
    ]);

    Text::from(vec![line1, line2])
}

/// Render the legend strip: ⬢ actor_name for each apiary role.
pub fn render_buzz_legend<'a>() -> Text<'a> {
    let pairs: &[(&'static str, Color)] = &[
        ("queen", LAVENDER),
        ("worker", POP_GREEN),
        ("validator", ORANGE),
        ("reviewer", INDIGO),
        ("scout", TEAL),
        ("daemon", AMBER),
        ("reject", CORAL),
        ("merge", SHINY_GOLD),
    ];
    let mut spans: Vec<Span<'a>> = Vec::new();
    for (label, color) in pairs {
        spans.push(Span::styled("⬢ ", Style::default().fg(*color)));
        spans.push(Span::styled(*label, Style::default().fg(MUTED)));
        spans.push(Span::raw(" "));
    }
    Text::from(Line::from(spans))
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn actor_color_maps_all_apiary_roles() {
        assert_eq!(actor_color(Some("queen")), LAVENDER);
        assert_eq!(actor_color(Some("conductor")), LAVENDER); // legacy alias
        assert_eq!(actor_color(Some("daemon")), AMBER);
        assert_eq!(actor_color(Some("worker")), POP_GREEN);
        assert_eq!(actor_color(Some("validator")), ORANGE);
        assert_eq!(actor_color(Some("reviewer")), INDIGO);
        assert_eq!(actor_color(Some("scout")), TEAL);
        assert_eq!(actor_color(Some("builder")), GOLD);
        assert_eq!(actor_color(Some("coder")), GOLD);
        assert_eq!(actor_color(Some("researcher")), GOLD);
        assert_eq!(actor_color(None), MUTED);
        assert_eq!(actor_color(Some("unknown_actor")), MUTED);
    }

    #[test]
    fn load_buzz_state_returns_empty_when_no_log() {
        let original = std::env::current_dir().unwrap();
        let tmp = std::env::temp_dir();
        std::env::set_current_dir(&tmp).unwrap();

        let state = load_buzz_state(Duration::from_secs(3600), 0);
        assert!(state.events.is_empty());

        std::env::set_current_dir(&original).unwrap();
    }

    #[test]
    fn render_buzz_empty_state_returns_no_buzz_yet() {
        let state = BuzzState {
            events: vec![],
        };
        let area = Rect::new(0, 0, 40, 10);
        let text = render_buzz(&state, area, 0);
        let rendered: String = text.lines.iter()
            .flat_map(|l| l.spans.iter().map(|s| s.content.as_ref()))
            .collect();
        assert!(rendered.contains("no buzz yet"));
    }

    #[test]
    fn render_buzz_lays_out_hexes_newest_first() {
        // Three events: oldest actor=daemon, middle actor=worker, newest actor=queen.
        // Expected order in the rendered grid: queen (newest) leftmost.
        let base_ts: DateTime<Utc> = "2026-04-30T12:00:00Z".parse().unwrap();
        let state = BuzzState {
            events: vec![
                BuzzEvent {
                    ts: Some(base_ts),
                    actor: Some("daemon".to_string()),
                    action: None,
                    brief: None,
                    cost_usd: 0.10,
                    intensity_bucket: 2,
                    duration_ms: None,
                },
                BuzzEvent {
                    ts: Some(base_ts + chrono::Duration::minutes(1)),
                    actor: Some("worker".to_string()),
                    action: None,
                    brief: None,
                    cost_usd: 0.10,
                    intensity_bucket: 2,
                    duration_ms: None,
                },
                BuzzEvent {
                    ts: Some(base_ts + chrono::Duration::minutes(2)),
                    actor: Some("queen".to_string()),
                    action: None,
                    brief: None,
                    cost_usd: 0.10,
                    intensity_bucket: 2,
                    duration_ms: None,
                },
            ],
        };

        let area = Rect::new(0, 0, 40, 10);
        let text = render_buzz(&state, area, 0);
        assert!(!text.lines.is_empty(), "should produce at least one row");

        // First span in first row (after optional offset space) should be queen color
        // at bucket 2 (base intensity → apply_intensity returns same RGB)
        let first_line = &text.lines[0];
        let first_hex = first_line.spans.iter().find(|s| s.content.contains('⬢')).unwrap();
        let Color::Rgb(r, g, b) = first_hex.style.fg.unwrap() else {
            panic!("expected Rgb color");
        };
        // LAVENDER = 0x00B894E6 → Rgb(184, 148, 230). Bucket 2 → unchanged.
        assert_eq!((r, g, b), (0xB8, 0x94, 0xE6), "newest event (queen) should be leftmost hex (LAVENDER at base intensity)");
    }

    #[test]
    fn load_buzz_state_events_sorted_chronologically() {
        // Events from a parsed log must be oldest-first in state.events
        // (renderer reverses them for newest-first display).
        let t1: DateTime<Utc> = "2026-04-30T10:00:00Z".parse().unwrap();
        let t2: DateTime<Utc> = "2026-04-30T11:00:00Z".parse().unwrap();

        let mut events = [
            BuzzEvent { ts: Some(t2), actor: None, action: None, brief: None, cost_usd: 0.10, intensity_bucket: 2, duration_ms: None },
            BuzzEvent { ts: Some(t1), actor: None, action: None, brief: None, cost_usd: 0.10, intensity_bucket: 2, duration_ms: None },
        ];
        events.sort_by(|a, b| match (a.ts, b.ts) {
            (Some(at), Some(bt)) => at.cmp(&bt),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => std::cmp::Ordering::Equal,
        });

        assert_eq!(events[0].ts, Some(t1));
        assert_eq!(events[1].ts, Some(t2));
    }

    // ── Cycle 2 tests ─────────────────────────────────────────────────────────

    #[test]
    fn cost_to_bucket_boundaries() {
        assert_eq!(cost_to_bucket(0.0), 0, "$0.00 → bucket 0");
        assert_eq!(cost_to_bucket(0.004), 0, "$0.004 → bucket 0");
        assert_eq!(cost_to_bucket(0.005), 1, "$0.005 → bucket 1");
        assert_eq!(cost_to_bucket(0.049), 1, "$0.049 → bucket 1");
        assert_eq!(cost_to_bucket(0.05), 2, "$0.05 → bucket 2");
        assert_eq!(cost_to_bucket(0.10), 2, "$0.10 → bucket 2");
        assert_eq!(cost_to_bucket(0.299), 2, "$0.299 → bucket 2");
        assert_eq!(cost_to_bucket(0.30), 3, "$0.30 → bucket 3");
        assert_eq!(cost_to_bucket(0.999), 3, "$0.999 → bucket 3");
        assert_eq!(cost_to_bucket(1.00), 4, "$1.00 → bucket 4");
        assert_eq!(cost_to_bucket(5.00), 4, "$5.00 → bucket 4");
    }

    #[test]
    fn event_override_reject_actions_return_coral() {
        assert_eq!(event_color_override(Some("error")), Some(CORAL));
        assert_eq!(event_color_override(Some("escalate")), Some(CORAL));
        assert_eq!(event_color_override(Some("fail")), Some(CORAL));
        assert_eq!(event_color_override(Some("reject")), Some(CORAL));
        assert_eq!(event_color_override(Some("task_fail")), Some(CORAL));
        assert_eq!(event_color_override(Some("escalate_blocked")), Some(CORAL));
    }

    #[test]
    fn event_override_merge_actions_return_shiny_gold() {
        assert_eq!(event_color_override(Some("merge")), Some(SHINY_GOLD));
        assert_eq!(event_color_override(Some("approve")), Some(SHINY_GOLD));
        assert_eq!(event_color_override(Some("daemon:merge")), Some(SHINY_GOLD));
        assert_eq!(event_color_override(Some("stamp_merge")), Some(SHINY_GOLD));
    }

    #[test]
    fn event_override_none_for_normal_actions() {
        assert_eq!(event_color_override(None), None);
        assert_eq!(event_color_override(Some("dispatch")), None);
        assert_eq!(event_color_override(Some("heartbeat")), None);
        assert_eq!(event_color_override(Some("evaluate")), None);
    }

    #[test]
    fn event_override_takes_priority_over_actor_color_in_render() {
        // A queen actor with an "escalate" action should render CORAL, not LAVENDER.
        let base_ts: DateTime<Utc> = "2026-04-30T12:00:00Z".parse().unwrap();
        let state = BuzzState {
            events: vec![BuzzEvent {
                ts: Some(base_ts),
                actor: Some("queen".to_string()),
                action: Some("escalate".to_string()),
                brief: None,
                cost_usd: 0.10,
                intensity_bucket: 2,
                duration_ms: None,
            }],
        };
        let area = Rect::new(0, 0, 40, 10);
        let text = render_buzz(&state, area, 0);
        let first_line = &text.lines[0];
        let hex_span = first_line.spans.iter().find(|s| s.content.contains('⬢')).unwrap();
        // CORAL = Rgb(255, 107, 107) at bucket 2 (no intensity change)
        assert_eq!(
            hex_span.style.fg,
            Some(Color::Rgb(0xFF, 0x6B, 0x6B)),
            "escalate action on queen should render CORAL not LAVENDER"
        );
    }

    #[test]
    fn apply_intensity_dims_bucket_0_and_brightens_bucket_4() {
        // Base color LAVENDER = Rgb(184, 148, 230)
        let (dim, bold0) = apply_intensity(LAVENDER, 0);
        assert!(!bold0);
        let Color::Rgb(r, g, b) = dim else { panic!() };
        assert!(r < 184 && g < 148 && b < 230, "bucket 0 should dim the color");

        let (bright, bold4) = apply_intensity(LAVENDER, 4);
        assert!(bold4, "bucket 4 should signal bold");
        let Color::Rgb(br, bg, bb) = bright else { panic!() };
        assert!(br > 184 && bg > 148 && bb > 230, "bucket 4 should brighten the color");
    }

    #[test]
    fn render_buzz_cursor_highlights_selected_hex() {
        let base_ts: DateTime<Utc> = "2026-04-30T12:00:00Z".parse().unwrap();
        let state = BuzzState {
            events: vec![
                BuzzEvent {
                    ts: Some(base_ts),
                    actor: Some("daemon".to_string()),
                    action: None,
                    brief: None,
                    cost_usd: 0.10,
                    intensity_bucket: 2,
                    duration_ms: None,
                },
                BuzzEvent {
                    ts: Some(base_ts + chrono::Duration::minutes(1)),
                    actor: Some("worker".to_string()),
                    action: None,
                    brief: None,
                    cost_usd: 0.10,
                    intensity_bucket: 2,
                    duration_ms: None,
                },
            ],
        };
        let area = Rect::new(0, 0, 40, 10);
        // cursor=0 highlights newest (worker). Check UNDERLINED modifier present.
        let text = render_buzz(&state, area, 0);
        let first_hex = text.lines[0]
            .spans
            .iter()
            .find(|s| s.content.contains('⬢'))
            .unwrap();
        assert!(
            first_hex.style.add_modifier.contains(Modifier::UNDERLINED),
            "cursor=0 should have UNDERLINED on the first (newest) hex"
        );
    }

    #[test]
    fn render_buzz_detail_shows_actor_and_action() {
        let base_ts: DateTime<Utc> = "2026-04-30T12:34:56Z".parse().unwrap();
        let state = BuzzState {
            events: vec![BuzzEvent {
                ts: Some(base_ts),
                actor: Some("queen".to_string()),
                action: Some("dispatch".to_string()),
                brief: Some("brief-042".to_string()),
                cost_usd: 0.25,
                intensity_bucket: 2,
                duration_ms: Some(3500),
            }],
        };
        let text = render_buzz_detail(&state, 0);
        let rendered: String = text
            .lines
            .iter()
            .flat_map(|l| l.spans.iter().map(|s| s.content.as_ref()))
            .collect();
        assert!(rendered.contains("queen"), "should show actor");
        assert!(rendered.contains("dispatch"), "should show action");
        assert!(rendered.contains("brief-042"), "should show brief");
        assert!(rendered.contains("$0.2500"), "should show cost");
        assert!(rendered.contains("3.5s"), "should show wall time in seconds");
    }

    #[test]
    fn render_buzz_legend_contains_all_apiary_roles() {
        let text = render_buzz_legend();
        let rendered: String = text
            .lines
            .iter()
            .flat_map(|l| l.spans.iter().map(|s| s.content.as_ref()))
            .collect();
        for role in &["queen", "worker", "validator", "reviewer", "scout", "daemon", "reject", "merge"] {
            assert!(rendered.contains(role), "legend should contain {}", role);
        }
    }

    #[test]
    fn load_buzz_state_offset_shifts_window_end() {
        // Call with a huge offset (1 year back) — whatever is in the local state
        // will be far outside the window, so events.len() should be 0.
        // Also tests that the function doesn't panic with large offset values.
        let original = std::env::current_dir().unwrap();
        let tmp = std::env::temp_dir();
        std::env::set_current_dir(&tmp).unwrap();

        let state = load_buzz_state(Duration::from_secs(3600), 365 * 24 * 3600);
        // No log.jsonl in temp dir, so always empty regardless of window.
        assert!(state.events.is_empty());

        std::env::set_current_dir(&original).unwrap();
    }
}
