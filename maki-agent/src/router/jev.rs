use isahc::AsyncReadResponseExt;
use isahc::config::Configurable;
use std::collections::BTreeMap;
#[cfg(test)]
use std::io::{Read, Write};
#[cfg(test)]
use std::net::TcpListener;
#[cfg(test)]
use std::thread;
use std::time::Duration;

use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, thiserror::Error)]
pub enum JevError {
    #[error("jev request failed: {0}")]
    Http(String),
    #[error("jev response malformed: {0}")]
    Malformed(&'static str),
    #[error("JEV_API_KEY not set (env {0})")]
    MissingKey(String),
}

#[derive(Debug, Clone)]
pub enum Question {
    Choice {
        instructions: String,
        criteria: BTreeMap<String, String>,
    },
    Noul {
        instructions: String,
    },
}

impl Question {
    fn to_json(&self) -> Value {
        match self {
            Question::Choice {
                instructions,
                criteria,
            } => serde_json::json!({
                "type": "choice",
                "instructions": instructions,
                "criteria": criteria,
            }),
            Question::Noul { instructions } => serde_json::json!({
                "type": "noul",
                "instructions": instructions,
            }),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct Answer {
    pub choice: Option<String>,
    pub confidence: Option<f32>,
    pub noul: Option<f32>,
}

#[derive(Deserialize)]
struct RawAnswer {
    #[serde(default)]
    choice: Option<String>,
    #[serde(default)]
    confidence: Option<f32>,
    #[serde(default)]
    noul: Option<f32>,
}

pub struct JevClient {
    endpoint: String,
    api_key: Option<String>,
    http: Option<isahc::HttpClient>,
}

impl JevClient {
    pub fn new(config: &maki_config::RouterConfig) -> Self {
        Self {
            endpoint: config.endpoint.clone(),
            api_key: std::env::var(&config.api_key_env).ok(),
            http: isahc::HttpClient::builder()
                .timeout(Duration::from_millis(config.timeout_ms))
                .version_negotiation(isahc::config::VersionNegotiation::http11())
                .build()
                .ok(),
        }
    }

    pub fn has_key(&self) -> bool {
        self.api_key.is_some()
    }

    /// One round trip: all questions are evaluated in parallel against `state`.
    pub async fn decide(
        &self,
        state: &Value,
        questions: BTreeMap<String, Question>,
    ) -> Result<BTreeMap<String, Answer>, JevError> {
        let Some(key) = &self.api_key else {
            return Err(JevError::MissingKey("JEV_API_KEY".to_string()));
        };
        let Some(http) = &self.http else {
            return Err(JevError::Http("http client unavailable".to_string()));
        };
        let body = serde_json::json!({
            "model": "jev-latest",
            "state": state,
            "questions": questions
                .iter()
                .map(|(name, q)| (name.as_str(), q.to_json()))
                .collect::<BTreeMap<_, _>>(),
        });
        let request = isahc::Request::builder()
            .method("POST")
            .uri(&self.endpoint)
            .header("authorization", format!("Bearer {key}"))
            .header("content-type", "application/json")
            .header("accept", "application/json")
            .body(isahc::AsyncBody::from_bytes_static(body.to_string()))
            .map_err(|e| JevError::Http(e.to_string()))?;
        let response = http
            .send_async(request)
            .await
            .map_err(|e| JevError::Http(e.to_string()))?;
        if !response.status().is_success() {
            return Err(JevError::Http(format!("status {}", response.status())));
        }
        let mut response = response;
        let text = response
            .text()
            .await
            .map_err(|e| JevError::Http(e.to_string()))?;
        let parsed: Value =
            serde_json::from_str(&text).map_err(|_| JevError::Malformed("body is not JSON"))?;
        let answers = parsed
            .get("answers")
            .and_then(Value::as_object)
            .ok_or(JevError::Malformed("missing answers object"))?;
        let mut out = BTreeMap::new();
        for (name, raw) in answers {
            let raw: RawAnswer = serde_json::from_value(raw.clone())
                .map_err(|_| JevError::Malformed("answer shape"))?;
            if questions.contains_key(name) && raw.choice.is_none() && raw.noul.is_none() {
                return Err(JevError::Malformed("answer without choice or noul"));
            }
            out.insert(
                name.clone(),
                Answer {
                    choice: raw.choice,
                    confidence: raw.confidence,
                    noul: raw.noul,
                },
            );
        }
        Ok(out)
    }
}

#[cfg(test)]
fn test_client(uri: String) -> JevClient {
    let config = maki_config::RouterConfig {
        endpoint: format!("{uri}/v1/decide"),
        timeout_ms: 2000,
        ..maki_config::RouterConfig::default()
    };
    let client = JevClient::new(&config);
    JevClient {
        api_key: client.api_key.or(Some("test".to_string())),
        ..client
    }
}

#[cfg(test)]
fn test_questions() -> BTreeMap<String, Question> {
    BTreeMap::from([
        (
            "model".to_string(),
            Question::Choice {
                instructions: "pick a model".to_string(),
                criteria: BTreeMap::from([(
                    "zai/glm-5.3-flash".to_string(),
                    "fast".to_string(),
                )]),
            },
        ),
        (
            "risky".to_string(),
            Question::Noul {
                instructions: "is this risky?".to_string(),
            },
        ),
    ])
}

/// Minimal HTTP server: one canned response per accepted connection.
#[cfg(test)]
fn mock_server(status: &'static str, body: &'static str) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0u8; 4096];
            let _ = stream.read(&mut buf);
            let response = format!("HTTP/1.1 {status}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len());
            let _ = stream.write_all(response.as_bytes());
        }
    });
    format!("http://{addr}")
}

#[test]
fn decide_parses_choice_and_noul_answers() {
    let body = r#"{"answers": {
        "model": {"choice": "zai/glm-5.3-flash", "confidence": 0.91},
        "risky": {"noul": 0.02}
    }}"#;
    let server = mock_server("200 OK", body);
    let client = test_client(server);
    let answers = smol::block_on(client.decide(
        &serde_json::json!({"task": "fix a typo"}),
        test_questions(),
    ))
    .expect("decide ok");
    assert_eq!(
        answers["model"].choice.as_deref(),
        Some("zai/glm-5.3-flash")
    );
    assert!((answers["model"].confidence.unwrap() - 0.91).abs() < 1e-6);
    assert!((answers["risky"].noul.unwrap() - 0.02).abs() < 1e-6);
}

#[test]
fn decide_surfaces_transport_errors_as_jev_error() {
    let client = test_client("http://127.0.0.1:1".to_string());
    let result = smol::block_on(client.decide(&serde_json::json!({}), test_questions()));
    assert!(matches!(result, Err(JevError::Http(_))));
}

#[test]
fn decide_flags_malformed_answers() {
    let server = mock_server("200 OK", r#"{"answers": {"model": {}}}"#);
    let client = test_client(server);
    let result = smol::block_on(client.decide(&serde_json::json!({}), test_questions()));
    assert!(matches!(result, Err(JevError::Malformed(_))));
}
