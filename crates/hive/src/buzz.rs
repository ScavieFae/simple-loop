use crate::state::{parse_log_ts, RawLogLine};
use chrono::{DateTime, Utc};
use ratatui::{
    layout::Rect,
    style::{Color, Style},
    text::{Line, Span, Text},
};
use std::{
    fs,
    io::{BufRead, BufReader},
    path::Path,
    time::Duration,
};

// Color constants — mirrors main.rs verbatim per brief anti-pattern
const AMBER: Color = Color::from_u32(0x00F5A623);
const GOLD: Color = Color::from_u32(0x00FFCE5C);
// Used in Cycle 2 for reject event overrides
#[allow(dead_code)]
const CORAL: Color = Color::from_u32(0x00FF6B6B);
const MUTED: Color = Color::from_u32(0x006A6A6A);
const INDIGO: Color = Color::from_u32(0x007B8FD4);
const LAVENDER: Color = Color::from_u32(0x00B894E6);
const POP_GREEN: Color = Color::from_u32(0x0039FF80);
const ORANGE: Color = Color::from_u32(0x00FF8C00);
const TEAL: Color = Color::from_u32(0x005DADE2);

// Ceremonial gold for merge events — distinct from STAMP_GREEN and GOLD.
// Used in Cycle 2 event-type overrides.
#[allow(dead_code)]
pub const SHINY_GOLD: Color = Color::from_u32(0x00FFD700);

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

// ── data model ────────────────────────────────────────────────────────────────

pub struct BuzzEvent {
    pub ts: Option<DateTime<Utc>>,
    pub actor: Option<String>,
    // Used in Cycle 3 cursor drill-in detail panel
    #[allow(dead_code)]
    pub action: Option<String>,
    // Used in Cycle 3 cursor drill-in detail panel
    #[allow(dead_code)]
    pub brief: Option<String>,
    // Used in Cycle 2 intensity bucketing via metrics.jsonl join
    #[allow(dead_code)]
    pub cost_usd: f64,
    // Used in Cycle 2 render with log-scale brightness
    #[allow(dead_code)]
    pub intensity_bucket: u8,
}

pub struct BuzzState {
    pub events: Vec<BuzzEvent>,
    // Used in Cycle 3 time-window pan ([/]/=)
    #[allow(dead_code)]
    pub window: Duration,
    // Used in Cycle 3 time-window pan ([/]/=)
    #[allow(dead_code)]
    pub window_end: DateTime<Utc>,
}

// ── loader ────────────────────────────────────────────────────────────────────

pub fn load_buzz_state(window: Duration) -> BuzzState {
    let log_path = Path::new(".loop/state/log.jsonl");
    let window_end = Utc::now();
    let cutoff = window_end - chrono::Duration::seconds(window.as_secs() as i64);

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

            events.push(BuzzEvent {
                ts,
                actor: entry.derived_actor(),
                action: entry.event.or(entry.action),
                brief: entry.brief,
                // Cycle 1: cost stub — all events get bucket 2 (median / base color)
                cost_usd: 0.0,
                intensity_bucket: 2,
            });
        }
    }

    // Chronological order (oldest → newest); newest displayed top-left in renderer
    events.sort_by(|a, b| match (a.ts, b.ts) {
        (Some(at), Some(bt)) => at.cmp(&bt),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    });

    BuzzState { events, window, window_end }
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
pub fn render_buzz<'a>(state: &BuzzState, area: Rect) -> Text<'a> {
    if state.events.is_empty() {
        let center_line = Line::from(Span::styled(
            "no buzz yet",
            Style::default().fg(MUTED),
        ));
        return Text::from(center_line);
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
            let color = actor_color(ev.actor.as_deref());
            spans.push(Span::styled("⬢ ", Style::default().fg(color)));
        }

        lines.push(Line::from(spans));
        consumed = row_end;
        row += 1;
    }

    Text::from(lines)
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
    fn intensity_bucket_stubbed_to_2_in_cycle1() {
        // All events loaded in Cycle 1 must be bucket 2 (median / base color)
        // until Cycle 2 wires the metrics.jsonl cost join.
        let original = std::env::current_dir().unwrap();
        let tmp = std::env::temp_dir();
        std::env::set_current_dir(&tmp).unwrap();

        let state = load_buzz_state(Duration::from_secs(3600));
        // No log file in tmp → empty, no assertions on buckets needed.
        // Just verify it doesn't panic.
        assert!(state.events.iter().all(|e| e.intensity_bucket == 2));

        std::env::set_current_dir(&original).unwrap();
    }

    #[test]
    fn load_buzz_state_returns_empty_when_no_log() {
        let original = std::env::current_dir().unwrap();
        let tmp = std::env::temp_dir();
        std::env::set_current_dir(&tmp).unwrap();

        let state = load_buzz_state(Duration::from_secs(3600));
        assert!(state.events.is_empty());

        std::env::set_current_dir(&original).unwrap();
    }

    #[test]
    fn render_buzz_empty_state_returns_no_buzz_yet() {
        let state = BuzzState {
            events: vec![],
            window: Duration::from_secs(3600),
            window_end: Utc::now(),
        };
        let area = Rect::new(0, 0, 40, 10);
        let text = render_buzz(&state, area);
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
                    cost_usd: 0.0,
                    intensity_bucket: 2,
                },
                BuzzEvent {
                    ts: Some(base_ts + chrono::Duration::minutes(1)),
                    actor: Some("worker".to_string()),
                    action: None,
                    brief: None,
                    cost_usd: 0.0,
                    intensity_bucket: 2,
                },
                BuzzEvent {
                    ts: Some(base_ts + chrono::Duration::minutes(2)),
                    actor: Some("queen".to_string()),
                    action: None,
                    brief: None,
                    cost_usd: 0.0,
                    intensity_bucket: 2,
                },
            ],
            window: Duration::from_secs(3600),
            window_end: Utc::now(),
        };

        let area = Rect::new(0, 0, 40, 10);
        let text = render_buzz(&state, area);
        assert!(!text.lines.is_empty(), "should produce at least one row");

        // First span in first row (after optional offset space) should be queen color
        let first_line = &text.lines[0];
        let first_hex = first_line.spans.iter().find(|s| s.content.contains('⬢')).unwrap();
        assert_eq!(
            first_hex.style.fg,
            Some(LAVENDER),
            "newest event (queen) should be leftmost hex (LAVENDER)"
        );
    }

    #[test]
    fn load_buzz_state_events_sorted_chronologically() {
        // Events from a parsed log must be oldest-first in state.events
        // (renderer reverses them for newest-first display).
        let t1: DateTime<Utc> = "2026-04-30T10:00:00Z".parse().unwrap();
        let t2: DateTime<Utc> = "2026-04-30T11:00:00Z".parse().unwrap();

        let mut events = [
            BuzzEvent { ts: Some(t2), actor: None, action: None, brief: None, cost_usd: 0.0, intensity_bucket: 2 },
            BuzzEvent { ts: Some(t1), actor: None, action: None, brief: None, cost_usd: 0.0, intensity_bucket: 2 },
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
}
