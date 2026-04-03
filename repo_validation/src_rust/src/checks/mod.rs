// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

pub mod no_tabs;
pub mod file_endings;
pub mod requirements_naming;
pub mod srs_uniqueness;
pub mod enable_mocks;
pub mod no_vld_include;
pub mod no_backticks_in_srs;
pub mod test_spec_tags;
pub mod aaa_comments;
pub mod srs_consistency;

use crate::config::{FileInfo, ValidatorConfig};

pub trait Check {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    fn file_types(&self) -> u32;
    fn requires_devdoc(&self) -> bool;
    fn init(&mut self, config: &ValidatorConfig);
    fn check_file(&mut self, file: &FileInfo, config: &ValidatorConfig);
    /// Returns violation count (0 = passed)
    fn finalize(&mut self, config: &ValidatorConfig) -> i32;
}

pub fn all_checks() -> Vec<Box<dyn Check>> {
    vec![
        Box::new(no_tabs::NoTabs::new()),
        Box::new(file_endings::FileEndings::new()),
        Box::new(requirements_naming::RequirementsNaming::new()),
        Box::new(srs_uniqueness::SrsUniqueness::new()),
        Box::new(enable_mocks::EnableMocks::new()),
        Box::new(no_vld_include::NoVldInclude::new()),
        Box::new(no_backticks_in_srs::NoBackticksInSrs::new()),
        Box::new(test_spec_tags::TestSpecTags::new()),
        Box::new(aaa_comments::AaaComments::new()),
        Box::new(srs_consistency::SrsConsistency::new()),
    ]
}
