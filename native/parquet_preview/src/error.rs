use std::fmt;

/// Failures returned to Quick Look. Messages stay short and never echo file bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PreviewError {
    Timeout,
    ByteLimit,
    MemoryLimit,
    PageTooLarge,
    NotParquet,
    NotAFile,
    Io,
    Decode,
}

impl PreviewError {
    pub fn message(self) -> &'static str {
        match self {
            Self::Timeout => "row preview timed out",
            Self::ByteLimit => "row preview exceeded the byte limit",
            Self::MemoryLimit => "row preview exceeded the memory limit",
            Self::PageTooLarge => "row preview rejected an oversized page",
            Self::NotParquet => "not a parquet file",
            Self::NotAFile => "not a regular file",
            Self::Io => "could not read the file",
            Self::Decode => "row preview could not decode this file",
        }
    }
}

impl fmt::Display for PreviewError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.message())
    }
}

#[cfg(test)]
mod tests {
    use super::PreviewError;

    #[test]
    fn every_failure_has_a_short_message() {
        let samples = [
            PreviewError::Timeout,
            PreviewError::ByteLimit,
            PreviewError::MemoryLimit,
            PreviewError::PageTooLarge,
            PreviewError::NotParquet,
            PreviewError::NotAFile,
            PreviewError::Io,
            PreviewError::Decode,
        ];
        for error in samples {
            let text = error.to_string();
            assert_eq!(text, error.message());
            assert!(!text.is_empty());
        }
    }
}
