//! LLM session titles: one cheap request after the session's first prompt,
//! named after what it is about rather than its first line.

use maki_providers::provider::Provider;
use maki_providers::{AgentError, ContentBlock, Message, Model, RequestOptions, Role};
use maki_storage::id::SessionRef;
use maki_storage::sessions::normalize_title;

const TITLE_SYSTEM: &str = "You name coding sessions for a picker. Reply with the title only: 2 to 6 words, no quotes, no trailing punctuation, in the language of the request.";
const TITLE_MAX_LEN: usize = 60;
const TITLE_PROMPT_PREFIX: &str = "Name this session:";

/// The text the session is about, as far as a title cares: the first user
/// words, trimmed of what would leak a whole code block into a picker line.
pub fn first_user_text(messages: &[Message]) -> Option<String> {
    messages
        .iter()
        .filter(|m| matches!(m.role, Role::User))
        .flat_map(|m| m.content.iter())
        .find_map(|block| match block {
            ContentBlock::Text { text } => {
                let normalized = normalize_title(text);
                (!normalized.is_empty()).then_some(normalized)
            }
            _ => None,
        })
}

/// Strips the wrapping models love to add and caps the length the picker
/// assumes. `None` when nothing usable is left.
pub(crate) fn clean(raw: &str) -> Option<String> {
    let trimmed = raw
        .trim()
        .trim_matches(|c| matches!(c, '"' | '\'' | '`' | '*'));
    let normalized = normalize_title(trimmed);
    (!normalized.is_empty()).then(|| {
        if normalized.len() <= TITLE_MAX_LEN {
            normalized
        } else {
            format!(
                "{}…",
                &normalized[..normalized.floor_char_boundary(TITLE_MAX_LEN)]
            )
        }
    })
}

/// One small request, no tools, no retry: a title is a nicety, and the session
/// keeps its heuristic title when this fails. `Ok(None)` means the answer was
/// unusable.
pub async fn generate(
    provider: &dyn Provider,
    model: &Model,
    prompt: &str,
    session_id: Option<&SessionRef>,
) -> Result<Option<String>, AgentError> {
    let (tx, _rx) = flume::unbounded();
    let response = provider
        .stream_message(
            model,
            &[Message::user(format!("{TITLE_PROMPT_PREFIX} {prompt}"))],
            TITLE_SYSTEM,
            &serde_json::json!([]),
            &tx,
            RequestOptions::default(),
            session_id,
        )
        .await?;
    Ok(response.message.first_text_content().and_then(clean))
}

#[cfg(test)]
mod tests {
    use super::*;
    use test_case::test_case;

    #[test_case("Fix the login bug", Some("Fix the login bug") ; "plain title")]
    #[test_case("  \"Fix the login bug\"  ", Some("Fix the login bug") ; "quoted and padded")]
    #[test_case("**Refactor parser**", Some("Refactor parser") ; "markdown emphasis")]
    #[test_case("   ", None ; "whitespace only")]
    fn cleans_raw_titles(raw: &str, expected: Option<&str>) {
        assert_eq!(clean(raw), expected.map(str::to_owned));
    }

    #[test]
    fn long_titles_are_cut_on_a_char_boundary() {
        let raw = "a".repeat(100);
        let title = clean(&raw).unwrap();
        assert_eq!(title.len(), TITLE_MAX_LEN + "…".len());
        assert!(title.ends_with('…'));
        assert!(title.is_char_boundary(title.len() - "…".len()));
    }

    #[test]
    fn first_user_text_skips_empty_leading_messages() {
        let messages = vec![
            Message::user("   ".to_owned()),
            Message {
                role: Role::Assistant,
                content: vec![],
                ..Message::default()
            },
            Message::user("fix\nthe\nparser".to_owned()),
        ];
        assert_eq!(
            first_user_text(&messages).as_deref(),
            Some("fix the parser")
        );
    }

    #[test]
    fn first_user_text_ignores_non_text_blocks() {
        let mut message = Message::user(String::new());
        message.content = vec![ContentBlock::Thinking {
            thinking: "internal".to_owned(),
            signature: None,
        }];
        assert_eq!(first_user_text(&[message]), None);
    }
}
