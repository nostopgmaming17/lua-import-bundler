@echo off
if not exist "dist/" (
    mkdir dist
)
lua bundle.lua import_bundle.lua -o dist/bundle.lua