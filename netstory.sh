#!/usr/bin/env bash
# netstory.sh - Bash network storytelling + Puppeteer browser diagnostics (robust launch)

DEST="$1"
if [[ -z "$DEST" ]]; then
  echo "Usage: $0 <destination-domain-or-IP>"
  exit 1
fi

for cmd in curl traceroute whois nc jq dig openssl node; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Missing dependency: $cmd"
    exit 1
  fi
done

is_private_ip() {
  local ip=$1
  [[ $ip =~ ^10\. ]] && return 0
  [[ $ip =~ ^192\.168\. ]] && return 0
  [[ $ip =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ $ip =~ ^127\. ]] && return 0
  [[ $ip =~ ^169\.254\. ]] && return 0
  return 1
}

ip_lookup() {
  local ip=$1
  if is_private_ip "$ip"; then
    echo "Private/Reserved (LAN/ISP internal)"
    return
  fi
  local info
  info=$(curl -s --max-time 4 "https://ipinfo.io/$ip/json" | jq -r '[.org, .city, .country] | join(", ")')
  if [[ -n "$info" && "$info" != "null, null, null" ]]; then
    echo "$info"; return
  fi
  local w
  w=$(whois "$ip" 2>/dev/null | egrep -i 'OrgName|organization|descr|country' | head -n 2 | tr '\n' ',' | sed 's/,$//')
  [[ -n "$w" ]] && echo "$w" && return
  echo "Unknown network"
}

# -------- Bash Diagnostics Section ---------
echo "🔎 Resolving destination $DEST..."
DEST_IP=$(dig +short "$DEST" | head -n1)
if [[ -z "$DEST_IP" ]]; then echo "❌ Could not resolve $DEST"; exit 1; fi
PROTO=$(getent ahosts "$DEST" | awk '{print $NF; exit}')

echo "🌐 Getting your public IP..."
MYIP=$(curl -s --max-time 5 https://ifconfig.me || echo "Unknown")

TRACE="You attempted communication with $DEST.
Your public IP: $MYIP
Resolved destination ($PROTO): $DEST_IP"

PORTS=(22 25 53 80 110 143 443 587 993 995 3306 5432 8080 8443)
echo "🔦 Checking common ports..."
PORT_RESULTS=()
for PORT in "${PORTS[@]}"; do
  if nc -z -w 3 "$DEST_IP" $PORT 2>/dev/null; then
    PORT_RESULTS+=("Port $PORT: OPEN")
  else
    PORT_RESULTS+=("Port $PORT: CLOSED/filtered")
  fi
done

TRACE+="\n\nConnectivity scan results:"
for r in "${PORT_RESULTS[@]}"; do TRACE+="\n - $r"; done

CDN_DETECTED="None"
HTTPS_CERT=""
for SCHEME in http https; do
  echo "🌐 Probing $SCHEME on $DEST..."
  RESP=$(curl -s -m 8 -I -w "\nCODE=%{http_code}\n" "$SCHEME://$DEST" -o /tmp/hdrs.txt)
  CODE=$(echo "$RESP" | grep CODE | cut -d= -f2)
  SERVER=$(grep -i '^Server:' /tmp/hdrs.txt | head -n1 | cut -d' ' -f2- | tr -d '\r')
  CF=$(grep -i 'cf-ray' /tmp/hdrs.txt)
  VIA=$(grep -i '^Via:' /tmp/hdrs.txt)

  TRACE+="\n\nWhen trying $SCHEME://$DEST → HTTP $CODE"
  [[ -n "$SERVER" ]] && TRACE+=" (server: $SERVER)."

  if echo "$SERVER" | grep -qi 'cloudflare\|cf-ray'; then CDN_DETECTED="Cloudflare"
  elif echo "$SERVER" | grep -qi 'gcore'; then CDN_DETECTED="GCore"
  elif echo "$SERVER" | grep -qi 'akamai'; then CDN_DETECTED="Akamai"
  elif echo "$SERVER" | grep -qi 'fastly\|varnish'; then CDN_DETECTED="Fastly"
  elif [[ -n "$VIA" ]]; then CDN_DETECTED="Generic Proxy"
  fi

  if [[ "$SCHEME" == "https" ]]; then
    echo "🔑 Extracting TLS certificate details..."
    CERT=$(echo | openssl s_client -servername "$DEST" -connect "$DEST:443" 2>/dev/null | openssl x509 -noout -issuer -subject -dates)
    HTTPS_CERT="$CERT"
    [[ -n "$CERT" ]] && TRACE+="\nTLS: $CERT"
  fi
done

echo "🚦 Running traceroute..."
FLOW="Flow: "
TRACE+="\n\nTraceroute:"
hop_num=0
> /tmp/traceinfo
traceroute -n "$DEST" 2>/dev/null | while read -r line; do
  hop_ip=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
  if [[ -n "$hop_ip" ]]; then
    hop_num=$((hop_num+1))
    echo "📡 Hop $hop_num: $hop_ip"
    desc=$(ip_lookup "$hop_ip")
    echo " → $hop_ip ($desc)" >> /tmp/traceinfo
    if [[ $hop_num -le 3 ]]; then FLOW+=" $hop_ip →"
    fi
  elif echo "$line" | grep -q '\*'; then
    echo " → Hidden hop (*)" >> /tmp/traceinfo
  fi
done
[ -f /tmp/traceinfo ] && TRACE+="$(cat /tmp/traceinfo)" && rm /tmp/traceinfo
FLOW+="$DEST_IP"

# -------- HTML resource/static dependency probing ---------
echo "📥 Performing GET to analyze static page dependencies..."
curl -s -L --max-time 12 "https://$DEST" -o /tmp/body.html -D /tmp/body_headers.txt

MAIN_DOMAIN=$(echo "$DEST" | awk -F. '{print $(NF-1)"."$NF}')
URLS=$(grep -Eo 'https?://[^"'\'' >]+' /tmp/body.html | cut -d/ -f3 | sort -u)

SAME_FAMILY=()
EXTERNAL_FONTS=()
for host in $URLS; do
  if [[ "$host" == *"$MAIN_DOMAIN" ]]; then
    SAME_FAMILY+=("$host")
  else
    if [[ "$host" =~ (googleapis\.com|gstatic\.com|cloudflare\.com|bootstrapcdn\.com|jsdelivr\.net) ]]; then
      EXTERNAL_FONTS+=("$host")
    fi
  fi
done

TRACE+="\n\nDependency checks:"
if [[ ${#SAME_FAMILY[@]} -gt 0 ]]; then
  TRACE+="\nFunctional subdomains/services:"
  for host in "${SAME_FAMILY[@]}"; do
    echo "🌐 Checking core dependency: $host..."
    RES=$(curl -s -I --max-time 6 "https://$host" -w "CODE=%{http_code}" -o /tmp/dep_hdrs.txt)
    CODE=$(echo "$RES" | grep CODE | cut -d= -f2)
    [[ -z "$CODE" || "$CODE" == "000" ]] && TRACE+="\n → $host no response." || TRACE+="\n → $host → $CODE"
  done
fi

if [[ ${#EXTERNAL_FONTS[@]} -gt 0 ]]; then
  TRACE+="\nSupporting assets (fonts/CSS/CDNs):"
  count=0
  for host in "${EXTERNAL_FONTS[@]}"; do
    ((count++)); [[ $count -gt 3 ]] && break
    echo "🌐 Checking static asset: $host..."
    RES=$(curl -s -I --max-time 5 "https://$host" -w "CODE=%{http_code}" -o /tmp/dep_hdrs.txt)
    CODE=$(echo "$RES" | grep CODE | cut -d= -f2)
    [[ -z "$CODE" || "$CODE" == "000" ]] && TRACE+="\n → $host no response." || TRACE+="\n → $host → $CODE"
  done
fi

# -------- Puppeteer: Try various launchers ----------
cat > /tmp/puppeteer_netstory.js <<'EOF'
const puppeteer = require('puppeteer');
const target = process.argv[2];
(async () => {
  const browser = await puppeteer.launch({headless: "new"});
  const page = await browser.newPage();
  let requests = [];
  page.on('request', req => requests.push({ type: req.resourceType(), url: req.url(), method: req.method() }));
  page.on('requestfailed', req => {
    requests.push({ type: req.resourceType(), url: req.url(), method: req.method(), fail: req.failure().errorText });
  });
  page.on('response', async resp => {
    const req = resp.request();
    const entry = requests.find(r => r.url === req.url() && !r.code);
    if (entry) {
      entry.code = resp.status();
      try {
        if (entry.code >= 400 && entry.code < 600 && (entry.type === 'xhr' || entry.type === 'fetch' || entry.type === 'script')) {
          entry.body = (await resp.text()).trim().replace(/\s+/g, " ").substring(0,80);
        }
      } catch {}
    }
  });
  await page.goto(target, {waitUntil: "networkidle2", timeout: 35000});
  await page.waitForTimeout(3000); // Let JS-driven requests fire
  // Summarize output
  let out = [];
  for (const req of requests) {
    if (/^data:/.test(req.url) || req.url.endsWith('.ico')) continue;
    const k = `[${req.type.toUpperCase()}] ${req.method || 'GET'} ${req.url} ` +
              (req.code ? `→ ${req.code}` : req.fail ? `→ FAIL (${req.fail})` : '');
    if (req.body) out.push(`${k} | Body: ${req.body.replace(/\n/g," ")}`);
    else out.push(k);
  }
  // Categories
  let importantAPIs = out.filter(line =>
    (line.match(/XHR|FETCH|SCRIPT|DOCUMENT|OTHER/) && !line.match(/googleapis|gstatic|cloudflare|jsdelivr|bootstrapcdn/))
  );
  let fontCSS = out.filter(line => line.match(/fonts\.google|gstatic|\.woff2?|\.ttf|\.otf/));
  let failed  = out.filter(line => line.match(/→ (4|5)[0-9][0-9]|→ FAIL/));
  console.log(`\n======= Puppeteer: BROWSER REQUEST TRACE for ${target} =======`);
  importantAPIs.slice(0,12).forEach(line => console.log(line));
  fontCSS.slice(0,6).forEach(line => console.log(line));
  if (failed.length) {
    console.log("\n-- Failed Requests Detected:");
    failed.slice(0,8).forEach(line => console.log(line));
  }
  process.exit(0)
})();
EOF

echo
echo "🕸️ Launching real-browser analysis with Puppeteer (Chrome headless)..."
PUPPETEER_RESULT=1

# Try: npx node ..., node ... (project-local), node ... (user-local), npx ...
npx node /tmp/puppeteer_netstory.js "https://$DEST" && PUPPETEER_RESULT=0
if [ $PUPPETEER_RESULT -ne 0 ]; then
  node /tmp/puppeteer_netstory.js "https://$DEST" && PUPPETEER_RESULT=0
fi
if [ $PUPPETEER_RESULT -ne 0 ] && [ -x ~/.npm-global/bin/node ]; then
  ~/.npm-global/bin/node /tmp/puppeteer_netstory.js "https://$DEST" && PUPPETEER_RESULT=0
fi
if [ $PUPPETEER_RESULT -ne 0 ]; then
  npx /tmp/puppeteer_netstory.js "https://$DEST" && PUPPETEER_RESULT=0
fi

if [ $PUPPETEER_RESULT -ne 0 ]; then
  echo -e "\n❌ Could not run Puppeteer. Try the following:\n"
  echo "  npm install puppeteer"
  echo "  or npm install -g puppeteer"
  echo "  or npm install --prefix ~/.npm-global puppeteer"
  echo -e "  And ensure you run this script WITHOUT sudo."
fi

rm -f /tmp/puppeteer_netstory.js

# ------ Bash-side summary -----
TRACE+="\n\nSummary:\n$DEST ($DEST_IP), path: $FLOW
CDN/Proxy: $CDN_DETECTED
$( [[ -n "$HTTPS_CERT" ]] && echo "TLS snippet: $(echo "$HTTPS_CERT" | head -n1)" )"

OPEN_PORTS=$(printf "%s\n" "${PORT_RESULTS[@]}" | grep -c OPEN)
KPI="
📊 KPIs:
- Destination: $DEST ($DEST_IP)
- Reached: ✅ Yes
- CDN/Proxy: $CDN_DETECTED
- Ports scanned: ${#PORTS[@]} | Open: $OPEN_PORTS
- Functional subdomains checked: ${#SAME_FAMILY[@]}
- Supporting externals checked: $(( ${#EXTERNAL_FONTS[@]} > 3 ? 3 : ${#EXTERNAL_FONTS[@]} ))
"

echo -e "\n✅ FINAL STORY (BASH DIAG):\n$TRACE\n$KPI"
