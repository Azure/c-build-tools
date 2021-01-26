#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

git checkout master
git pull
git submodule update --init
git submodule foreach "git checkout master && git pull"
git branch -D new_deps
git checkout -b new_deps
git add .
git commit -m "Update dependencies"
git push -f origin new_deps
