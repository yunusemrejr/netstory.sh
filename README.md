 
***

# netstory.sh

**netstory.sh** is a comprehensive CLI network/application diagnostic tool for Linux, combining classic Bash networking checks with real Chrome headless (Puppeteer) browser analysis.
It’s designed for network engineers, sysadmins, DevOps, and web troubleshooters who want to **see both the raw network path and what the actual browser experiences—**including real API errors, module loads, and CDN issues.

***

## Features

- **Network storytelling:**
    - Resolves a destination (domain, IP or URL) and traces the network path with ISP/geolocation information and private/reserved IP awareness.
    - Checks a broad range of ports (web, mail, DB, SSH, alt web) for basic reachability.
    - Probes HTTP and HTTPS status, detects CDN/proxy shielding (Cloudflare, Akamai, GCore, Fastly, etc.), extracts server headers and TLS certificate info.
- **Dependency \& asset analysis:**
    - Static probe parses the HTML to discover API endpoints, subdomain services, external fonts/CDN links.
    - Checks health of all key domains/subdomains and up to 3 supporting font/CDN assets.
- **Real browser-level request trace:**
    - Launches a real headless Chrome using Puppeteer (via Node.js) to simulate what a user’s browser would do.
    - Records all module loads, scripts, fonts, dynamic XHR/fetch/API calls, and their response codes—**including errors caused by JS, async modules, and runtime APIs that Bash/cURL cannot detect**.
    - Summarizes successful and failed requests, matching exactly what you’d see in browser DevTools.
- **Narrative and summary output:**
    - Produces a narrative “story” of your request’s journey, technical but readable.
    - Highlights key KPIs: reachability, open ports, CDN used, dependency failures, and more.

***

## Requirements

- **Debian/Ubuntu/Pop!_OS/WSL** system.
- **Bash** (default shell).
- Dependencies: `curl`, `traceroute`, `whois`, `jq`, `nc` (netcat), `dig`, `openssl`, **Node.js (≥14)**, and **Puppeteer** (installed via npm).
- _Install everything quickly:_

```bash
sudo apt-get install curl traceroute whois jq netcat-openbsd dnsutils openssl nodejs npm
npm install puppeteer
```

- You must run the script **as your normal user** (not root/sudo), so it can access your npm-installed modules!

***

## Usage

```bash
./netstory.sh <destination domain or IP>
# Example:
./netstory.sh finans.aspotomasyon.com
```

**What it outputs:**

- Textual story with all network jumps, key subdomains, dependency/CDN analysis, failed and successful probes, and clear, color-coded summaries.
- Browser request section lists real API/JS/module/font requests and errors from a headless browser session—what DevTools Network/XHR would reveal.

***

## Sample Output

```
🔎 Resolving destination finans.aspotomasyon.com...
🌐 Getting your public IP...
...
🕸️ Launching real-browser analysis with Puppeteer (Chrome headless)...

======= Puppeteer: BROWSER REQUEST TRACE for https://finans.aspotomasyon.com =======
[DOCUMENT] GET https://finans.aspotomasyon.com → 200
[SCRIPT] GET https://finans.aspotomasyon.com/dist/app/core/core.module.js → 522 | Body: Cloudflare ray ID: ...
[XHR] GET https://finans.aspotomasyon.com/api/auth/me → 522 | Body: Error 522
...

-- Failed Requests Detected:
[SCRIPT] GET https://finans.aspotomasyon.com/dist/app/core/core.module.js → 522 ...
...
✅ FINAL STORY (BASH DIAG):
You attempted communication with finans.aspotomasyon.com.
...
📊 KPIs:
- Destination: finans.aspotomasyon.com (172.67.214.95)
- Reached: ✅ Yes
- CDN/Proxy: Cloudflare
- Ports scanned: 14 | Open: 4
...
```


***

## Troubleshooting

### “Puppeteer not found in Node.js; install with: npm install puppeteer”

- Make sure to run `npm install puppeteer` as your normal user in the target/script directory.
- Never use `sudo` to run this script.
- If you get permission/launch errors, ensure your NODE_PATH and environment are correct. The script autodetects and tries to run Puppeteer several different ways.

***

## Security Notice

- Do NOT run this script as root unless absolutely necessary; all diagnostics are safe and require only normal user permissions.
- As with any headless browser, Puppeteer launches a local Chrome and fetches the destination site’s URLs as a real browser would.

***

## License

MIT or public domain — feel free to adapt and share!

***

## Credits

Script logic, network storytelling, and browser automation adapted for troubleshooting by Yunus Emre Vurgun.

***

**TL;DR:**
`netstory.sh` gives you the “full story” — from the physical network through to the real JavaScript errors your users will see.
If you care about what’s really broken, run it!
