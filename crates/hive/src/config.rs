use serde_json::Value;
use std::{fs, path::Path};

/// RGB palette colors read from `.loop/config.json` → `beehive.palette`.
/// Each field stores a 24-bit RGB value (same encoding as ratatui's
/// `Color::from_u32` — high byte is ignored, so `0xRRGGBB` works).
#[derive(Debug, Clone)]
pub struct Palette {
    /// Primary focus color — panel borders + header when focused. Default: amber.
    pub primary: u32,
    /// Bright accent — ids, names, highlighted values. Default: gold.
    pub accent: u32,
    /// Muted labels and dimmed text. Default: dark gray.
    pub muted: u32,
    /// Success / approve color. Default: stamp green.
    pub stamp_green: u32,
    /// Errors and alerts. Default: coral red.
    pub coral: u32,
    /// Conductor / dispatch events. Default: lavender.
    pub lavender: u32,
    /// Pending-dispatch signals. Default: blue.
    pub blue: u32,
}

impl Default for Palette {
    fn default() -> Self {
        Palette {
            primary: 0xF5A623,    // AMBER
            accent: 0xFFCE5C,     // GOLD
            muted: 0x6A6A6A,      // MUTED
            stamp_green: 0x5EC488,
            coral: 0xFF6B6B,
            lavender: 0xB894E6,
            blue: 0x5B9BD5,
        }
    }
}

/// Layout knobs controllable via config.
#[derive(Debug, Clone)]
pub struct Layout {
    /// Max number of active-brief entries displayed in the Cells panel
    /// before the section is truncated with a "+ N more" footer.
    pub active_section_height: u16,
}

impl Default for Layout {
    fn default() -> Self {
        Layout { active_section_height: 10 }
    }
}

/// Full hive config loaded from `.loop/config.json` → `beehive` section.
/// Missing fields fall through to defaults. Invalid JSON degrades to full
/// defaults with a stderr warning — crash-on-config is the anti-pattern.
#[derive(Debug, Clone, Default)]
pub struct HiveConfig {
    pub palette: Palette,
    pub layout: Layout,
}

impl HiveConfig {
    pub fn load() -> Self {
        let path = Path::new(".loop/config.json");
        if !path.exists() {
            return Self::default();
        }
        let content = match fs::read_to_string(path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("hive: warning: could not read .loop/config.json ({e}); using defaults");
                return Self::default();
            }
        };
        let json: Value = match serde_json::from_str(&content) {
            Ok(v) => v,
            Err(e) => {
                eprintln!(
                    "hive: warning: .loop/config.json is not valid JSON ({e}); using defaults"
                );
                return Self::default();
            }
        };

        let mut cfg = Self::default();
        let Some(beehive) = json.get("beehive") else {
            return cfg;
        };

        if let Some(palette) = beehive.get("palette") {
            macro_rules! apply {
                ($field:ident, $key:literal) => {
                    if let Some(v) = hex_color(palette, $key) {
                        cfg.palette.$field = v;
                    }
                };
            }
            apply!(primary, "primary");
            apply!(accent, "accent");
            apply!(muted, "muted");
            apply!(stamp_green, "stamp_green");
            apply!(coral, "coral");
            apply!(lavender, "lavender");
            apply!(blue, "blue");
        }

        if let Some(layout) = beehive.get("layout") {
            if let Some(h) = layout
                .get("active_section_height")
                .and_then(Value::as_u64)
            {
                cfg.layout.active_section_height = h.min(255) as u16;
            }
        }

        cfg
    }
}

fn hex_color(obj: &Value, key: &str) -> Option<u32> {
    let s = obj.get(key)?.as_str()?;
    u32::from_str_radix(s.trim_start_matches('#'), 16).ok()
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_palette_has_expected_primary() {
        let cfg = HiveConfig::default();
        assert_eq!(cfg.palette.primary, 0xF5A623);
    }

    #[test]
    fn hex_color_parses_with_and_without_hash() {
        let json = serde_json::json!({ "primary": "#FF00FF" });
        assert_eq!(hex_color(&json, "primary"), Some(0xFF00FF));
        let json2 = serde_json::json!({ "primary": "FF00FF" });
        assert_eq!(hex_color(&json2, "primary"), Some(0xFF00FF));
    }

    #[test]
    fn hex_color_returns_none_for_invalid() {
        let json = serde_json::json!({ "primary": "not-a-color" });
        assert_eq!(hex_color(&json, "primary"), None);
    }

    #[test]
    fn parse_beehive_palette_overrides_primary() {
        // Use escaped string to avoid r#"..."# terminating on "#ABCDEF"
        let content = "{\"beehive\":{\"palette\":{\"primary\":\"#ABCDEF\"}}}";
        let json: Value = serde_json::from_str(content).unwrap();
        let mut cfg = HiveConfig::default();
        if let Some(palette) = json["beehive"].get("palette") {
            if let Some(v) = hex_color(palette, "primary") {
                cfg.palette.primary = v;
            }
        }
        assert_eq!(cfg.palette.primary, 0xABCDEF);
        // Other fields unchanged
        assert_eq!(cfg.palette.accent, 0xFFCE5C);
    }

    #[test]
    fn parse_active_section_height() {
        let content = r#"{"beehive":{"layout":{"active_section_height":5}}}"#;
        let json: Value = serde_json::from_str(content).unwrap();
        let mut cfg = HiveConfig::default();
        if let Some(layout) = json["beehive"].get("layout") {
            if let Some(h) = layout.get("active_section_height").and_then(Value::as_u64) {
                cfg.layout.active_section_height = h.min(255) as u16;
            }
        }
        assert_eq!(cfg.layout.active_section_height, 5);
    }
}
