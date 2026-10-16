//! The two forms a path takes in the language server.
//!
//! The platform's form is the file system's own: `C:\Users\x` on Windows, `/Users/x` on Unix.
//! It is what `DocumentUri::path` holds, what the compiler and the sandbox work in and what a
//! module folder is joined from.
//!
//! The URI form is what a `file://` URI holds: `/`-separated, and on Windows the drive is a
//! leading component, so `file:///c%3A/Users/x` is `/c:/Users/x`. Only the client speaks it: a
//! request's URI becomes a path at [`DocumentUri::parse`](crate::DocumentUri) and a path becomes
//! the URI of a location or a Markdown link here.
use std::path::Path;

/// The platform's form of a path in the URI form (`/c:/Users/x` as `C:\Users\x` on Windows).
/// A path already in the platform's form (the standard library's install directory, say) comes
/// back unchanged, so the two can be told apart by their text.
pub fn to_platform(path: &str) -> String {
    if !cfg!(windows) {
        return path.to_string();
    }
    let Some(rest) = path.strip_prefix('/') else {
        return path.to_string();
    };
    let bytes = rest.as_bytes();
    if bytes.len() < 2 || !bytes[0].is_ascii_alphabetic() || bytes[1] != b':' {
        // `/tmp/x`: Windows reads that as the root of the current drive already.
        return path.to_string();
    }
    let mut out = String::with_capacity(path.len());
    out.push(bytes[0].to_ascii_uppercase() as char);
    out.push(':');
    out.push_str(&rest[2..].replace('/', "\\"));
    out
}

/// The URI form of a platform path (`C:\Users\x` as `/c:/Users/x` on Windows). A path that is
/// not a file the editor can open (a relative path, the label of an `#import,string`) has no URI
/// form and comes back unchanged, so a caller can tell it apart.
pub fn to_uri(path: &str) -> String {
    if !cfg!(windows) {
        return path.to_string();
    }
    if let Some(rest) = path.strip_prefix('/') {
        // Already the URI form: the only difference `Path::join` makes is the separator
        // (`/c:/dir\file.jai`), and `\` is a separator on Windows either way.
        return format!("/{}", rest.replace('\\', "/"));
    }
    // `std::fs::canonicalize` writes a Windows path verbatim (`\\?\C:\...`), which names the
    // same file as the plain form an editor's URI holds.
    let text = jaic::strip_verbatim(path).unwrap_or_else(|| path.to_string());
    let (drive, rest) = match text.as_bytes() {
        [letter, b':', ..] if letter.is_ascii_alphabetic() => (Some(*letter), &text[2..]),
        // `\Users\x` is the root of the current drive; anything else (a relative path, a UNC
        // share) has no URI form.
        _ => match text.strip_prefix('\\') {
            Some(rest) => (None, rest),
            None => return path.to_string(),
        },
    };
    let mut out = String::with_capacity(text.len() + 2);
    out.push('/');
    if let Some(letter) = drive {
        out.push(letter.to_ascii_lowercase() as char);
        out.push(':');
    }
    out.push_str(&rest.replace('\\', "/"));
    out
}

/// [`to_uri`] with a `Path` argument.
pub fn uri_path(path: &Path) -> String {
    to_uri(&path.to_string_lossy())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Converted both ways, a path the editor sends is the same file again.
    #[test]
    fn windows_paths_round_trip() {
        if !cfg!(windows) {
            return;
        }
        assert_eq!(to_platform("/c:/Users/x/main.jai"), r"C:\Users\x\main.jai");
        assert_eq!(to_uri(r"C:\Users\x\main.jai"), "/c:/Users/x/main.jai");
        // The separator `Path::join` writes and the verbatim prefix `canonicalize` writes name
        // the same file as the URI form.
        assert_eq!(to_uri("/c:/Users/x\\main.jai"), "/c:/Users/x/main.jai");
        assert_eq!(to_uri(r"\\?\C:\Users\x\main.jai"), "/c:/Users/x/main.jai");
        assert_eq!(to_platform("/c:/Users/x\\main.jai"), r"C:\Users\x\main.jai");
        // The root of the current drive, which `NativeFs::canonical` makes of a `/`-rooted
        // path, is still the same file as its URI form.
        assert_eq!(to_uri(r"\Users\x\main.jai"), "/Users/x/main.jai");
        // Already in the URI form (or the platform's): nothing to convert.
        assert_eq!(to_platform(r"C:\Users\x\main.jai"), r"C:\Users\x\main.jai");
        assert_eq!(to_uri("/c:/Users/x/main.jai"), "/c:/Users/x/main.jai");
        assert_eq!(to_platform("/tmp/x"), "/tmp/x");
        // Not a file the editor can open: unchanged, so a caller can tell.
        assert_eq!(to_uri("<added string 1>"), "<added string 1>");
        assert_eq!(to_uri("../relative.jai"), "../relative.jai");
    }

    /// On Unix the two forms are the same path, so nothing is converted.
    #[test]
    fn unix_paths_are_their_own_uri_form() {
        if cfg!(windows) {
            return;
        }
        assert_eq!(to_platform("/Users/x/main.jai"), "/Users/x/main.jai");
        assert_eq!(to_uri("/Users/x/main.jai"), "/Users/x/main.jai");
    }
}
