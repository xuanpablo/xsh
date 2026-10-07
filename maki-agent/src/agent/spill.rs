use std::{env, fs, path::Path, sync::Arc};

use tracing::{debug, warn};

use crate::types::ToolDoneEvent;

const SPILL_DIR: &str = ".maki/spill";
/// How much of a spilled output stays in the transcript as a taste of what
/// the full text holds.
pub(crate) const SPILL_RETAINED_BYTES: usize = 2048;
const ID_MAX_CHARS: usize = 64;
const ID_FALLBACK: &str = "unnamed";

fn spill_id(id: &str) -> String {
    let cleaned: String = id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
        .take(ID_MAX_CHARS)
        .collect();
    if cleaned.is_empty() {
        ID_FALLBACK.into()
    } else {
        cleaned
    }
}

/// A tool result over `spill_bytes` never enters the transcript whole: the
/// full text is written to `<root>/.maki/spill/<id>` and the model keeps the
/// first [`SPILL_RETAINED_BYTES`] bytes plus a locator it can page back with
/// the `spill` tool. A write failure leaves the original output alone.
pub(super) fn apply(done: &mut ToolDoneEvent, spill_bytes: usize) {
    let Ok(root) = env::current_dir() else {
        return;
    };
    apply_at(done, spill_bytes, &root);
}

fn apply_at(done: &mut ToolDoneEvent, spill_bytes: usize, root: &Path) {
    if spill_bytes == 0 || done.is_error {
        return;
    }
    let Some(text) = Arc::make_mut(&mut done.output).filterable_text_mut() else {
        return;
    };
    let total = text.len();
    if total <= spill_bytes {
        return;
    }
    let id = spill_id(&done.id);
    let path = root.join(SPILL_DIR).join(&id);
    if let Err(e) =
        fs::create_dir_all(root.join(SPILL_DIR)).and_then(|()| fs::write(&path, text.as_bytes()))
    {
        warn!(error = %e, tool = %done.tool, "spill write failed, keeping the full output");
        return;
    }
    let boundary = text.floor_char_boundary(SPILL_RETAINED_BYTES);
    let locator = format!(
        "\n\n[full output at {SPILL_DIR}/{id} ({total} bytes), first {SPILL_RETAINED_BYTES} bytes retained; page it back with the spill tool]"
    );
    text.truncate(boundary);
    text.push_str(&locator);
    debug!(
        tool = %done.tool,
        bytes = total,
        spill = %path.display(),
        "spilled tool output"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::ToolOutput;
    use tempfile::TempDir;

    const THRESHOLD: usize = 64;
    const BIG: &str =
        "a big tool output that is well and truly over the threshold for sure, no doubt";

    fn done(text: &str) -> ToolDoneEvent {
        ToolDoneEvent {
            call: None,
            id: "toolu_01ABC".into(),
            tool: Arc::from("bash"),
            output: Arc::new(ToolOutput::Plain(text.into())),
            is_error: false,
            annotation: None,
            written_path: None,
        }
    }

    #[test]
    fn big_output_spilled_with_locator() {
        let dir = TempDir::new().unwrap();
        let mut event = done(BIG);
        apply_at(&mut event, THRESHOLD, dir.path());
        let text = event.output.as_text();
        assert!(text.starts_with("a big tool outpu"));
        assert!(text.contains(".maki/spill/toolu01ABC"));
        assert!(
            fs::read(dir.path().join(".maki/spill/toolu01ABC")).is_ok_and(|f| f == BIG.as_bytes())
        );
    }

    #[test]
    fn small_output_and_disabled_spill_pass_through() {
        let dir = TempDir::new().unwrap();
        let mut small = done("tiny");
        apply_at(&mut small, THRESHOLD, dir.path());
        assert_eq!(small.output.as_text(), "tiny");

        let mut disabled = done(BIG);
        apply_at(&mut disabled, 0, dir.path());
        assert_eq!(disabled.output.as_text(), BIG);
    }

    #[test]
    fn error_outputs_are_never_spilled() {
        let dir = TempDir::new().unwrap();
        let mut mut_event = done(BIG);
        mut_event.is_error = true;
        apply_at(&mut mut_event, THRESHOLD, dir.path());
        assert_eq!(mut_event.output.as_text(), BIG);
    }

    #[test]
    fn unwritable_root_keeps_the_full_output() {
        let dir = TempDir::new().unwrap();
        let mut event = done(BIG);
        let blocked = dir.path().join("file");
        fs::write(&blocked, "in the way").unwrap();
        apply_at(&mut event, THRESHOLD, &blocked);
        assert_eq!(event.output.as_text(), BIG);
    }
}
