#!/bin/bash

flutter pub get && flutter build apk && open build/app/outputs/flutter-apk/app-release.apk