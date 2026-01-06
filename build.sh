#!/bin/bash

# Compile the Swift app
swiftc -o PomodoroTimer PomodoroTimer.swift -framework Cocoa -framework AVFoundation

# Create app bundle structure
mkdir -p "Pomodoro.app/Contents/MacOS"
mkdir -p "Pomodoro.app/Contents/Resources"

# Move executable and Info.plist
mv PomodoroTimer "Pomodoro.app/Contents/MacOS/"
cp Info.plist "Pomodoro.app/Contents/"
cp AppIcon.icns "Pomodoro.app/Contents/Resources/"

# Create DMG
rm -f Pomodoro.dmg
hdiutil create -volname "Pomodoro Timer" -srcfolder "Pomodoro.app" -ov -format UDZO Pomodoro.dmg

echo "✓ Build complete! Pomodoro.dmg created"
