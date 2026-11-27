//! Persistent storage for anisette state and certificate keys.
//!
//! iOS has no keyring accessible to a plain static library, so we use the
//! filesystem-backed `FsStorage` from isideload (`fs-storage` feature) rooted
//! inside the app's Application Support directory (passed from Swift).

use std::path::{Path, PathBuf};
use rootcause::prelude::*;

/// Newtype wrapper so callers can pass a path without depending on isideload.
#[derive(Debug, Clone)]
pub struct StorageRoot(pub PathBuf);

impl StorageRoot {
    pub fn new(path: impl AsRef<Path>) -> Self {
        Self(path.as_ref().to_path_buf())
    }

    pub fn as_path(&self) -> &Path {
        &self.0
    }

    /// Ensure the directory tree exists.
    pub fn ensure(&self) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.0)
    }

    /// Create an isideload-compatible storage handle rooted at `self`.
    pub fn into_isideload_storage(self) -> impl isideload::util::storage::SideloadingStorage {
        isideload::util::fs_storage::FsStorage::new(self.0)
    }
}

/// Test that storage is writable; returns false on permission errors.
pub fn probe(root: &StorageRoot) -> bool {
    if root.ensure().is_err() {
        return false;
    }
    let probe_file = root.as_path().join(".write_probe");
    match std::fs::write(&probe_file, b"ok") {
        Ok(_) => {
            let _ = std::fs::remove_file(probe_file);
            true
        }
        Err(_) => false,
    }
}
