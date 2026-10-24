use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::sync::Arc;

use bytes::Bytes;
use parquet::errors::{ParquetError, Result};
use parquet::file::reader::{ChunkReader, Length};

use crate::budget::Budget;
use crate::error::PreviewError;

/// File reader that refuses reads past the byte, time, and cancellation caps.
pub struct CappedFile {
    file: File,
    len: u64,
    budget: Arc<Budget>,
}

impl CappedFile {
    pub fn new(file: File, len: u64, budget: Arc<Budget>) -> Self {
        Self { file, len, budget }
    }

    pub fn byte_len(&self) -> u64 {
        self.len
    }

    fn map_budget(error: PreviewError) -> ParquetError {
        ParquetError::General(error.message().to_string())
    }

    fn prepare(&self, length: usize) -> Result<()> {
        let len = length as u64;
        self.budget
            .try_reserve(len)
            .map_err(Self::map_budget)?;
        Ok(())
    }
}

impl Length for CappedFile {
    fn len(&self) -> u64 {
        self.len
    }
}

impl ChunkReader for CappedFile {
    type T = BudgetRead<File>;

    fn get_read(&self, start: u64) -> Result<Self::T> {
        if self.budget.expired() {
            return Err(Self::map_budget(PreviewError::Timeout));
        }
        if start > self.len {
            return Err(ParquetError::General("read past end of file".to_string()));
        }
        let mut reader = self
            .file
            .try_clone()
            .map_err(|_| ParquetError::General("could not read the file".to_string()))?;
        reader
            .seek(SeekFrom::Start(start))
            .map_err(|_| ParquetError::General("could not read the file".to_string()))?;
        Ok(BudgetRead {
            inner: reader,
            budget: Arc::clone(&self.budget),
        })
    }

    fn get_bytes(&self, start: u64, length: usize) -> Result<Bytes> {
        self.prepare(length)?;
        if start.saturating_add(length as u64) > self.len {
            return Err(ParquetError::General("read past end of file".to_string()));
        }
        let mut reader = self
            .file
            .try_clone()
            .map_err(|_| ParquetError::General("could not read the file".to_string()))?;
        reader
            .seek(SeekFrom::Start(start))
            .map_err(|_| ParquetError::General("could not read the file".to_string()))?;
        let mut buffer = vec![0u8; length];
        reader
            .read_exact(&mut buffer)
            .map_err(|_| ParquetError::General("could not read the file".to_string()))?;
        Ok(buffer.into())
    }
}

pub struct BudgetRead<R> {
    inner: R,
    budget: Arc<Budget>,
}

impl<R: Read> Read for BudgetRead<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        if self.budget.expired() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                PreviewError::Timeout.message(),
            ));
        }
        let allowed = self.budget.remaining();
        if allowed == 0 {
            self.budget.fail(PreviewError::ByteLimit);
            return Err(io::Error::new(
                io::ErrorKind::QuotaExceeded,
                PreviewError::ByteLimit.message(),
            ));
        }
        let max = buf.len().min(usize::try_from(allowed).unwrap_or(usize::MAX));
        let n = self.inner.read(&mut buf[..max])?;
        self.budget.try_reserve(n as u64).map_err(|error| {
            io::Error::new(io::ErrorKind::QuotaExceeded, error.message())
        })?;
        Ok(n)
    }
}
