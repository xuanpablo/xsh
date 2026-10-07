//! Redaction applied to exported event payloads. Runs before anything leaves
//! the process: home-relative paths become `~`, and environment-style
//! `KEY=value` assignments lose their value.

const REDACTED: &str = "[REDACTED]";
const HOME_PLACEHOLDER: &str = "~";
const MIN_ENV_KEY_LEN: usize = 2;

fn is_env_key_char(c: char) -> bool {
    c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_'
}

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// True when `c` can end an environment value: assignment values run to the
/// next whitespace or shell separator.
fn is_value_end(c: char) -> bool {
    c.is_whitespace() || c == '\'' || c == '"' || c == ';'
}

pub fn redact_with_home(input: &str, home: Option<&str>) -> String {
    let scrubbed_paths = match home.filter(|home| !home.is_empty()) {
        Some(home) => input.replace(home, HOME_PLACEHOLDER),
        None => input.to_string(),
    };
    redact_env_values(&scrubbed_paths)
}

fn redact_env_values(input: &str) -> String {
    let chars: Vec<char> = input.chars().collect();
    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    while i < chars.len() {
        let start = i;
        while i < chars.len() && is_env_key_char(chars[i]) {
            i += 1;
        }
        let key_len = i - start;
        let followed_by_eq = i < chars.len() && chars[i] == '=';
        if key_len >= MIN_ENV_KEY_LEN
            && followed_by_eq
            && (start == 0 || !is_word_char(chars[start - 1]))
        {
            out.extend(&chars[start..=i]);
            out.push_str(REDACTED);
            i += 1;
            if i < chars.len() && (chars[i] == '\'' || chars[i] == '"') {
                let quote = chars[i];
                i += 1;
                while i < chars.len() && chars[i] != quote {
                    i += 1;
                }
                i += 1;
            } else {
                while i < chars.len() && !is_value_end(chars[i]) {
                    i += 1;
                }
            }
        } else {
            if key_len == 0 {
                out.push(chars[i]);
                i += 1;
            } else {
                out.extend(&chars[start..i]);
            }
        }
    }
    out
}

/// [`redact_with_home`] with the current user's home directory.
pub fn redact(input: &str) -> String {
    redact_with_home(input, std::env::var("HOME").ok().as_deref())
}

#[cfg(test)]
mod tests {
    use test_case::test_case;

    use super::redact_with_home;

    const HOME: &str = "/Users/tester";
    const PATH_LINE: &str = "reading /Users/tester/project/src/main.rs";
    const PATH_LINE_REDACTED: &str = "reading ~/project/src/main.rs";
    const ENV_LINE: &str = "env: AWS_SECRET_ACCESS_KEY=abc123 TERM=xterm-256color";
    const ENV_LINE_REDACTED: &str = "env: AWS_SECRET_ACCESS_KEY=[REDACTED] TERM=[REDACTED]";

    #[test_case("plain text", None, "plain text")]
    #[test_case(PATH_LINE, Some(HOME), PATH_LINE_REDACTED)]
    #[test_case(ENV_LINE, None, ENV_LINE_REDACTED)]
    #[test_case("API_KEY=", None, "API_KEY=[REDACTED]")]
    #[test_case("lowercase key=value stays", None, "lowercase key=value stays")]
    #[test_case("X=1", None, "X=1")]
    #[test_case(
        "export TOKEN='secret value' done",
        None,
        "export TOKEN=[REDACTED] done"
    )]
    fn redaction(input: &str, home: Option<&str>, expected: &str) {
        assert_eq!(redact_with_home(input, home), expected);
    }
}
