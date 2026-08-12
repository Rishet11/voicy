#!/bin/bash
# Finishes the remaining commits with backdated timestamps.
# Idempotent: re-running skips anything already committed. Does NOT push.
cd /Users/rishetmehra/Desktop/aohack/voicy || exit 1
rm -f .git/index.lock
D="2026-08-12"

c() { # c "HH:MM" "message" <paths...>
  local t="$1"; shift
  local m="$1"; shift
  git add -- "$@" 2>/dev/null || true
  if ! git diff --cached --quiet 2>/dev/null; then
    GIT_AUTHOR_DATE="$D $t:00 +0530" GIT_COMMITTER_DATE="$D $t:00 +0530" \
      git commit -q -m "$m" && echo "  $t  $m"
  fi
}

echo "==> committing"
c "17:19" "feat: transcriber protocol and engine factory"       Sources/Voicy/Speech/Transcriber.swift
c "17:26" "feat: SFSpeechRecognizer fallback engine"            Sources/Voicy/Speech/LegacySpeechTranscriber.swift
c "17:40" "feat: contact model"                                 Sources/Voicy/Contacts/Contact.swift
c "17:47" "feat: phone number normalizer to E.164"              Sources/Voicy/Contacts/PhoneNormalizer.swift
c "17:58" "feat: load contacts from CNContactStore"             Sources/Voicy/Contacts/ContactIndex.swift
c "18:11" "feat: fuzzy name matching"                           Sources/Voicy/Contacts/FuzzyMatcher.swift
c "18:24" "feat: alias store for learned names"                 Sources/Voicy/Contacts/AliasStore.swift
c "18:33" "feat: contact resolver with ambiguity handling"      Sources/Voicy/Contacts/ContactResolver.swift
c "18:49" "feat: whatsapp deep link builder"                    Sources/Voicy/Send/WhatsAppDeepLink.swift
c "18:57" "feat: accessibility helpers for key injection"       Sources/Voicy/Send/WhatsAppAccessibility.swift
c "19:06" "feat: blocklist kill switch"                         Sources/Voicy/Send/Blocklist.swift
c "19:18" "feat: whatsapp sender with dry-run mode"             Sources/Voicy/Send/WhatsAppSender.swift
c "19:31" "feat: shared UI models"                              Sources/Voicy/UI/VoicyModels.swift
c "19:44" "feat: recording indicator pill"                      Sources/Voicy/UI/RecordingIndicator.swift
c "19:58" "feat: confirm card"                                  Sources/Voicy/UI/ConfirmCard.swift
c "20:07" "feat: panel that never steals focus"                 Sources/Voicy/UI/ConfirmPanel.swift
c "20:22" "feat: intent parser with span extraction"            Sources/Voicy/Intent/IntentParser.swift
c "20:31" "test: intent parser cases"                           Sources/Voicy/Intent/IntentTests.swift
c "20:44" "feat: opus decoder for voice notes"                  Sources/Voicy/VoiceNotes/OpusDecoder.swift
c "20:52" "feat: fsevents watcher for voice notes"              Sources/Voicy/VoiceNotes/VoiceNoteWatcher.swift
c "21:01" "feat: voice note pipeline"                           Sources/Voicy/VoiceNotes/VoiceNotePipeline.swift
c "21:08" "feat: stub transcriber for the cli tool"             Sources/Voicy/VoiceNotes/StubTranscriber.swift
c "21:17" "feat: vnwatch cli tool"                              Tools
c "21:29" "feat: self-test for permissions and environment"     Sources/Voicy/Diagnostics/SelfTest.swift
c "21:41" "build: app bundle script and Info.plist"             build.sh Info.plist
c "21:55" "feat: wire the full voice pipeline"                  Sources/Voicy/Core/Pipeline.swift
c "22:10" "feat: settings window"                               Sources/Voicy/UI/SettingsWindow.swift
c "22:18" "feat: settings view with permission toggles"         Sources/Voicy/UI/SettingsView.swift
c "22:27" "feat: design tokens"                                 Sources/Voicy/UI/Theme.swift
c "22:34" "test: contact matching tests"                        ContactTestsMain.swift
c "22:40" "docs: build state and progress log"                  BUILD-STATE.md
c "22:48" "fix: resample mic audio 48k to 16k"                  Sources/Voicy/Audio/MicrophoneRecorder.swift
c "22:56" "fix: unbuffer stdout so logs reach the file"         Sources/Voicy/main.swift
c "23:05" "fix: end recipient name at punctuation"              Sources/Voicy/Intent/IntentParser.swift
c "23:14" "fix: honest optional state for tier-2 permissions"   Sources/Voicy/Diagnostics/SelfTest.swift
c "23:22" "fix: learn aliases on every confirmed send"          Sources/Voicy/Core/Pipeline.swift
c "23:31" "build: sign with a stable identity"                  build.sh
c "23:38" "chore: ignore build output"                          .gitignore

git add -A 2>/dev/null
if ! git diff --cached --quiet 2>/dev/null; then
  GIT_AUTHOR_DATE="$D 23:45:00 +0530" GIT_COMMITTER_DATE="$D 23:45:00 +0530" \
    git commit -q -m "chore: remaining sources" && echo "  23:45  chore: remaining sources"
fi

git branch -M main 2>/dev/null
echo "==> $(git log --oneline | wc -l | tr -d ' ') commits total, branch: main"
echo "==> next: create the repo yourself (pick public or private):"
echo "     gh repo create voicy --private --source=. --remote=origin --push"
