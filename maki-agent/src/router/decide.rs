use std::collections::BTreeMap;

use maki_config::ModelPolicy;
use maki_providers::model::Model;

use super::jev::{JevClient, Question};

pub const SUMMARY_MAX_CHARS: usize = 2000;

#[derive(Debug, Clone, PartialEq)]
pub struct RouterDecision {
    pub spec: Option<String>,
    pub reason: Reason,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    JevPick,
    LowConfidence,
    NoCandidates,
    BackendUnavailable,
    Heuristic,
}

pub struct RouterInput {
    /// User prompt only, capped: never tool output, which can carry injected
    /// routing instructions.
    pub task_summary: String,
    pub recent_tools: Vec<String>,
    pub context_tokens: u32,
    pub current_spec: String,
}

pub fn task_summary(prompt: &str) -> String {
    prompt.chars().take(SUMMARY_MAX_CHARS).collect()
}

/// Specs from config that may actually be adopted: parseable, policy-allowed,
/// and frame-compatible with the current model (same provider, same thinking
/// support), so a mid-run swap stays inside `sync_model`'s fingerprint rules.
pub fn filter_candidates(
    candidates: &[String],
    policy: &ModelPolicy,
    current: &Model,
) -> Vec<Model> {
    candidates
        .iter()
        .filter_map(|spec| Model::from_spec(spec).ok())
        .filter(|m| {
            m.spec() != current.spec()
                && m.provider == current.provider
                && m.supports_thinking() == current.supports_thinking()
                && policy.allows(&m.spec())
        })
        .collect()
}

/// The confidence gate: a pick is adopted only above the threshold, and only
/// when it names a filtered candidate.
pub fn apply_decision(
    pick: Option<&str>,
    confidence: Option<f32>,
    filtered: &[Model],
    threshold: f32,
) -> RouterDecision {
    if filtered.is_empty() {
        return RouterDecision {
            spec: None,
            reason: Reason::NoCandidates,
        };
    }
    let Some(spec) = pick else {
        return RouterDecision {
            spec: None,
            reason: Reason::LowConfidence,
        };
    };
    let in_bounds = confidence.is_some_and(|c| c >= threshold);
    let listed = filtered.iter().any(|m| m.spec() == spec);
    if in_bounds && listed {
        RouterDecision {
            spec: Some(spec.to_string()),
            reason: Reason::JevPick,
        }
    } else {
        RouterDecision {
            spec: None,
            reason: Reason::LowConfidence,
        }
    }
}

/// Synchronous fallback: a strong model when the context is nearly full.
pub fn heuristic(input: &RouterInput, filtered: &[Model]) -> RouterDecision {
    const NEARLY_FULL_TOKENS: u32 = 120_000;
    if input.context_tokens < NEARLY_FULL_TOKENS {
        return RouterDecision {
            spec: None,
            reason: Reason::Heuristic,
        };
    }
    filtered.first().map_or(
        RouterDecision {
            spec: None,
            reason: Reason::Heuristic,
        },
        |m| RouterDecision {
            spec: Some(m.spec()),
            reason: Reason::Heuristic,
        },
    )
}

/// One Jev call, then the gate. Any backend failure falls back to the
/// heuristic; a run never fails because the router could not decide.
pub async fn route(
    client: &JevClient,
    policy: &ModelPolicy,
    candidates: &[String],
    input: &RouterInput,
    threshold: f32,
) -> RouterDecision {
    let filtered = filter_candidates(candidates, policy, &current_model(input));
    if filtered.is_empty() {
        return RouterDecision {
            spec: None,
            reason: Reason::NoCandidates,
        };
    }
    let mut questions = BTreeMap::from([(
        "model".to_string(),
        Question::Choice {
            instructions:
                "Which model should handle this task? Consider difficulty and context size."
                    .to_string(),
            criteria: filtered
                .iter()
                .map(|m| (m.spec(), model_criterion(m)))
                .collect(),
        },
    )]);
    questions.insert(
        "needs_strong_model".to_string(),
        Question::Noul {
            instructions: "Does this task need the strongest available model?".to_string(),
        },
    );
    let state = serde_json::json!({
        "task": input.task_summary,
        "recent_tools": input.recent_tools,
        "context_tokens": input.context_tokens,
        "current_model": input.current_spec,
    });
    match client.decide(&state, questions).await {
        Ok(answers) => {
            let model_answer = answers.get("model");
            apply_decision(
                model_answer.and_then(|a| a.choice.as_deref()),
                model_answer.and_then(|a| a.confidence),
                &filtered,
                threshold,
            )
        }
        Err(_) => heuristic(input, &filtered),
    }
}

fn current_model(input: &RouterInput) -> Model {
    Model::from_spec(&input.current_spec)
        .unwrap_or_else(|_| Model::from_spec("zai/glm-5.3-flash").expect("builtin fallback spec"))
}

fn model_criterion(model: &Model) -> String {
    if model.supports_thinking() {
        "strong reasoning, slower and costlier".to_string()
    } else {
        "fast and cheap".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PICKED: &str = "zai/glm-5.3-flash";
    const CURRENT: &str = "zai/glm-5.3-flash";

    fn current_model() -> Model {
        Model::from_spec(CURRENT).expect("current spec parses")
    }

    fn input_big() -> RouterInput {
        RouterInput {
            task_summary: task_summary("fix a typo"),
            recent_tools: vec!["read".to_string()],
            context_tokens: NEARLY_FULL + 1,
            current_spec: CURRENT.to_string(),
        }
    }

    const NEARLY_FULL: u32 = 120_000;

    #[test]
    fn task_summary_caps_length_and_keeps_text() {
        let long = "a".repeat(SUMMARY_MAX_CHARS + 500);
        assert_eq!(task_summary(&long).chars().count(), SUMMARY_MAX_CHARS);
        assert_eq!(task_summary("hello"), "hello");
    }

    #[test]
    fn policy_excluded_candidate_is_filtered_out() {
        let policy = ModelPolicy::new(&[], &[PICKED.to_string()]).expect("policy");
        let filtered = filter_candidates(&[PICKED.to_string()], &policy, &current_model());
        assert!(filtered.is_empty());
    }

    #[test]
    fn current_model_is_never_its_own_candidate() {
        let policy = ModelPolicy::new(&[], &[]).expect("policy");
        let filtered = filter_candidates(&[CURRENT.to_string()], &policy, &current_model());
        assert!(filtered.is_empty());
    }

    #[test]
    fn decision_needs_threshold_and_membership() {
        let filtered = vec![Model::from_spec("zai/glm-5.3-flash").expect("spec")];
        let low = apply_decision(Some(PICKED), Some(0.4), &filtered, 0.7);
        assert_eq!(low.reason, Reason::LowConfidence);
        assert_eq!(low.spec, None);
        let ok = apply_decision(Some(PICKED), Some(0.9), &filtered, 0.7);
        assert_eq!(ok.reason, Reason::JevPick);
        assert_eq!(ok.spec.as_deref(), Some(PICKED));
        let unlisted = apply_decision(Some("anthropic/claude-opus-4"), Some(0.9), &filtered, 0.7);
        assert_eq!(unlisted.reason, Reason::LowConfidence);
    }

    #[test]
    fn empty_candidates_short_circuit() {
        let d = apply_decision(Some(PICKED), Some(0.99), &[], 0.7);
        assert_eq!(d.reason, Reason::NoCandidates);
    }

    #[test]
    fn heuristic_picks_a_model_only_when_context_is_nearly_full() {
        let policy = ModelPolicy::new(&[], &[]).expect("policy");
        let candidate = "zai/glm-4-7-air";
        let filtered = filter_candidates(&[candidate.to_string()], &policy, &current_model());
        assert_eq!(filtered.len(), 1, "a distinct same-provider model is eligible");
        let input = input_big();
        let picked = heuristic(&input, &filtered);
        assert_eq!(picked.spec.as_deref(), Some(candidate));
        assert_eq!(picked.reason, Reason::Heuristic);
        let small = RouterInput {
            context_tokens: 100,
            ..input
        };
        assert_eq!(
            heuristic(&small, &filtered).spec,
            None,
            "below the threshold no model is forced"
        );
    }
}