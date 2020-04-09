/* global JSON */
// The module 'vscode' contains the VS Code extensibility API
// Import the module and reference it with the alias vscode in your code below
var path = require('path');
var FS = require('fs');
var vscode = require('vscode');
var reqParser = require('./reqparser.js');

var ADD_NEW_PREFIX = "Add New Prefix...";

// this method is called when your extension is activated
// your extension is activated the very first time the command is executed
function activate(context) {
    var devId = loadDevId();
    var reqPrefix = "";

    var setDevId = function (id) {
        if(id && id.trim().length > 0) {
            devId = id;
            saveDevId(id);
            return true;
        }
        return false;
    };

    var setReqPrefix = function (prefix) {
        if(!!prefix) {
            if(prefix === ADD_NEW_PREFIX) {
                return vscode.window.showInputBox({
                    placeHolder: 'New requirement prefix',
                    prompt: 'Enter the new requirement prefix to use'
                })
                .then(function(newPrefix) {
                    if(!!newPrefix) {
                        reqPrefix = newPrefix;
                        return true;
                    }
                    return false;
                });
            }
            else {
                reqPrefix = prefix;
                return true;
            }
        }
        return false;
    };
    
    var askDevId = function () {
        return vscode.window.showInputBox({ prompt: "Please enter your dev id" });
    };

    var loadText = function () {
        var text = "";
        if (vscode.window.activeTextEditor) {
            text = vscode.window.activeTextEditor.document.getText();
        } else {
            vscode.window.showErrorMessage('File not loaded. Please open a file in the editor first.');
        }

        return text;
    };

    var lookupReqPrefix = function () {
        if (reqPrefix) return;
        var text = loadText();

        if (text) {
            var prefixes = reqParser.getPrefixes(text);
            if(!prefixes || prefixes.length === 0) {
                return vscode.window.showInputBox({ prompt: "Please enter the requirement tag to use" }).
                    then(setReqPrefix);
            }
            else if (prefixes.length === 1) {
                setReqPrefix(prefixes[0]);
                return;
            } else {
                return vscode.window.showQuickPick(prefixes)
                    .then(setReqPrefix);
            }
        }
    };

    var insertReqTag = function () {
        var text = loadText();

        if (text) {
            var reqTag = reqParser.getNextReq(text, reqPrefix, devId);
            var editor = vscode.window.activeTextEditor;
            var startSnippet = '**' + reqTag + ': [** ';
            var endSnippet = ' **]**';
            return editor.edit(function (e) {
                // insert start snippet
                e.insert(editor.selection.start, startSnippet);
            }).then(function(status) {
                if(status) {
                    // insert end snippet
                    return editor.edit(function(e) {
                        e.insert(editor.selection.end, endSnippet);
                    });
                }
                
                return status;
            }).then(function(status) {
                if(status) {
                    // move caret to end of line before endSnippet
                    var pos = editor.selection.end.translate(0, -1 * endSnippet.length);
                    editor.selection = new vscode.Selection(pos, pos);
                }
                return status;
            });
        } else {
            return editor.edit(function (e) {}).then(function(status) { return status; });
        }
    };

    var insertReqTags = function () {
        var text = loadText();

        if (text) {
            var nextReqTag = reqParser.getNextReq(text, reqPrefix, devId);

            var editor = vscode.window.activeTextEditor;
            var document = editor.document;

            var endSnippet = ' **]**';

            var rangesToEdit = new Array();
            var positionIterator = editor.selection.start;
            var stopLine = editor.selection.end.line;
            while (positionIterator.line <= stopLine) {
                var line = document.lineAt(positionIterator);
                // Attempt to add requirement to each line
                if (!line.isEmptyOrWhitespace) {
                    // Skip markdown list and white space around it
                    var startOffset = line.firstNonWhitespaceCharacterIndex;
                    while (line.text.charAt(startOffset) == '-' || line.text.charAt(startOffset) == ' ') {
                        startOffset++;
                    }
                    if (line.text.charAt(startOffset) != '\n' && line.text.charAt(startOffset) != '\r') {
                        var lineStart = positionIterator.translate(0, startOffset);
                        rangesToEdit.push(lineStart);
                    }
                }
                positionIterator = positionIterator.with(positionIterator.line + 1, 0);
            }

            var task = null;

            rangesToEdit.forEach(function (value, index, array){
                var doInsertStart = function (e) {
                    // insert start snippet
                    var startSnippet = '**' + nextReqTag + ': [** ';
                    nextReqTag = reqParser.getNextReq(nextReqTag, reqPrefix, devId);
                    e.insert(value, startSnippet);
                };

                var doInsertEnd = function (e) {
                    // recompute line end (after inserting start) and insert end
                    var line = document.lineAt(value);
                    var lineEnd = value.with(value.line, line.text.length);
                    e.insert(lineEnd, endSnippet);
                };
                
                // Insert start
                if (task == null) {
                    task = editor.edit(doInsertStart);
                } else {
                    task = task.then(function(status) {
                        if (status) {
                            return editor.edit(doInsertStart);
                        }
                        return status;
                    });
                }

                // Insert end
                task = task.then(function(status) {
                    if (status) {
                        return editor.edit(doInsertEnd);
                    }
                    return status;
                });
            });
            
            if (task == null) {
                return editor.edit(function (e) {}).then(function(status) { return status; });
            } else {
                return task.then(function(status) { return status; });
            }
        } else {
            return editor.edit(function (e) {}).then(function(status) { return status; });
        }
    };

    var insertReqCommand = vscode.commands.registerCommand('extension.insertReqCommand', function () {
        if (devId === "") {
            return askDevId().then(setDevId)
                      .then(lookupReqPrefix)
                      .then(insertReqTag);
        } else {
            var prefixPromise = lookupReqPrefix();
            if (prefixPromise) {
                return prefixPromise.then(insertReqTag);
            } else {
                return insertReqTag();
            }
        }
    });

    var insertReqsCommand = vscode.commands.registerCommand('extension.insertReqsCommand', function () {
        if (devId === "") {
            return askDevId().then(setDevId)
                      .then(lookupReqPrefix)
                      .then(insertReqTags);
        } else {
            var prefixPromise = lookupReqPrefix();
            if (prefixPromise) {
                return prefixPromise.then(insertReqTags);
            } else {
                return insertReqTags();
            }
        }
    });

    var changeDevIdCommand = vscode.commands.registerCommand('extension.changeDevId', function () {
        askDevId().then(setDevId);
    });

    var changeReqPrefixCommand = vscode.commands.registerCommand('extension.changeReqPrefix', function () {
        var text = loadText();
        var prefixes = reqParser.getPrefixes(text);
        prefixes.push(ADD_NEW_PREFIX);
        vscode.window.showQuickPick(prefixes)
                     .then(setReqPrefix);
    });

    // Test hook
    var forceSetDevIdCommand = vscode.commands.registerCommand('extension.forceSetDevId', function (id) {
        setDevId(id);
    });
    var forceSetReqPrefixCommand = vscode.commands.registerCommand('extension.forceSetReqPrefix', function (prefix) {
        setReqPrefix(prefix);
    });

    context.subscriptions.push(insertReqCommand);
    context.subscriptions.push(insertReqsCommand);
    context.subscriptions.push(changeDevIdCommand);
    context.subscriptions.push(changeReqPrefixCommand);

    // Expose commands for test that don't need UI
    context.subscriptions.push(forceSetDevIdCommand);
    context.subscriptions.push(forceSetReqPrefixCommand);
}

// from: http://stackoverflow.com/a/9081436
function getUserHome() {
  return process.env[(process.platform == 'win32') ? 'USERPROFILE' : 'HOME'];
}

function saveDevId(devid) {
    var settingsPath = path.join(getUserHome(), '.reqdocs');
    var settings = {};
    if(FS.existsSync(settingsPath)) {
        var settingString = FS.readFileSync(settingsPath, {
            encoding: 'utf8'
        });
        if(settingString) {
            settings = JSON.parse(settingString);
        }
    }
    settings.devid = devid;
    FS.writeFileSync(settingsPath, JSON.stringify(settings), {
        encoding: 'utf8'
    });
}

function loadDevId() {
    var settingsPath = path.join(getUserHome(), '.reqdocs');
    var settings = null;
    if(FS.existsSync(settingsPath)) {
        settings = FS.readFileSync(settingsPath, {
            encoding: 'utf8'
        });
        if(settings) {
            settings = JSON.parse(settings);
        }
    }
    return (settings && settings.devid) || '';
}

exports.activate = activate;
