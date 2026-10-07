//! Host-side job registry: id issuance, session-scoped owner isolation,
//! incremental polling and cancellation. Tool frontends (e.g. bash_bg via
//! maki-lua) register jobs here so state survives plugin reloads.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use thiserror::Error;

/// Lines kept per job; older ones are dropped and only counted.
const OUTPUT_CAPACITY: usize = 10_000;
const POLL_DEADLINE: Duration = Duration::from_secs(5);
const POLL_TICK: Duration = Duration::from_millis(10);
const SHELL: &str = "bash";

pub type JobId = u64;

#[derive(Debug, Error)]
pub enum JobError {
    #[error("unknown job id {0}")]
    Unknown(JobId),
    #[error("job {0} is owned by another session")]
    NotOwner(JobId),
    #[error("spawning job failed: {0}")]
    Spawn(#[source] std::io::Error),
    #[error("cancellation is unsupported on this platform")]
    CancelUnsupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct JobOwner(u64);

impl JobOwner {
    pub const fn new(session_key: u64) -> Self {
        Self(session_key)
    }
}

#[derive(Debug)]
pub struct JobSpec<'a> {
    pub owner: JobOwner,
    pub name: &'a str,
    pub command: &'a str,
    pub cwd: Option<&'a str>,
    pub env: &'a [(String, String)],
}

#[derive(Debug)]
pub struct PollSnapshot {
    pub id: JobId,
    pub name: String,
    pub new_lines: Vec<String>,
    pub dropped_lines: usize,
    pub exit_code: Option<i32>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum CancelOutcome {
    Killed,
    AlreadyExited(i32),
}

#[derive(Debug)]
pub struct JobInfo {
    pub id: JobId,
    pub name: String,
    pub owner: JobOwner,
    pub exit_code: Option<i32>,
}

#[derive(Default)]
struct JobOutput {
    lines: Vec<String>,
    dropped: usize,
    read: usize,
}

struct JobShared {
    output: Mutex<JobOutput>,
    exit_code: Mutex<Option<i32>>,
}

impl JobShared {
    fn push(&self, line: String) {
        let mut output = self.output.lock().expect("job output poisoned");
        if output.lines.len() == OUTPUT_CAPACITY {
            output.lines.remove(0);
            output.dropped += 1;
            if output.read > 0 {
                output.read -= 1;
            }
        }
        output.lines.push(line);
    }

    fn drain(&self) -> (Vec<String>, usize) {
        let mut output = self.output.lock().expect("job output poisoned");
        let dropped = output.dropped;
        let lines = output.lines[output.read.min(output.lines.len())..].to_vec();
        output.read = output.lines.len();
        (lines, dropped)
    }
}

struct JobEntry {
    id: JobId,
    owner: JobOwner,
    name: String,
    pid: u32,
    shared: Arc<JobShared>,
}

#[derive(Default)]
pub struct JobRegistry {
    next_id: AtomicU64,
    entries: Mutex<HashMap<JobId, Arc<JobEntry>>>,
}

impl JobRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn spawn(&self, spec: &JobSpec<'_>) -> Result<JobId, JobError> {
        let mut command = Command::new(SHELL);
        command
            .arg("-c")
            .arg(spec.command)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(cwd) = spec.cwd {
            command.current_dir(cwd);
        }
        for (key, value) in spec.env {
            command.env(key, value);
        }
        set_process_group(&mut command);
        let mut child = command.spawn().map_err(JobError::Spawn)?;
        let id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        let shared = Arc::new(JobShared {
            output: Mutex::new(JobOutput::default()),
            exit_code: Mutex::new(None),
        });
        let entry = Arc::new(JobEntry {
            id,
            owner: spec.owner,
            name: spec.name.to_string(),
            pid: child.id(),
            shared: Arc::clone(&shared),
        });
        self.entries
            .lock()
            .expect("job registry poisoned")
            .insert(id, Arc::clone(&entry));

        spawn_reader(child.stdout.take(), &shared);
        spawn_reader(child.stderr.take(), &shared);
        let shared = Arc::clone(&shared);
        std::thread::spawn(move || {
            // Signals are encoded as negative codes so a killed job still
            // reports an exit instead of None forever.
            *shared.exit_code.lock().expect("job exit poisoned") = exit_code(child.wait());
        });
        Ok(id)
    }

    fn entry(&self, id: JobId, owner: JobOwner) -> Result<Arc<JobEntry>, JobError> {
        let entry = self
            .entries
            .lock()
            .expect("job registry poisoned")
            .get(&id)
            .cloned()
            .ok_or(JobError::Unknown(id))?;
        if entry.owner != owner {
            return Err(JobError::NotOwner(id));
        }
        Ok(entry)
    }

    /// Returns the lines produced since the previous poll by the same caller.
    pub fn poll(&self, owner: JobOwner, id: JobId) -> Result<PollSnapshot, JobError> {
        let entry = self.entry(id, owner)?;
        let (new_lines, dropped_lines) = entry.shared.drain();
        Ok(PollSnapshot {
            id,
            name: entry.name.clone(),
            new_lines,
            dropped_lines,
            exit_code: *entry.shared.exit_code.lock().expect("job exit poisoned"),
        })
    }

    /// Waits until the job exits or the internal deadline passes, then polls.
    pub fn poll_exited(&self, owner: JobOwner, id: JobId) -> Result<PollSnapshot, JobError> {
        let entry = self.entry(id, owner)?;
        let deadline = Instant::now() + POLL_DEADLINE;
        loop {
            let exit_code = *entry.shared.exit_code.lock().expect("job exit poisoned");
            if let Some(code) = exit_code {
                let mut snapshot = self.poll(owner, id)?;
                snapshot.exit_code = Some(code);
                return Ok(snapshot);
            }
            if Instant::now() >= deadline {
                return self.poll(owner, id);
            }
            std::thread::sleep(POLL_TICK);
        }
    }

    pub fn cancel(&self, owner: JobOwner, id: JobId) -> Result<CancelOutcome, JobError> {
        let entry = self.entry(id, owner)?;
        let exit_code = entry.shared.exit_code.lock().expect("job exit poisoned");
        if let Some(code) = *exit_code {
            return Ok(CancelOutcome::AlreadyExited(code));
        }
        drop(exit_code);
        match kill_process_group(entry.pid) {
            Ok(()) => Ok(CancelOutcome::Killed),
            // The process died between the check and the signal: not a failure.
            Err(JobError::Spawn(err)) if err.raw_os_error() == Some(libc::ESRCH) => {
                Ok(CancelOutcome::Killed)
            }
            Err(err) => Err(err),
        }
    }

    pub fn list(&self, owner: JobOwner) -> Vec<JobInfo> {
        self.entries
            .lock()
            .expect("job registry poisoned")
            .values()
            .filter(|entry| entry.owner == owner)
            .map(|entry| JobInfo {
                id: entry.id,
                name: entry.name.clone(),
                owner: entry.owner,
                exit_code: *entry.shared.exit_code.lock().expect("job exit poisoned"),
            })
            .collect()
    }

    pub fn forget(&self, owner: JobOwner, id: JobId) -> Result<bool, JobError> {
        self.entry(id, owner)?;
        Ok(self
            .entries
            .lock()
            .expect("job registry poisoned")
            .remove(&id)
            .is_some())
    }
}

fn exit_code(status: std::io::Result<std::process::ExitStatus>) -> Option<i32> {
    let status = status.ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        // Signals are encoded as negative codes so a killed job still reports
        // an exit instead of None forever.
        status
            .code()
            .or_else(|| status.signal().map(|signal| -signal))
    }
    #[cfg(not(unix))]
    status.code()
}

fn spawn_reader<T: std::io::Read + Send + 'static>(pipe: Option<T>, shared: &Arc<JobShared>) {
    if let Some(pipe) = pipe {
        let shared = Arc::clone(shared);
        std::thread::spawn(move || {
            for line in BufReader::new(pipe).lines() {
                match line {
                    Ok(line) => shared.push(line),
                    Err(_) => break,
                }
            }
        });
    }
}

#[cfg(unix)]
fn set_process_group(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    command.process_group(0);
}

#[cfg(not(unix))]
fn set_process_group(_command: &mut Command) {}

#[cfg(unix)]
fn kill_process_group(pid: u32) -> Result<(), JobError> {
    let rc = unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
    if rc != 0 {
        return Err(JobError::Spawn(std::io::Error::last_os_error()));
    }
    Ok(())
}

#[cfg(not(unix))]
fn kill_process_group(_pid: u32) -> Result<(), JobError> {
    Err(JobError::CancelUnsupported)
}

#[cfg(test)]
mod tests {
    use test_case::test_case;

    use super::*;
    use crate::jobs::{CancelOutcome, JobOwner, JobRegistry, JobSpec};

    const SESSION_A: JobOwner = JobOwner::new(1);
    const SESSION_B: JobOwner = JobOwner::new(2);
    const NO_ENV: &[(String, String)] = &[];
    const ECHO_JOB: &str = "echo hello";
    const HELLO_LINE: &str = "hello";
    const SLEEP_JOB: &str = "sleep 60";
    const EXIT_3: &str = "exit 3";

    fn spec<'a>(owner: JobOwner, name: &'a str, command: &'a str) -> JobSpec<'a> {
        JobSpec {
            owner,
            name,
            command,
            cwd: None,
            env: NO_ENV,
        }
    }

    #[test]
    fn ids_are_unique_and_positive() {
        let registry = JobRegistry::new();
        let first = registry.spawn(&spec(SESSION_A, "a", ECHO_JOB)).unwrap();
        let second = registry.spawn(&spec(SESSION_A, "b", ECHO_JOB)).unwrap();
        assert_ne!(first, second);
        assert!(first > 0 && second > 0);
    }

    #[test]
    fn poll_returns_output_then_exit_code() {
        let registry = JobRegistry::new();
        let id = registry.spawn(&spec(SESSION_A, "echo", ECHO_JOB)).unwrap();
        let snapshot = registry.poll_exited(SESSION_A, id).unwrap();
        assert_eq!(snapshot.new_lines, [HELLO_LINE]);
        assert_eq!(snapshot.exit_code, Some(0));
    }

    #[test_case(3)]
    fn poll_reports_nonzero_exit(code: i32) {
        let registry = JobRegistry::new();
        let id = registry.spawn(&spec(SESSION_A, "fail", EXIT_3)).unwrap();
        let snapshot = registry.poll_exited(SESSION_A, id).unwrap();
        assert_eq!(snapshot.exit_code, Some(code));
    }

    #[test]
    fn poll_is_incremental() {
        let registry = JobRegistry::new();
        let id = registry
            .spawn(&spec(SESSION_A, "seq", "echo one; sleep 0.05; echo two"))
            .unwrap();
        let first = registry.poll_exited(SESSION_A, id).unwrap();
        let second = registry.poll(SESSION_A, id).unwrap();
        assert!(first.new_lines.contains(&"one".to_string()));
        assert!(first.new_lines.contains(&"two".to_string()));
        assert!(second.new_lines.is_empty());
    }

    #[test]
    fn owner_isolation_blocks_other_sessions() {
        let registry = JobRegistry::new();
        let id = registry.spawn(&spec(SESSION_A, "job", ECHO_JOB)).unwrap();
        assert!(matches!(
            registry.poll(SESSION_B, id),
            Err(JobError::NotOwner(err_id)) if err_id == id
        ));
        assert!(matches!(
            registry.cancel(SESSION_B, id),
            Err(JobError::NotOwner(err_id)) if err_id == id
        ));
        assert!(registry.list(SESSION_B).is_empty());
        assert_eq!(registry.list(SESSION_A).len(), 1);
    }

    #[test]
    fn unknown_job_id_is_reported() {
        let registry = JobRegistry::new();
        assert!(matches!(
            registry.poll(SESSION_A, 999),
            Err(JobError::Unknown(999))
        ));
    }

    #[test]
    fn cancel_kills_running_job() {
        let registry = JobRegistry::new();
        let id = registry
            .spawn(&spec(SESSION_A, "sleep", SLEEP_JOB))
            .unwrap();
        assert_eq!(
            registry.cancel(SESSION_A, id).unwrap(),
            CancelOutcome::Killed
        );
        let snapshot = registry.poll_exited(SESSION_A, id).unwrap();
        assert_ne!(snapshot.exit_code, Some(0));
        assert_eq!(
            registry.cancel(SESSION_A, id).unwrap(),
            CancelOutcome::AlreadyExited(snapshot.exit_code.unwrap())
        );
    }

    #[test]
    fn forget_removes_finished_job() {
        let registry = JobRegistry::new();
        let id = registry.spawn(&spec(SESSION_A, "echo", ECHO_JOB)).unwrap();
        registry.poll_exited(SESSION_A, id).unwrap();
        assert!(registry.forget(SESSION_A, id).unwrap());
        assert!(matches!(
            registry.poll(SESSION_A, id),
            Err(JobError::Unknown(_))
        ));
    }

    #[test]
    fn env_and_cwd_are_applied() {
        let dir = tempfile::tempdir().unwrap();
        let env = vec![("MAKI_JOB_TEST".to_string(), "42".to_string())];
        let registry = JobRegistry::new();
        let id = registry
            .spawn(&JobSpec {
                owner: SESSION_A,
                name: "env",
                command: "echo $MAKI_JOB_TEST:$(basename \"$PWD\")",
                cwd: Some(dir.path().to_str().unwrap()),
                env: &env,
            })
            .unwrap();
        let expected = format!("42:{}", dir.path().file_name().unwrap().to_string_lossy());
        let snapshot = registry.poll_exited(SESSION_A, id).unwrap();
        assert_eq!(snapshot.new_lines, [expected]);
    }
}
