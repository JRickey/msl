//! Path-component validation. A lookup name is one component resolved under a
//! parent fd, so it must never contain NUL or `/` and must not be a traversal
//! (`.` or `..`); anything else is rejected before it reaches `openat`.

/// True when `name` is a safe single path component to resolve under a parent.
#[must_use]
pub fn is_valid_component(name: &str) -> bool {
    if name.is_empty() || name.len() > 255 {
        return false;
    }
    if name == "." || name == ".." {
        return false;
    }
    !name.bytes().any(|byte| byte == 0 || byte == b'/')
}

#[cfg(test)]
mod tests {
    use super::is_valid_component;

    #[test]
    fn accepts_ordinary_names() {
        for name in ["etc", "os-release", "a", ".hidden", "with space", "名前"] {
            assert!(is_valid_component(name), "{name}");
        }
    }

    #[test]
    fn rejects_traversal_and_separators() {
        for name in ["", ".", "..", "a/b", "/", "with\0nul"] {
            assert!(!is_valid_component(name), "{name:?}");
        }
    }

    #[test]
    fn rejects_overlong() {
        assert!(!is_valid_component(&"x".repeat(256)));
        assert!(is_valid_component(&"x".repeat(255)));
    }
}
