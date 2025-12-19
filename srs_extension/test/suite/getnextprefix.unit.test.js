const assert = require('assert');

// You can import and use all API from the 'vscode' module
// as well as import your extension to test it
const vscode = require('vscode');
const reqparser = require('../../reqparser');

const exampleEmpty = "no requirements yet";

const exampleExisting = `
SRS_CODE_REQ_01_001: Blah
SRS_CODE_REQ_01_002: Blah
`;

const exampleExistingMultipleDev = `
SRS_CODE_REQ_01_001: Blah
SRS_CODE_REQ_01_002: Blah
SRS_CODE_REQ_02_004: Blah
SRS_CODE_REQ_02_006: Blah
`;

const exampleExistingMultiplePrefix = `
SRS_CODE_REQ_01_001: Blah
SRS_CODE_REQ_01_002: Blah
SRS_CODE_REQ_02_004: Blah
SRS_CODE_REQ_02_006: Blah
SRS_CODE2_REQ_01_003: Blah
SRS_CODE2_REQ_01_004: Blah
`;


suite('getNextPrefix Unit Test Suite', () => {
    vscode.window.showInformationMessage('Start unit tests.');

    test('Get Next Prefix with no requirements', () => {
        var next = reqparser.getNextReq(exampleEmpty, "SRS_CODE_REQ_", 1);
        assert.equal(next, 'SRS_CODE_REQ_01_001');
    });

    test('Get Next Prefix with existing requirements', () => {
        var next = reqparser.getNextReq(exampleExisting, "SRS_CODE_REQ_", 1);
        assert.equal(next, 'SRS_CODE_REQ_01_003');
    });

    test('Get Next Prefix with existing requirements other devId', () => {
        var next = reqparser.getNextReq(exampleExisting, "SRS_CODE_REQ_", 2);
        assert.equal(next, 'SRS_CODE_REQ_02_001');
    });

    test('Get Next Prefix with existing requirements with multiple dev ids', () => {
        var next = reqparser.getNextReq(exampleExistingMultipleDev, "SRS_CODE_REQ_", 1);
        assert.equal(next, 'SRS_CODE_REQ_01_003');
    });

    test('Get Next Prefix with existing requirements with multiple dev ids (2)', () => {
        var next = reqparser.getNextReq(exampleExistingMultipleDev, "SRS_CODE_REQ_", 2);
        assert.equal(next, 'SRS_CODE_REQ_02_007');
    });

    test('Get Next Prefix with existing requirements with multiple prefixes', () => {
        var next = reqparser.getNextReq(exampleExistingMultiplePrefix, "SRS_CODE_REQ_", 1);
        assert.equal(next, 'SRS_CODE_REQ_01_003');
    });

    test('Get Next Prefix with existing requirements with multiple prefixes', () => {
        var next = reqparser.getNextReq(exampleExistingMultiplePrefix, "SRS_CODE2_REQ_", 1);
        assert.equal(next, 'SRS_CODE2_REQ_01_005');
    });
});
