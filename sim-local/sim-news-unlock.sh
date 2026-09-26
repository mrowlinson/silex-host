#!/bin/bash
# sim-news-unlock: drive sim News past Welcome, headless + idempotent.
#
# Why taps, not prefs: News 11.5 (iOS 26.5 sim) ignores every defaults bypass
# tried (news.onboarding.version.latest_completed=0/99/999,
# debug_latest_completed=999 in container AND global plists, splash disable,
# useWelcomeSeries=false) — BootstrapFlowProvider still logs experience
# 'welcome'. One accessibility tap on Continue runs Apple's own
# completeOnboarding (writes latest_completed=5=current, debug=-1) and lands
# on the Today feed; later launches skip Welcome (state persists in the
# News container). See docs/SIM-NEWS-UNLOCK.md.
#
# Requires: booted sim (default uid851-iphone), `idb` with companion access.
# Exit 0 = feed reached (no Welcome heading in AX tree). Safe to re-run:
# already-unlocked sims no-op after the first AX dump.
#
# Env: UDID=<sim> (default A1E4A805...), OUT=<png path> (default tmp file),
#      MAX_TAPS (default 10).
set -u

UDID="${UDID:-A1E4A805-39CE-46F4-91E3-35A712947CBB}"
OUT="${OUT:-tmp/sim-news-unlock-proof.png}"
MAX_TAPS="${MAX_TAPS:-10}"

fail() { echo "UNLOCK-FAIL: $1" >&2; exit 1; }
info() { echo "UNLOCK-INFO: $1"; }

command -v idb >/dev/null 2>&1 || fail "idb not on PATH"
command -v xcrun >/dev/null 2>&1 || fail "xcrun not on PATH"
xcrun simctl list devices booted 2>/dev/null | grep -q "$UDID" \
  || fail "sim $UDID not booted"

idb list-targets 2>/dev/null | grep "$UDID" | grep -q "companion.sock" \
  || { info "connecting idb companion"; idb connect "$UDID" >/dev/null 2>&1 \
  || fail "idb connect $UDID failed"; }

xcrun simctl launch "$UDID" com.apple.news >/dev/null 2>&1 || true
sleep 6

n=0
while [ "$n" -lt "$MAX_TAPS" ]; do
  AX=$(idb ui describe-all --udid "$UDID" 2>/dev/null) || fail "AX dump failed"
  case "$AX" in
    *'"AXLabel":"Continue"'*)
      n=$((n+1)); info "tap $n: Continue present"
      idb ui tap --udid "$UDID" Continue >/dev/null 2>&1 || fail "tap failed"
      sleep 4 ;;
    *) break ;;
  esac
done

AX=$(idb ui describe-all --udid "$UDID" 2>/dev/null) || fail "final AX dump failed"
case "$AX" in
  *'Welcome Back to Apple News'*|*'Welcome to Apple News'*)
    fail "Welcome still present after $n taps" ;;
esac

# System permission alerts (location, notifications) gate first render with
# a black screen behind them and re-appear across launches until answered
# (T1-clean-retest). Dismiss iff the button label is actually present.
m=0
while [ "$m" -lt 3 ]; do
  AX=$(idb ui describe-all --udid "$UDID" 2>/dev/null) || fail "alert AX dump failed"
  case "$AX" in
    *'Don’t Allow'*|*"Don't Allow"*)
      m=$((m+1)); info "alert-dismiss tap $m"
      idb ui tap --udid "$UDID" "Don’t Allow" >/dev/null 2>&1 \
        || idb ui tap --udid "$UDID" "Don't Allow" >/dev/null 2>&1 || true
      sleep 4 ;;
    *) break ;;
  esac
done
[ "$m" -gt 0 ] && info "dismissed $m alert(s)"

xcrun simctl io "$UDID" screenshot "$OUT" >/dev/null 2>&1 || fail "screenshot failed"
info "feed reached taps=$n proof=$OUT"
echo "UNLOCK-PASS: sim News past Welcome (taps=$n)"
