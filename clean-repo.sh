#!/bin/bash

echo "> 🧹🧹 cleaning yarn cache ..."
yarn cache clean --all > /dev/null

echo "> 🧹🧹 repository dependencies ..."
rm -rf node_modules

echo "> 🧹✨ cleanup finished"

exit 0