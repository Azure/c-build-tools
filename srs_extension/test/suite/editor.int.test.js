const assert = require('assert');

// You can import and use all API from the 'vscode' module
// as well as import your extension to test it
const vscode = require('vscode');
const crypto = require('crypto');
const MemFS = require('../memfs');

const extension = require('../../extension');

// Test code based on https://github.com/microsoft/vscode/tree/master/extensions/vscode-api-tests/src/singlefolder-tests

function rndName() {
    return crypto.randomBytes(8).toString('hex');
}

const testFs = new MemFS.MemFS('fake-fs');
vscode.workspace.registerFileSystemProvider(testFs.scheme, testFs);

async function createRandomFile(contents = '', dir = undefined, ext = '') {
    var fakeFile;
    if (dir) {
        assert.equal(dir.scheme, testFs.scheme);
        fakeFile = dir.with({ path: dir.path + '/' + rndName() + ext });
    } else {
        fakeFile = vscode.Uri.parse(`${testFs.scheme}:/${rndName() + ext}`);
    }
    await testFs.writeFile(fakeFile, Buffer.from(contents), { create: true, overwrite: true });
    return fakeFile;
}

async function deleteFile(file) {
    try {
        await testFs.delete(file);
        return true;
    } catch {
        return false;
    }
}

function closeAllEditors() {
    return vscode.commands.executeCommand('workbench.action.closeAllEditors');
}


const sampleFileBefore = `
# A File header

This is my spec:
   
do something

do something else

do a third thing
`;

const sampleFileAfterOneSpec = `
# A File header

This is my spec:
   
**SRS_MY_PREFIX_08_001: [** do something **]**

do something else

do a third thing
`;

const sampleFileAfter = `
# A File header

This is my spec:
   
**SRS_MY_PREFIX_08_001: [** do something **]**

**SRS_MY_PREFIX_08_002: [** do something else **]**

**SRS_MY_PREFIX_08_003: [** do a third thing **]**
`;

const sampleFileWithExistingBefore = `
# A File header

**SRS_MY_PREFIX_08_142: [** This is my spec: **]**

do something

do something else

do a third thing
`;

const sampleFileWithExistingAfterOneSpec = `
# A File header

**SRS_MY_PREFIX_08_142: [** This is my spec: **]**

do something

**SRS_MY_PREFIX_08_143: [** do something else **]**

do a third thing
`;

const sampleFileWithExistingAfter = `
# A File header

**SRS_MY_PREFIX_08_142: [** This is my spec: **]**

**SRS_MY_PREFIX_08_143: [** do something **]**

**SRS_MY_PREFIX_08_144: [** do something else **]**

**SRS_MY_PREFIX_08_145: [** do a third thing **]**
`;

const otherSampleFile = `## hello world


This file has white space



done.`;

const sampleFileBeforeWithLists = `
# A File header

Do many things:
   
 - do something

 - do something else

   - sublist item

Last one
`;

const sampleFileAfterWithLists = `
# A File header

**SRS_MY_PREFIX_08_001: [** Do many things: **]**
   
 - **SRS_MY_PREFIX_08_002: [** do something **]**

 - **SRS_MY_PREFIX_08_003: [** do something else **]**

   - **SRS_MY_PREFIX_08_004: [** sublist item **]**

**SRS_MY_PREFIX_08_005: [** Last one **]**
`;

suite('Editor Int Test Suite', () => {
    vscode.window.showInformationMessage('Start editor int tests.');

    teardown(closeAllEditors);

    function withRandomFileEditor(initialContents, run) {
        return createRandomFile(initialContents, undefined, '.md').then(file => {
            return vscode.workspace.openTextDocument(file).then(doc => {
                return vscode.window.showTextDocument(doc).then((editor) => {
                    return run(editor, doc).then(_ => {
                        if (doc.isDirty) {
                            return doc.save().then(saved => {
                                assert.ok(saved);
                                assert.ok(!doc.isDirty);
                                return deleteFile(file);
                            });
                        } else {
                            return deleteFile(file);
                        }
                    });
                });
            });
        });
    }

    test('Tag one requirement', (done) => {
        withRandomFileEditor(sampleFileBefore, (editor, doc) => {
            editor.selection = new vscode.Selection(
                new vscode.Position(5, 0),
                new vscode.Position(5, 12)
            );

            return vscode.commands.executeCommand("extension.forceSetDevId", "8").then(_ => {
                return vscode.commands.executeCommand("extension.forceSetReqPrefix", "SRS_MY_PREFIX_").then(_ => {
                    return vscode.commands.executeCommand("extension.insertReqCommand").then(status => {
                        assert.ok(status);
                        assert.equal(doc.getText(), sampleFileAfterOneSpec);
                        done();
                    });
                });
            });
        })
        .catch(err => {
            done(err);
        });
    });

    test('Tag one requirement with existing requirement', (done) => {
        withRandomFileEditor(sampleFileWithExistingBefore, (editor, doc) => {
            editor.selection = new vscode.Selection(
                new vscode.Position(7, 0),
                new vscode.Position(7, 17)
            );

            return vscode.commands.executeCommand("extension.forceSetDevId", "8").then(_ => {
                return vscode.commands.executeCommand("extension.forceSetReqPrefix", "SRS_MY_PREFIX_").then(_ => {
                    return vscode.commands.executeCommand("extension.insertReqCommand").then(status => {
                        assert.ok(status);
                        assert.equal(doc.getText(), sampleFileWithExistingAfterOneSpec);
                        done();
                    });
                });
            });
        })
        .catch(err => {
            done(err);
        });
    });

    test('Tag three requirements', (done) => {
        withRandomFileEditor(sampleFileBefore, (editor, doc) => {
            editor.selection = new vscode.Selection(
                new vscode.Position(5, 0),
                new vscode.Position(5, 12)
            );

            return vscode.commands.executeCommand("extension.forceSetDevId", "8").then(_ => {
                return vscode.commands.executeCommand("extension.forceSetReqPrefix", "SRS_MY_PREFIX_").then(_ => {
                    return vscode.commands.executeCommand("extension.insertReqCommand").then(status => {
                        assert.ok(status);
                        editor.selection = new vscode.Selection(
                            new vscode.Position(7, 0),
                            new vscode.Position(7, 17)
                        );
                        return vscode.commands.executeCommand("extension.insertReqCommand").then(status => {
                            assert.ok(status);
                            editor.selection = new vscode.Selection(
                                new vscode.Position(9, 0),
                                new vscode.Position(9, 16)
                            );
                            return vscode.commands.executeCommand("extension.insertReqCommand").then(status => {
                                assert.ok(status);
                                assert.equal(doc.getText(), sampleFileAfter);
                                done();
                            });
                        });
                    });
                });
            });
        })
        .catch(err => {
            done(err);
        });
    });

    test('Tag three requirements with one command', (done) => {
        withRandomFileEditor(sampleFileBefore, (editor, doc) => {
            editor.selection = new vscode.Selection(
                new vscode.Position(5, 0),
                new vscode.Position(9, 16)
            );

            return vscode.commands.executeCommand("extension.forceSetDevId", "8").then(_ => {
                return vscode.commands.executeCommand("extension.forceSetReqPrefix", "SRS_MY_PREFIX_").then(_ => {
                    return vscode.commands.executeCommand("extension.insertReqsCommand").then(status => {
                        assert.ok(status);
                        assert.equal(doc.getText(), sampleFileAfter);
                        done();
                    });
                });
            });
        })
        .catch(err => {
            done(err);
        });
    });

    test('Tag multiple does nothing when selection is whitespace', (done) => {
        withRandomFileEditor(otherSampleFile, (editor, doc) => {
            editor.selection = new vscode.Selection(
                new vscode.Position(4, 0),
                new vscode.Position(6, 0)
            );

            return vscode.commands.executeCommand("extension.forceSetDevId", "8").then(_ => {
                return vscode.commands.executeCommand("extension.forceSetReqPrefix", "SRS_MY_PREFIX_").then(_ => {
                    return vscode.commands.executeCommand("extension.insertReqsCommand").then(status => {
                        assert.ok(status);
                        assert.equal(doc.getText(), otherSampleFile);
                        done();
                    });
                });
            });
        })
        .catch(err => {
            done(err);
        });
    });

    test('Tag multiple requirements with one command with existing', (done) => {
        withRandomFileEditor(sampleFileWithExistingBefore, (editor, doc) => {
            editor.selection = new vscode.Selection(
                new vscode.Position(5, 0),
                new vscode.Position(9, 16)
            );

            return vscode.commands.executeCommand("extension.forceSetDevId", "8").then(_ => {
                return vscode.commands.executeCommand("extension.forceSetReqPrefix", "SRS_MY_PREFIX_").then(_ => {
                    return vscode.commands.executeCommand("extension.insertReqsCommand").then(status => {
                        assert.ok(status);
                        assert.equal(doc.getText(), sampleFileWithExistingAfter);
                        done();
                    });
                });
            });
        })
        .catch(err => {
            done(err);
        });
    });

    test('Tag multiple requirements with markdown lists', (done) => {
        withRandomFileEditor(sampleFileBeforeWithLists, (editor, doc) => {
            editor.selection = new vscode.Selection(
                new vscode.Position(3, 0),
                new vscode.Position(12, 0)
            );

            return vscode.commands.executeCommand("extension.forceSetDevId", "8").then(_ => {
                return vscode.commands.executeCommand("extension.forceSetReqPrefix", "SRS_MY_PREFIX_").then(_ => {
                    return vscode.commands.executeCommand("extension.insertReqsCommand").then(status => {
                        assert.ok(status);
                        assert.equal(doc.getText(), sampleFileAfterWithLists);
                        done();
                    });
                });
            });
        })
        .catch(err => {
            done(err);
        });
    });

});