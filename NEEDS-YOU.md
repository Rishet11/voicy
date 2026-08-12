# Things only Rishet can do

The autonomous agent appends here instead of stopping. Newest at the bottom.
Nothing in this file blocks the agent — it works around each item and logs it.

---

## 1. Test auto-send with your voice (5 minutes) — HIGHEST VALUE

Auto-send is fully built and both permissions are granted, but **it has never once executed**. No agent can test it, because it needs a human to hold a key and speak.

```bash
cd /Users/rishetmehra/Desktop/aohack/voicy
open -n dist/Voicy.app --stdout /tmp/voicy.log --stderr /tmp/voicy.err
# hold Ctrl+Space, say: "message Stone that this is a test"
cat /tmp/voicy.log
```

**Watch for:** does WhatsApp send it without you clicking Send? The log prints every step (`OPEN`, `READY`, `POST Return`, `VERIFY`), so a failure will name itself.

---

## 2. Deploy the landing page

`wrangler` is not installed and Cloudflare login needs a browser, so the agent cannot deploy. It builds the site as static files at `landing/` instead.

```bash
npx wrangler pages deploy landing --project-name voicy
```

First run opens a browser to authenticate.

---

## 3. Decisions the agent cannot make for you

- **Repo visibility.** Currently private. Public before judging?
- **Sarvam AI for Hinglish.** Better Indic accuracy, but it uploads your audio and breaks the "never leaves your Mac" claim. Agent's recommendation: optional toggle, default OFF, API key in a gitignored `.env`. Needs your key and your call.
- **Apple Developer ID ($99/yr).** Required for a notarized build other people can download without scary warnings. A purchase, not a code change.
- **Cold-start deep link.** Verified only with WhatsApp already running. Quit WhatsApp entirely, then fire a deep link, and tell the agent whether the text still pre-fills.

---

## 4. Blocked / stuck (agent appends below)

<!-- Agent: append anything you tried 3+ times and could not resolve. Include the exact error and what you tried. -->
