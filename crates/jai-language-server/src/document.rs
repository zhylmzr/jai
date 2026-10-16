use crate::{Error, Range};
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct DocumentUri {
    uri: String,
    path: String,
}

impl DocumentUri {
    pub fn parse(uri: &str) -> Result<Self, Error> {
        if uri.len() > 4096 {
            return Err(Error::Limit("document URI exceeds 4096 bytes"));
        }
        let encoded = uri
            .strip_prefix("file://")
            .ok_or(Error::Uri("only absolute local file URIs are supported"))?;
        if !encoded.starts_with('/') || encoded.contains(['?', '#', '\0']) {
            return Err(Error::Uri(
                "file URI must have no authority, query or fragment",
            ));
        }
        let mut bytes = Vec::with_capacity(encoded.len());
        let input = encoded.as_bytes();
        let mut at = 0;
        while at < input.len() {
            if input[at] == b'%' {
                let value = input
                    .get(at + 1..at + 3)
                    .ok_or(Error::Uri("incomplete URI escape"))?;
                let high = hex(value[0]).ok_or(Error::Uri("invalid URI escape"))?;
                let low = hex(value[1]).ok_or(Error::Uri("invalid URI escape"))?;
                bytes.push(high * 16 + low);
                at += 3;
            } else {
                bytes.push(input[at]);
                at += 1;
            }
        }
        let decoded = String::from_utf8(bytes).map_err(|_| Error::Uri("URI path is not UTF-8"))?;
        Self::from_uri_path(&decoded)
    }

    /// The document of a path in the URI's own spelling, decoded and without the `file://`
    /// prefix, which is what [`Self::parse`] and [`Self::from_path`] both end with.
    fn from_uri_path(decoded: &str) -> Result<Self, Error> {
        let path = lowercase_drive(normalize(decoded)?);
        let uri = format!("file://{}", encode(&path));
        if uri.len() > 4096 {
            return Err(Error::Limit("canonical document URI exceeds 4096 bytes"));
        }
        Ok(Self {
            uri,
            path: crate::paths::to_platform(&path),
        })
    }

    /// The document of a file a compile reported: a module, standard library or `#load`ed file
    /// the editor may not have open (`C:\Users\...\Print.jai` as the platform names it, or the
    /// URI form). `None` for a name that is not a file, such as the label of an `#import,string`
    /// or a file of a `#load,string`.
    pub fn from_path(path: &str) -> Option<Self> {
        Self::from_uri_path(&crate::paths::to_uri(path)).ok()
    }

    pub fn as_str(&self) -> &str {
        &self.uri
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    pub(crate) fn load(&self, target: &str) -> Result<Self, Error> {
        if target.contains(['\\', '\0', ':']) || target.len() > 4096 {
            return Err(Error::Uri("unsupported #load target"));
        }
        let joined = if target.starts_with('/') {
            target.to_owned()
        } else {
            let parent = std::path::Path::new(&self.path)
                .parent()
                .ok_or(Error::Uri("document path has no folder"))?;
            format!("{}/{}", crate::paths::uri_path(parent), target)
        };
        Self::from_uri_path(&joined)
    }
}

fn hex(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

fn encode(path: &str) -> String {
    let mut out = String::new();
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || b"/-._~:".contains(&byte) {
            out.push(byte as char);
        } else {
            use std::fmt::Write;
            let _ = write!(out, "%{byte:02X}");
        }
    }
    out
}

/// `/C:/Users/x` as `/c:/Users/x`: a `file://` URI writes a drive letter in lower case, and
/// `from_path` does too, so the URI of a file is the same value whichever way it was reached.
fn lowercase_drive(path: String) -> String {
    let bytes = path.as_bytes();
    let drive = bytes.len() > 2
        && bytes[0] == b'/'
        && bytes[1].is_ascii_uppercase()
        && bytes[2] == b':'
        && (bytes.len() == 3 || bytes[3] == b'/');
    if drive {
        let mut out = String::with_capacity(path.len());
        out.push('/');
        out.push((bytes[1] as char).to_ascii_lowercase());
        out.push_str(&path[2..]);
        out
    } else {
        path
    }
}

fn normalize(path: &str) -> Result<String, Error> {
    if !path.starts_with('/') || path.contains(['\\', '\0']) {
        return Err(Error::Uri(
            "document path must be absolute and contain no backslash or NUL",
        ));
    }
    let mut parts = vec![];
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.pop().is_none() {
                    return Err(Error::Uri("document path escapes its root"));
                }
            }
            value => parts.push(value),
        }
    }
    if parts.is_empty() {
        return Err(Error::Uri("document URI names a root"));
    }
    Ok(format!("/{}", parts.join("/")))
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextChange {
    pub range: Option<Range>,
    pub range_length: Option<u32>,
    pub text: String,
}

/// A closed immutable snapshot of the open documents. It never consults an OS filesystem.
#[derive(Clone, Debug, Default)]
pub struct VirtualSources {
    pub(crate) files: BTreeMap<String, String>,
}

impl VirtualSources {
    /// Text of an open document by absolute path (either form); unopened or escaping paths are
    /// `None`. The entries are keyed by the URI's spelling of the path, so a platform path is
    /// converted before the lookup.
    pub fn read(&self, path: &str) -> Option<&str> {
        let path = normalize(&crate::paths::to_uri(path)).ok()?;
        self.files.get(&path).map(String::as_str)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_and_its_uri_name_the_same_document() {
        let uri = DocumentUri::parse("file:///lsp/one.jai").unwrap();
        assert_eq!(DocumentUri::from_path(uri.path()), Some(uri));
        // A `file://` URI writes a drive letter in lower case.
        assert_eq!(
            DocumentUri::parse("file:///C%3A/Users/x/main.jai").unwrap(),
            DocumentUri::parse("file:///c%3A/Users/x/main.jai").unwrap()
        );
    }

    /// A compile reports the platform's own path (`C:\Users\...`), which names the document
    /// the editor opened from `file:///c%3A/Users/...`.
    #[test]
    fn a_platform_path_is_the_editor_s_uri() {
        if !cfg!(windows) {
            return;
        }
        let opened = DocumentUri::parse("file:///c%3A/Users/x/main.jai").unwrap();
        // `path` is the platform's form of the file, what the compiler and the file system get.
        assert_eq!(opened.path(), r"C:\Users\x\main.jai");
        let reported = DocumentUri::from_path(r"C:\Users\x\main.jai").unwrap();
        assert_eq!(reported, opened);
        assert_eq!(reported.as_str(), "file:///c:/Users/x/main.jai");
        // The label of an `#import,string` names no file the editor can open.
        assert_eq!(DocumentUri::from_path("<added string 1>"), None);
    }
}
