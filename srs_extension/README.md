# README

*Right now the code is a spike to test the features. It is neither clean nor tested.*
*See the backlog for what's next, and feel free to contribute :P*

## Installation instructions
There are 2 ways to install this extension: either directly using the source code, or using a vsix package. In both cases, the files end up in `C:\users\<username>\.vscode\extensions`.

### Using the source code
- Clone this repository in `C:\users\<username>\.vscode\extensions`.
or
- Clone this repo anywhere and copy the files to `C:\users\<username>\.vscode\extensions`
- Run `npm install` in this directory

### Using the vsix package:
in short, just open the extension in Visual Studio Code (don't double-click, it won't work since it'll try to install on Visual Studio instead).
Your choice:
- Right-Click on the VSIX file and select "open with code"
or
- Use "File -> Open" in Visual Studio Code and open the vsix file
or
- in the command line: `code PATH_TO_VSIX_FILE.vsix`

## Quick start

Once installed, the extension becomes active whenever a markdown file is opened.
At first it'll ask for a Developer ID, it's used to create requirement tags.
To insert a new requirement tag:
1. Select the text of the requirement 
2. Press `Alt+F8`. It'll read all the tags in the document and insert the next one using your Dev ID. 
    - If it hasn't yet it will prompt you for your Dev ID.
    - if there are multiple requirement tags in the document with different prefixes, it'll ask you once to pick which prefix to use.
    - if there are no requirements in the document, you'll have to create the first one yourself manually (see below for requirement tags format).

All requirement tags use the following syntax: `SRS_SOMESTRING_<DEVID>_<REQID>`

You may also insert requirement tags for the currently selected text by pressing `Alt+F9`. This will:
 - Tag all non-empty (white space only) lines
 - Preserve unordered list markdown (i.e. skip over combinations of `-` and space)

(Right now the requirement tag format is hardcoded.)

There are a couple more things you can do, by bringing up the command pane (by pressing F1):
- change your Dev ID (look for the "Change Developer ID" command in the list)
- change the prefix used (look for the "Change Requirement Tag Prefix" command in the list)

these two commands do not have shortcut keys (doesn't feel useful for now).

## How to generate a VSIX package
1. Increment the version number in `package.json`
1. Install the vsce module: `npm install -g vsce`
2. Open a command prompt and navigate to the folder where the extension source code is
3. type `vsce package` and witness the appearance of the vsix file
