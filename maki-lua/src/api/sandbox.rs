use std::{
    env,
    path::{Path, PathBuf},
    process::Command,
};
use thiserror::Error;

pub(crate) const WORKSPACE_WRITE: &str = "workspace_write";

#[cfg(target_os = "macos")]
const BACKEND: &str = "/usr/bin/sandbox-exec";
#[cfg(target_os = "macos")]
const PROBE_PROFILE: &str = "(version 1)(allow default)";
#[cfg(not(target_os = "macos"))]
const BACKEND: &str = "bwrap";
const PROBE_BIN: &str = "/usr/bin/true";

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
const NO_BACKEND_PLATFORM: bool = true;
#[cfg(any(target_os = "macos", target_os = "linux"))]
const NO_BACKEND_PLATFORM: bool = false;

const PROFILE_TMPL: &str = "\
(version 1)
(deny default)
(allow process*)
(allow file-read*)
(allow file-write* (subpath \"/tmp\") (subpath \"/private/tmp\") (subpath \"{workspace}\"))";

#[derive(Debug, Error)]
pub(crate) enum SandboxError {
    #[error(
        "sandbox requested but no backend is available on this platform (macOS sandbox-exec or Linux bwrap)"
    )]
    NoBackend,
    #[error(
        "sandbox backend {backend:?} failed its startup probe ({reason}); refusing to run unsandboxed"
    )]
    ProbeFailed {
        backend: &'static str,
        reason: String,
    },
    #[error("sandbox workspace {path:?} is not an absolute directory")]
    BadWorkspace { path: PathBuf },
}

#[cfg(target_os = "macos")]
fn seatbelt_profile(workspace: &Path) -> String {
    PROFILE_TMPL.replace("{workspace}", &workspace.to_string_lossy())
}

/// argv prefix that runs everything after it under the sandbox: reads allowed
/// everywhere, writes confined to the workspace and tmp.
fn backend_argv(workspace: &Path) -> Vec<String> {
    #[cfg(target_os = "macos")]
    {
        vec![
            BACKEND.to_string(),
            "-p".to_string(),
            seatbelt_profile(workspace),
        ]
    }
    #[cfg(target_os = "linux")]
    {
        let ws = workspace.to_string_lossy().into_owned();
        vec![
            BACKEND.to_string(),
            "--ro-bind".to_string(),
            "/".to_string(),
            "--bind".to_string(),
            ws.clone(),
            ws,
            "--dev".to_string(),
            "/dev".to_string(),
            "--proc".to_string(),
            "/proc".to_string(),
            "--tmpfs".to_string(),
            "/tmp".to_string(),
            "--unshare-pid".to_string(),
            "--die-with-parent".to_string(),
        ]
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = workspace;
        Vec::new()
    }
}

fn probe_argv() -> Vec<String> {
    #[cfg(target_os = "macos")]
    {
        vec![
            BACKEND.to_string(),
            "-p".to_string(),
            PROBE_PROFILE.to_string(),
            PROBE_BIN.to_string(),
        ]
    }
    #[cfg(target_os = "linux")]
    {
        vec![
            BACKEND.to_string(),
            "--ro-bind".to_string(),
            "/".to_string(),
            "--dev".to_string(),
            "/dev".to_string(),
            "--".to_string(),
            PROBE_BIN.to_string(),
        ]
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        Vec::new()
    }
}

/// A real run through the backend, not a PATH lookup: a bwrap with the suid
/// bit stripped (containers, hardened distros) passes `which` and still cannot
/// sandbox anything. Fail-closed: any doubt becomes an error, never a silent
/// unsandboxed run.
pub(crate) trait BackendProbe {
    fn probe(&self) -> Result<(), SandboxError>;
}

struct RealBackend;

impl BackendProbe for RealBackend {
    fn probe(&self) -> Result<(), SandboxError> {
        if NO_BACKEND_PLATFORM {
            return Err(SandboxError::NoBackend);
        }
        let mut argv = probe_argv();
        let output = Command::new(argv.remove(0))
            .args(&argv)
            .output()
            .map_err(|e| SandboxError::ProbeFailed {
                backend: BACKEND,
                reason: e.to_string(),
            })?;
        if output.status.success() {
            return Ok(());
        }
        Err(SandboxError::ProbeFailed {
            backend: BACKEND,
            reason: format!("exit status {}", output.status.code().unwrap_or(-1)),
        })
    }
}

fn workspace_dir(cwd: Option<&Path>) -> Result<PathBuf, SandboxError> {
    let dir = match cwd {
        Some(dir) => dir.to_path_buf(),
        None => env::current_dir().map_err(|e| SandboxError::ProbeFailed {
            backend: BACKEND,
            reason: format!("cannot resolve working directory: {e}"),
        })?,
    };
    if !dir.is_absolute() || !dir.is_dir() {
        return Err(SandboxError::BadWorkspace { path: dir });
    }
    Ok(dir)
}

/// Rewrites `command` so the original program and its args run confined:
/// reads allowed everywhere, writes land only in the workspace and tmp, and
/// the whole child tree dies with maki.
pub(crate) fn wrap(command: &mut Command, cwd: Option<&Path>) -> Result<(), SandboxError> {
    wrap_with(&RealBackend, command, cwd)
}

fn wrap_with(
    backend: &dyn BackendProbe,
    command: &mut Command,
    cwd: Option<&Path>,
) -> Result<(), SandboxError> {
    backend.probe()?;
    let workspace = workspace_dir(cwd)?;
    let mut argv = backend_argv(&workspace);
    #[cfg(target_os = "linux")]
    argv.push("--".to_string());
    argv.push(command.get_program().to_string_lossy().into_owned());
    argv.extend(
        command
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned()),
    );
    *command = Command::new(argv[0].clone());
    command.args(&argv[1..]);
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use test_case::test_case;

    const WORKSPACE: &str = "/definitely/workspace";

    #[test_case(Path::new(WORKSPACE); "macos_profile_names_workspace")]
    #[cfg(target_os = "macos")]
    fn profile_grants_workspace_write(workspace: &Path) {
        let profile = seatbelt_profile(workspace);
        assert!(profile.contains("(subpath \"/definitely/workspace\")"));
        assert!(profile.contains("(deny default)"));
        assert!(profile.contains("(allow file-read*)"));
    }

    #[test_case(Path::new(WORKSPACE); "linux_argv_binds_workspace")]
    #[cfg(target_os = "linux")]
    fn argv_binds_workspace(workspace: &Path) {
        let argv = backend_argv(workspace);
        assert_eq!(argv.first().map(String::as_str), Some(BACKEND));
        assert!(
            argv.windows(2)
                .any(|w| w[0] == "--bind" && w[1] == WORKSPACE)
        );
        assert!(*argv.last().expect("non-empty") != "--");
    }

    #[test_case(Some(Path::new("no/such/dir")); "missing_cwd_is_rejected")]
    fn missing_cwd_is_rejected(cwd: Option<&Path>) {
        assert!(matches!(
            workspace_dir(cwd),
            Err(SandboxError::BadWorkspace { .. })
        ));
    }

    #[test_case(None; "missing_cwd_falls_back_to_current_dir")]
    fn cwd_falls_back_to_current_dir(cwd: Option<&Path>) {
        assert!(workspace_dir(cwd).is_ok());
    }

    struct MissingBackend;

    impl BackendProbe for MissingBackend {
        fn probe(&self) -> Result<(), SandboxError> {
            Err(SandboxError::NoBackend)
        }
    }

    #[test_case("ls"; "missing_backend_refuses_and_leaves_command_intact")]
    fn missing_backend_refuses(program: &str) {
        let mut command = Command::new(program);
        let result = wrap_with(&MissingBackend, &mut command, None);
        assert!(matches!(result, Err(SandboxError::NoBackend)));
        assert_eq!(command.get_program().to_string_lossy(), program);
    }
}
