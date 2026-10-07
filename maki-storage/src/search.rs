//! SQLite FTS5 index over session transcripts.
//!
//! The sessions directory is the source of truth; the index is a cache keyed
//! by each JSONL file's `(size, mtime)` signature, so a refresh only re-reads
//! sessions that changed since the last one.

use std::fs;
use std::path::Path;

use rusqlite::Connection;

use crate::sessions::{SESSIONS_DIR, file_signature, session_entries};
use crate::{StateDir, StorageError};

pub const SEARCH_INDEX_FILE: &str = "sessions-search.db";
const MSG_TAGS: [&str; 2] = ["msg", "sub_msg"];
const SNIPPET_WORDS: i32 = 12;
pub const DEFAULT_SEARCH_LIMIT: usize = 20;

#[derive(Debug, thiserror::Error)]
pub enum SearchError {
    #[error("session index: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("session index: {0}")]
    Io(#[from] std::io::Error),
    #[error("session index: {0}")]
    Storage(#[from] StorageError),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchHit {
    pub session_id: String,
    pub role: String,
    pub snippet: String,
}

pub struct SessionIndex {
    conn: Connection,
}

impl SessionIndex {
    pub fn open(path: &Path) -> Result<Self, SearchError> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "CREATE VIRTUAL TABLE IF NOT EXISTS transcript USING fts5(\
                 session_id UNINDEXED, role UNINDEXED, content, tokenize='unicode61');\
             CREATE TABLE IF NOT EXISTS indexed(\
                 session_id TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime_ms INTEGER NOT NULL);",
        )?;
        Ok(Self { conn })
    }

    /// Re-indexes every session file whose signature moved since the last
    /// refresh. Cheap after the first run: unchanged sessions cost one lookup.
    pub fn refresh(&mut self, sessions_dir: &Path) -> Result<(), SearchError> {
        for path in session_entries(sessions_dir)? {
            let Some(session_id) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            let Some((size, mtime_ms)) = file_signature(&path) else {
                continue;
            };
            let up_to_date = self.conn.query_row(
                "SELECT 1 FROM indexed WHERE session_id = ?1 AND size = ?2 AND mtime_ms = ?3",
                (session_id, size, mtime_ms),
                |_| Ok(()),
            );
            if up_to_date.is_ok() {
                continue;
            }
            let rows = transcript_rows(&fs::read(&path)?);
            let tx = self.conn.transaction()?;
            tx.execute(
                "DELETE FROM transcript WHERE session_id = ?1",
                (session_id,),
            )?;
            {
                let mut stmt = tx.prepare(
                    "INSERT INTO transcript (session_id, role, content) VALUES (?1, ?2, ?3)",
                )?;
                for (role, content) in rows {
                    stmt.execute((session_id, role, content))?;
                }
            }
            tx.execute(
                "INSERT INTO indexed (session_id, size, mtime_ms) VALUES (?1, ?2, ?3)\
                 ON CONFLICT(session_id) DO UPDATE SET size = ?2, mtime_ms = ?3",
                (session_id, size, mtime_ms),
            )?;
            tx.commit()?;
        }
        Ok(())
    }

    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchHit>, SearchError> {
        if query.trim().is_empty() {
            return Ok(Vec::new());
        }
        let mut stmt = self.conn.prepare(
            "SELECT session_id, role, snippet(transcript, 2, '', '', '…', ?1)\
             FROM transcript WHERE transcript MATCH ?2 ORDER BY rank LIMIT ?3",
        )?;
        let hits = stmt
            .query_map((SNIPPET_WORDS, match_query(query), limit), |row| {
                Ok(SearchHit {
                    session_id: row.get(0)?,
                    role: row.get(1)?,
                    snippet: row.get(2)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(hits)
    }
}

/// Quotes each term so user input is never read as FTS5 syntax.
fn match_query(query: &str) -> String {
    let mut out = String::new();
    for term in query.split_whitespace() {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push('"');
        out.push_str(&term.replace('"', "\"\""));
        out.push('"');
    }
    out
}

/// One `(role, content)` row per transcript message, read straight off the
/// JSONL so the index never needs the typed session loader.
fn transcript_rows(data: &[u8]) -> Vec<(String, String)> {
    let mut rows = Vec::new();
    for line in data.split(|&b| b == b'\n') {
        let Ok(record) = serde_json::from_slice::<serde_json::Value>(line) else {
            continue;
        };
        if !record
            .get("t")
            .and_then(|t| t.as_str())
            .is_some_and(|t| MSG_TAGS.contains(&t))
        {
            continue;
        }
        let Some(message) = record.get("d") else {
            continue;
        };
        let role = message
            .get("role")
            .and_then(|r| r.as_str())
            .unwrap_or_default()
            .to_string();
        let mut content = String::new();
        collect_text(message.get("content"), &mut content);
        if !content.is_empty() {
            rows.push((role, content));
        }
    }
    rows
}

/// Message content is either a plain string or an array of blocks; only the
/// text a user or the model actually wrote is worth searching.
fn collect_text(value: Option<&serde_json::Value>, out: &mut String) {
    match value {
        Some(serde_json::Value::String(s)) => {
            if !out.is_empty() {
                out.push(' ');
            }
            out.push_str(s);
        }
        Some(serde_json::Value::Array(blocks)) => {
            for block in blocks {
                collect_text(block.get("text"), out);
            }
        }
        _ => {}
    }
}

/// Refreshes the index under the state dir and runs one query against it.
pub fn search_sessions(
    dir: &StateDir,
    query: &str,
    limit: usize,
) -> Result<Vec<SearchHit>, SearchError> {
    let sessions_dir = dir.path().join(SESSIONS_DIR);
    let mut index = SessionIndex::open(&dir.path().join(SEARCH_INDEX_FILE))?;
    index.refresh(&sessions_dir)?;
    index.search(query, limit)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sessions::Session;

    const QUERY: &str = "durability";
    const MISS: &str = "nothing-matches-this";
    const HIT_SNIPPET: &str = "flush before durability checkpoints";
    const SECOND_SESSION_TEXT: &str = "an unrelated conversation";

    fn tempdir() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }

    #[test]
    fn search_finds_text_across_sessions() {
        let tmp = tempdir();
        let dir = StateDir::from_path(tmp.path().to_path_buf());
        let sessions_dir = dir.path().join(SESSIONS_DIR);
        fs::create_dir_all(&sessions_dir).unwrap();
        let first =
            Session::<serde_json::Value, serde_json::Value, serde_json::Value>::new("m", "/tmp");
        fs::write(
            sessions_dir.join(format!("{}.jsonl", first.id)),
            format!(
                "{{\"t\":\"header\",\"v\":1,\"id\":\"{id}\",\"model\":\"m\",\"cwd\":\"/tmp\",\"created_at\":0}}\n\
                 {{\"t\":\"msg\",\"d\":{{\"role\":\"user\",\"content\":[{{\"type\":\"text\",\"text\":\"{HIT_SNIPPET}\"}}]}}}}\n",
                id = first.id,
            ),
        )
        .unwrap();
        let second =
            Session::<serde_json::Value, serde_json::Value, serde_json::Value>::new("m", "/tmp");
        fs::write(
            sessions_dir.join(format!("{}.jsonl", second.id)),
            format!(
                "{{\"t\":\"header\",\"v\":1,\"id\":\"{id}\",\"model\":\"m\",\"cwd\":\"/tmp\",\"created_at\":0}}\n\
                 {{\"t\":\"msg\",\"d\":{{\"role\":\"assistant\",\"content\":\"{SECOND_SESSION_TEXT}\"}}}}\n",
                id = second.id,
            ),
        )
        .unwrap();

        let hits = search_sessions(&dir, QUERY, DEFAULT_SEARCH_LIMIT).unwrap();
        assert_eq!(hits.len(), 1, "{hits:?}");
        assert_eq!(hits[0].session_id, first.id.to_string());
        assert_eq!(hits[0].role, "user");
        assert!(hits[0].snippet.contains(QUERY), "{:?}", hits[0].snippet);

        assert!(
            search_sessions(&dir, MISS, DEFAULT_SEARCH_LIMIT)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn refresh_does_not_duplicate_rows() {
        let tmp = tempdir();
        let sessions_dir = tmp.path().join(SESSIONS_DIR);
        fs::create_dir_all(&sessions_dir).unwrap();
        fs::write(
            sessions_dir.join("a.jsonl"),
            format!(
                "{{\"t\":\"msg\",\"d\":{{\"role\":\"user\",\"content\":\"{HIT_SNIPPET}\"}}}}\n"
            ),
        )
        .unwrap();

        let index_path = tmp.path().join(SEARCH_INDEX_FILE);
        let mut index = SessionIndex::open(&index_path).unwrap();
        index.refresh(&sessions_dir).unwrap();
        index.refresh(&sessions_dir).unwrap();

        assert_eq!(index.search(QUERY, DEFAULT_SEARCH_LIMIT).unwrap().len(), 1);
    }

    #[test]
    fn fts_syntax_in_user_input_is_never_interpreted() {
        assert_eq!(
            match_query("foo\" OR 1=1 --"),
            "\"foo\"\"\" \"OR\" \"1=1\" \"--\""
        );
        assert_eq!(match_query("  "), "");
    }
}
