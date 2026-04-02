// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

/// File type classification bitmask
pub const FILE_TYPE_C: u32 = 0x0001;
pub const FILE_TYPE_H: u32 = 0x0002;
pub const FILE_TYPE_CPP: u32 = 0x0004;
pub const FILE_TYPE_HPP: u32 = 0x0008;
pub const FILE_TYPE_CS: u32 = 0x0010;
pub const FILE_TYPE_MD: u32 = 0x0020;
pub const FILE_TYPE_TXT: u32 = 0x0040;

/// File location flags
pub const FILE_FLAG_IN_DEVDOC: u32 = 0x0100;
pub const FILE_FLAG_IS_UT: u32 = 0x0200;

pub struct FileInfo {
    pub path: String,
    pub relative_path: String,
    pub type_flags: u32,
    pub content: Vec<u8>,
}

pub struct ValidatorConfig {
    pub repo_root: String,
    pub exclude_folders: Vec<String>,
    pub fix_mode: bool,
}
