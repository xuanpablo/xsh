//! Content hashing, exposed as `maki.hash`. Used by tools that guard against
//! editing a file that changed since it was last read.

use maki_lua_macro::{lua_fn, lua_table};
use mlua::{Lua, Result as LuaResult, Value as LuaValue};
use sha2::{Digest, Sha256};

use crate::api::base64::bytes_arg;

/// 128 bits is collision-proof for change detection, and half the tokens of
/// the full digest when the model has to echo the hash back.
const HASH_BYTES: usize = 16;

/// SHA-256 of {data} as lowercase hex, truncated to 32 characters.
/// Accepts both strings and Luau buffers.
///
/// @param data string|buffer Data to hash.
/// @return (string) Hex digest.
/// @example
/// maki.hash.sha256("hello")
#[lua_fn]
fn sha256(_lua: &Lua, data: LuaValue) -> LuaResult<String> {
    let bytes = bytes_arg(&data, "hash.sha256")?;
    let digest = Sha256::digest(bytes);
    Ok(digest[..HASH_BYTES]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

lua_table! {
    /// Content hashing. Digests are short enough for a model to pass back as
    /// `expected_content_hash` on write and edit tools.
    ///
    /// ```lua
    /// maki.hash.sha256("hello")
    /// ```
    "maki.hash" => pub(crate) fn create_hash_table(), DOCS [
        sha256,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    const HELLO_SHA256_PREFIX: &str = "2cf24dba5fb0a30e26e83b2ac5b9e29e";

    #[test]
    fn sha256_matches_known_vector_truncated() {
        let lua = Lua::new();
        let t = create_hash_table(&lua).unwrap();
        let f: mlua::Function = t.get("sha256").unwrap();
        assert_eq!(f.call::<String>("hello").unwrap(), HELLO_SHA256_PREFIX);
    }

    #[test]
    fn sha256_accepts_buffers() {
        let lua = Lua::new();
        let t = create_hash_table(&lua).unwrap();
        let f: mlua::Function = t.get("sha256").unwrap();
        let buf = lua.create_buffer(b"hello").unwrap();
        assert_eq!(f.call::<String>(buf).unwrap(), HELLO_SHA256_PREFIX);
    }
}
