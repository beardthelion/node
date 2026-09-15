//! Display helpers for strings that come off the wire unchecked.

/// Truncate `s` to at most `max` chars, cutting at a char boundary.
///
/// `&s[..max]` panics when `s` is shorter than `max` bytes and when `max`
/// lands inside a multi-byte char; `s.len().min(max)` guards only the first
/// case. Node-supplied timestamps and ids hit both.
pub(crate) fn truncate(s: &str, max: usize) -> &str {
    match s.char_indices().nth(max) {
        Some((i, _)) => &s[..i],
        None => s,
    }
}

#[cfg(test)]
mod tests {
    use super::truncate;

    #[test]
    fn cuts_ascii_at_max() {
        assert_eq!(truncate("2026-08-15T12:34:56Z", 10), "2026-08-15");
    }

    #[test]
    fn short_and_empty_inputs_return_whole() {
        assert_eq!(truncate("2026", 10), "2026");
        assert_eq!(truncate("", 10), "");
    }

    #[test]
    fn multibyte_cut_does_not_panic() {
        // Byte index 10 lands inside 'é'; the cut must land on the boundary
        // after it (10 chars) rather than panic.
        assert_eq!(
            truncate("2026-08-1\u{e9}5T12:34:56Z", 10),
            "2026-08-1\u{e9}"
        );
        // A string that is entirely multi-byte and shorter than max.
        assert_eq!(truncate("\u{e9}\u{e9}", 10), "\u{e9}\u{e9}");
    }
}
