//! Tests the workflow plugin end-to-end: real plugin source, real tool
//! registry, with `maki.agent.call_tool` replaced by a Lua stub so step
//! scripts exercise the bounded loop, checkpoints and resume.

use std::sync::Arc;

use maki_agent::tools::ToolRegistry;
use maki_agent::tools::test_support::stub_ctx;
use maki_agent::{AgentMode, ToolOutput};
use maki_lua::PluginHost;
use serde_json::{Value, json};
use test_case::test_case;

const WORKFLOW_PLUGIN_SRC: &str = include_str!("../../plugins/workflow/init.lua");

const WORKFLOW_TOOL: &str = "workflow";

const STUB_PRELUDE: &str = r#"
recorder = { calls = 0 }
maki.agent.call_tool = function(ctx, name, input, opts)
  recorder.calls = recorder.calls + 1
  recorder.timeout = opts and opts.timeout
  return "out:" .. name
end
"#;

const CHECKPOINT_FENCE: &str = "```json";

const TWO_STEP_SCRIPT: &str = r#"
return {
  start = "fetch",
  steps = {
    fetch = function(sctx, state)
      local out = sctx:call("read", { path = "a.txt" })
      sctx.log("got " .. out)
      return "done", { path = state.path }
    end,
    done = function(_, state)
      return nil, { path = state.path, finished = true }
    end,
  },
}
"#;

const LOOP_SCRIPT: &str = r#"
return {
  start = "spin",
  steps = {
    spin = function()
      return "spin", {}
    end,
  },
}
"#;

fn load_workflow_host() -> (Arc<ToolRegistry>, PluginHost) {
    let reg = Arc::new(ToolRegistry::new());
    let host = PluginHost::new(Arc::clone(&reg)).unwrap();
    host.load_source(
        "workflow_policy",
        &format!("{STUB_PRELUDE}\n{WORKFLOW_PLUGIN_SRC}"),
    )
    .unwrap();
    (reg, host)
}

fn exec_tool(reg: &ToolRegistry, input: Value) -> Result<String, String> {
    let entry = reg
        .get(WORKFLOW_TOOL)
        .unwrap_or_else(|| panic!("{WORKFLOW_TOOL} tool not registered"));
    let inv = entry.tool.parse(&input).expect("parse failed");
    let ctx = stub_ctx(&AgentMode::Build);
    smol::block_on(async { inv.execute(&ctx).await })
        .output
        .map(|out| match out {
            ToolOutput::Plain(s) | ToolOutput::Markdown(s) => s.text,
            other => panic!("unexpected output: {other:?}"),
        })
}

fn checkpoint_json(output: &str) -> Value {
    let start = output
        .find(CHECKPOINT_FENCE)
        .expect("checkpoint fence missing")
        + CHECKPOINT_FENCE.len()
        + 1;
    let end = start
        + output[start..]
            .find(CHECKPOINT_FENCE)
            .expect("no closing fence")
        - 1;
    serde_json::from_str(&output[start..end]).expect("checkpoint is not valid json")
}

fn step_ran(output: &str, step: &str) -> bool {
    output
        .lines()
        .any(|l| l.starts_with("- ") && l.contains(step))
}

const COMPILE_ERROR_SCRIPT: &str = "return {";

#[test]
fn workflow_runs_steps_calls_tools_and_reports_state() {
    let (reg, _host) = load_workflow_host();
    let out = exec_tool(&reg, json!({ "script": TWO_STEP_SCRIPT })).expect("workflow failed");
    assert!(step_ran(&out, "fetch"), "fetch step missing: {out}");
    assert!(step_ran(&out, "done"), "done step missing: {out}");
    assert!(
        out.contains("got out:read"),
        "tool result not logged: {out}"
    );
    assert!(
        out.contains(r#""finished":true"#) || out.contains(r#""finished": true"#),
        "final state missing: {out}"
    );
}

#[test_case(json!({}) ; "no_script")]
#[test_case(json!({ "script": "return 1" }) ; "bad_shape")]
#[test_case(json!({ "script": LOOP_SCRIPT }) ; "loop_detected")]
#[test_case(json!({ "script": COMPILE_ERROR_SCRIPT }) ; "compile_error")]
fn workflow_rejects_bad_runs(input: Value) {
    let (reg, _host) = load_workflow_host();
    let err = exec_tool(&reg, input).unwrap_err();
    assert!(!err.is_empty());
}

#[test]
fn workflow_loop_aborts_with_resumable_checkpoint() {
    let (reg, _host) = load_workflow_host();
    let err = exec_tool(&reg, json!({ "script": LOOP_SCRIPT })).unwrap_err();
    assert!(err.contains("loop detected"), "loop error missing: {err}");

    let ck = checkpoint_json(&err);
    assert!(ck["script"].is_string(), "checkpoint script id: {ck}");
    assert_eq!(ck["current"], "spin");
    assert_eq!(ck["history"].as_array().map(Vec::len), Some(1));
}

#[test]
fn workflow_resume_rejects_a_different_script() {
    let (reg, _host) = load_workflow_host();
    let err = exec_tool(&reg, json!({ "script": LOOP_SCRIPT })).unwrap_err();
    let ck = checkpoint_json(&err).to_string();
    let err = exec_tool(&reg, json!({ "script": TWO_STEP_SCRIPT, "resume": ck })).unwrap_err();
    assert!(err.contains("different script"), "mismatch error: {err}");
}

#[test]
fn workflow_step_limit_checkpoints_and_resumes() {
    let (reg, _host) = load_workflow_host();
    let err = exec_tool(&reg, json!({ "script": TWO_STEP_SCRIPT, "max_steps": 1 })).unwrap_err();
    assert!(err.contains("step budget exhausted"), "budget error: {err}");
    assert!(step_ran(&err, "fetch"), "fetch ran before the limit: {err}");

    let ck = checkpoint_json(&err).to_string();
    let out = exec_tool(
        &reg,
        json!({ "script": TWO_STEP_SCRIPT, "resume": ck, "max_steps": 2 }),
    )
    .expect("resume failed");
    assert!(step_ran(&out, "done"), "resumed step missing: {out}");
    assert!(!step_ran(&out, "fetch"), "already-run step repeated: {out}");
    assert!(out.contains("final state"), "no final state: {out}");
}

#[test]
fn workflow_step_error_reports_the_failure_with_a_checkpoint() {
    let script = r#"
return {
  start = "boom",
  steps = {
    boom = function()
      error("step exploded", 0)
    end,
  },
}
"#;
    let (reg, _host) = load_workflow_host();
    let err = exec_tool(&reg, json!({ "script": script })).unwrap_err();
    assert!(err.contains("step exploded"), "step error missing: {err}");
    let ck = checkpoint_json(&err);
    assert_eq!(ck["current"], "boom");
}
