use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::error::PreviewError;

/// Shared read/time budget checked on every byte the decoder pulls from disk.
#[derive(Debug)]
pub struct Budget {
    max_bytes: u64,
    read: AtomicU64,
    deadline: Instant,
    cancel: Arc<AtomicBool>,
    reason: Mutex<Option<PreviewError>>,
}

impl Budget {
    pub fn new(max_bytes: u64, deadline: Instant, cancel: Arc<AtomicBool>) -> Arc<Self> {
        Arc::new(Self {
            max_bytes,
            read: AtomicU64::new(0),
            deadline,
            cancel,
            reason: Mutex::new(None),
        })
    }

    pub fn take_reason(&self) -> Option<PreviewError> {
        self.reason.lock().ok().and_then(|mut guard| guard.take())
    }

    pub fn fail(&self, error: PreviewError) {
        if let Ok(mut guard) = self.reason.lock() {
            if guard.is_none() {
                *guard = Some(error);
            }
        }
    }

    pub fn expired(&self) -> bool {
        if self.cancel.load(Ordering::Relaxed) {
            self.fail(PreviewError::Timeout);
            return true;
        }
        if Instant::now() >= self.deadline {
            self.fail(PreviewError::Timeout);
            return true;
        }
        false
    }

    pub fn remaining(&self) -> u64 {
        self.max_bytes.saturating_sub(self.read.load(Ordering::Relaxed))
    }

    /// Reserve `len` bytes against the cap. Fails closed before the caller allocates.
    pub fn try_reserve(&self, len: u64) -> Result<(), PreviewError> {
        if self.expired() {
            return Err(PreviewError::Timeout);
        }
        if len > self.max_bytes {
            self.fail(PreviewError::ByteLimit);
            return Err(PreviewError::ByteLimit);
        }
        let mut current = self.read.load(Ordering::Relaxed);
        loop {
            let next = current.saturating_add(len);
            if next > self.max_bytes {
                self.fail(PreviewError::ByteLimit);
                return Err(PreviewError::ByteLimit);
            }
            match self.read.compare_exchange_weak(
                current,
                next,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => return Ok(()),
                Err(observed) => current = observed,
            }
        }
    }
}
