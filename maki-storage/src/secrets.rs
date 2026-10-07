//! Protected secret store and conversational auth flows.
//!
//! Settings may reference secrets by name (`ref:<name>`); the value lives in
//! the OS keychain when one is reachable, otherwise in a 0600 file under the
//! state dir. Providers that need an interactive login register an
//! [`AuthFlow`], mirroring the OAuth flow MCP already uses.

use thiserror::Error;

use crate::StateDir;
use crate::auth::{self, ProviderCredentials, REF_PREFIX};

const KEYRING_SERVICE: &str = "maki";

#[derive(Debug, Error)]
pub enum SecretError {
    #[error("secret {0:?} not found")]
    NotFound(String),
    #[error("keychain unavailable: {0}")]
    Keychain(String),
    #[error("storage failure: {0}")]
    Storage(#[from] StorageFailure),
}

#[derive(Debug, Error)]
pub enum StorageFailure {
    #[error(transparent)]
    Storage(#[from] crate::StorageError),
    #[error("keychain write failed: {0}")]
    Keychain(String),
}

pub trait SecretStore: Send + Sync {
    fn set(&self, name: &str, value: &str) -> Result<(), StorageFailure>;
    fn get(&self, name: &str) -> Result<String, SecretError>;
    fn delete(&self, name: &str) -> Result<bool, StorageFailure>;
}

/// OS keychain via `keyring`; a maintained crate is already in the workspace.
pub struct KeychainStore;

impl SecretStore for KeychainStore {
    fn set(&self, name: &str, value: &str) -> Result<(), StorageFailure> {
        entry(name)
            .and_then(|entry| entry.set_password(value).map_err(|e| e.to_string()))
            .map_err(StorageFailure::Keychain)
    }

    fn get(&self, name: &str) -> Result<String, SecretError> {
        let value = entry(name)
            .and_then(|entry| entry.get_password().map_err(|e| e.to_string()))
            .map_err(|e| {
                if e.contains("no matching entry") {
                    SecretError::NotFound(name.to_string())
                } else {
                    SecretError::Keychain(e)
                }
            })?;
        Ok(value)
    }

    fn delete(&self, name: &str) -> Result<bool, StorageFailure> {
        entry(name)
            .and_then(|entry| entry.delete_credential().map_err(|e| e.to_string()))
            .map(|_| true)
            .map_err(StorageFailure::Keychain)
    }
}

fn entry(name: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new(KEYRING_SERVICE, name).map_err(|e| e.to_string())
}

/// 0600 file fallback: the existing secrets file under the auth dir.
pub struct FileSecretStore<'a> {
    dir: &'a StateDir,
}

impl SecretStore for FileSecretStore<'_> {
    fn set(&self, name: &str, value: &str) -> Result<(), StorageFailure> {
        auth::save_secret(self.dir, name, value).map_err(StorageFailure::Storage)
    }

    fn get(&self, name: &str) -> Result<String, SecretError> {
        auth::load_secret(self.dir, name).ok_or_else(|| SecretError::NotFound(name.to_string()))
    }

    fn delete(&self, name: &str) -> Result<bool, StorageFailure> {
        auth::delete_secret(self.dir, name).map_err(StorageFailure::Storage)
    }
}

/// Keychain first, file fallback: reads try both, writes fall back whenever
/// the keychain rejects them.
pub struct ProtectedStore<'a> {
    dir: &'a StateDir,
}

impl<'a> ProtectedStore<'a> {
    pub fn new(dir: &'a StateDir) -> Self {
        Self { dir }
    }

    fn file(&self) -> FileSecretStore<'a> {
        FileSecretStore { dir: self.dir }
    }

    pub fn set(&self, name: &str, value: &str) -> Result<(), StorageFailure> {
        if KeychainStore.set(name, value).is_ok() {
            return Ok(());
        }
        self.file().set(name, value)
    }

    pub fn get(&self, name: &str) -> Result<String, SecretError> {
        match KeychainStore.get(name) {
            Ok(value) => Ok(value),
            Err(SecretError::NotFound(_)) | Err(SecretError::Keychain(_)) => self.file().get(name),
            Err(err @ SecretError::Storage(_)) => Err(err),
        }
    }

    pub fn delete(&self, name: &str) -> Result<bool, StorageFailure> {
        let from_keychain = KeychainStore.delete(name).unwrap_or(false);
        let from_file = self.file().delete(name)?;
        Ok(from_keychain || from_file)
    }

    /// A credential value as written in settings: `ref:<name>` resolves from
    /// the protected store, anything else is the literal value.
    pub fn resolve(&self, value: &str) -> Result<String, SecretError> {
        match value.strip_prefix(REF_PREFIX) {
            Some(name) => self.get(name),
            None => Ok(value.to_string()),
        }
    }
}

#[derive(Debug, Error)]
pub enum AuthFlowError {
    #[error("no auth flow registered for {0:?}")]
    UnknownProvider(String),
    #[error("auth flow for {0:?} failed: {1}")]
    Flow(String, String),
}

/// Interactive login for a provider, in the shape of the MCP OAuth flow: the
/// implementation runs its own prompt/browser/token exchange and returns the
/// credentials to persist.
pub trait AuthFlow: Send + Sync {
    fn slug(&self) -> &'static str;

    fn run(
        &self,
        dir: &StateDir,
        store: &ProtectedStore<'_>,
    ) -> Result<ProviderCredentials, AuthFlowError>;
}

#[derive(Default)]
pub struct AuthFlowRegistry {
    flows: Vec<Box<dyn AuthFlow>>,
}

impl AuthFlowRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, flow: Box<dyn AuthFlow>) {
        self.flows.push(flow);
    }

    pub fn run(&self, slug: &str, dir: &StateDir) -> Result<ProviderCredentials, AuthFlowError> {
        let store = ProtectedStore::new(dir);
        for flow in &self.flows {
            if flow.slug() == slug {
                return flow.run(dir, &store);
            }
        }
        Err(AuthFlowError::UnknownProvider(slug.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::StateDir;
    use crate::auth::{ProviderCredentials, save_secret};
    use tempfile::TempDir;

    const SECRET_NAME: &str = "openai-key";
    const SECRET_VALUE: &str = "sk-live";
    const REF_VALUE: &str = "ref:openai-key";
    const MISSING_NAME: &str = "nope";
    const PROVIDER_SLUG: &str = "acme";

    struct AcmeFlow;

    impl AuthFlow for AcmeFlow {
        fn slug(&self) -> &'static str {
            PROVIDER_SLUG
        }

        fn run(
            &self,
            _dir: &StateDir,
            _store: &ProtectedStore<'_>,
        ) -> Result<ProviderCredentials, AuthFlowError> {
            Ok(ProviderCredentials {
                api_key: SECRET_VALUE.to_string(),
                host: None,
            })
        }
    }

    fn state_dir() -> (TempDir, StateDir) {
        let tmp = TempDir::new().unwrap();
        let dir = StateDir::from_path(tmp.path().to_path_buf());
        (tmp, dir)
    }

    #[test]
    fn protected_store_falls_back_to_file() {
        let (_tmp, dir) = state_dir();
        let store = ProtectedStore::new(&dir);
        store.set(SECRET_NAME, SECRET_VALUE).unwrap();
        assert_eq!(store.get(SECRET_NAME).unwrap(), SECRET_VALUE);
        assert!(store.delete(SECRET_NAME).unwrap());
        assert!(matches!(
            store.get(SECRET_NAME),
            Err(SecretError::NotFound(name)) if name == SECRET_NAME
        ));
    }

    #[test]
    fn resolve_ref_and_literal() {
        let (_tmp, dir) = state_dir();
        save_secret(&dir, SECRET_NAME, SECRET_VALUE).unwrap();
        let store = ProtectedStore::new(&dir);
        assert_eq!(store.resolve(REF_VALUE).unwrap(), SECRET_VALUE);
        assert_eq!(store.resolve(SECRET_VALUE).unwrap(), SECRET_VALUE);
        assert!(matches!(
            store.resolve(&format!("ref:{MISSING_NAME}")),
            Err(SecretError::NotFound(name)) if name == MISSING_NAME
        ));
    }

    #[test]
    fn auth_flow_registry_dispatches_by_slug() {
        let (_tmp, dir) = state_dir();
        let mut registry = AuthFlowRegistry::new();
        registry.register(Box::new(AcmeFlow));
        let creds = registry.run(PROVIDER_SLUG, &dir).unwrap();
        assert_eq!(creds.api_key, SECRET_VALUE);
        assert!(matches!(
            registry.run(MISSING_NAME, &dir),
            Err(AuthFlowError::UnknownProvider(slug)) if slug == MISSING_NAME
        ));
    }

    #[test]
    fn file_store_reads_back_what_it_wrote() {
        let (_tmp, dir) = state_dir();
        let store = FileSecretStore { dir: &dir };
        store.set(SECRET_NAME, SECRET_VALUE).unwrap();
        assert_eq!(store.get(SECRET_NAME).unwrap(), SECRET_VALUE);
        assert!(store.delete(SECRET_NAME).unwrap());
        assert!(matches!(
            store.get(SECRET_NAME),
            Err(SecretError::NotFound(name)) if name == SECRET_NAME
        ));
    }
}
