const assert = require('assert');

// You can import and use all API from the 'vscode' module
// as well as import your extension to test it
const vscode = require('vscode');
const reqparser = require('../../reqparser');

const example1 = "SRS_CODE_REQ_99_001";

const example2 = `
SRS_CODE_REQ_99_001
SRS_CODE_REQ_99_002
SRS_CODE_REQ_99_003
SRS_CODE_REQ_99_004 blah blah blah
`;

const exampleWithNumbers = `
SRS_2_CODE_2_FURIOUS_01_001
`;

const exampleInvalidFormats = `
Some text here
This is not an SRS_PREFIX
SRS_CODE_REQ_999_001:
SRS_CODE_REQ_9_002:
SRS_CODE_REQ_99_03
SRS_CODE_REQ_99_A03
srs_code_req_99_004
`;

const exampleMultiple = `
SRS_CODE_REQ_16_001 [line 1]
SRS_CODE_REQ_16_002 [line 2]
SRS_CODE_REQ_16_003 [line 3]
SRS_CODE_OTHERREQ_16_005 [line 4]
SRS_CODE_OTHERREQ_07_001 [line 5]
SRS_CODE_REQ_07_003 [line 6]
SRS_CODE_REQ_07_002 [line 7]
SRS_CODE_OTHERREQ_07_002 [line 8]
SRS_CODE_OTHERREQ2_16_001 [line 4]
SRS_CODE_OTHERREQ2_07_001 [line 5]
SRS_1_07_001 [line 5]
`;

suite('getPrefixes Unit Test Suite', () => {
    vscode.window.showInformationMessage('Start unit tests.');

    test('Get Prefixes with one prefix only', () => {
        var prefixes = reqparser.getPrefixes(example1);
        assert.equal(prefixes.length, 1);
        assert.equal(prefixes[0], 'SRS_CODE_REQ_');
    });

    test('Get Prefixes with one prefix multiple uses', () => {
        var prefixes = reqparser.getPrefixes(example2);
        assert.equal(prefixes.length, 1);
        assert.equal(prefixes[0], 'SRS_CODE_REQ_');
    });

    test('Get Prefixes with numbers', () => {
        var prefixes = reqparser.getPrefixes(exampleWithNumbers);
        assert.equal(prefixes.length, 1);
        assert.equal(prefixes[0], 'SRS_2_CODE_2_FURIOUS_');
    });

    test('Get Prefixes with invalid prefixes only', () => {
        var prefixes = reqparser.getPrefixes(exampleInvalidFormats);
        assert.equal(prefixes.length, 0);
    });

    test('Get Prefixes with multiple prefixes', () => {
        var prefixes = reqparser.getPrefixes(exampleMultiple);
        assert.equal(prefixes.length, 4);
        assert.ok(prefixes.indexOf('SRS_CODE_REQ_') > -1);
        assert.ok(prefixes.indexOf('SRS_CODE_OTHERREQ_') > -1);
        assert.ok(prefixes.indexOf('SRS_CODE_OTHERREQ2_') > -1);
        assert.ok(prefixes.indexOf('SRS_1_') > -1);
    });
});
