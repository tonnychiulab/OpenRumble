import { spawn } from "node:child_process";
export function emptyStatus(detail) {
    return {
        available: false,
        root: "?",
        os: "?",
        zeekctl: "?",
        iface: "",
        ifaceExists: "no",
        json: "no",
        jsonLine: "no",
        cron: "no",
        logrotate: "no",
        copytruncateCurrent: "no",
        fingerprint: "",
        detail,
    };
}
const PROBE = `
set +e
if [ -r /etc/os-release ]; then
  . /etc/os-release
  echo "os=\${ID:-unknown} \${VERSION_ID:-unknown}"
else
  echo "os=unknown"
fi
echo "root=\$(id -u 2>/dev/null || echo na)"
if [ -x /opt/zeek/bin/zeekctl ]; then
  status=\$(/opt/zeek/bin/zeekctl status 2>&1)
  if echo "\$status" | grep -q running; then echo "zeekctl=running"
  elif echo "\$status" | grep -q stopped; then echo "zeekctl=stopped"
  else echo "zeekctl=installed"; fi
else
  echo "zeekctl=missing"
fi
iface=""
if [ -f /opt/zeek/etc/node.cfg ]; then
  iface=\$(awk -F= '/^[[:space:]]*interface=/ { gsub(/[[:space:]]/, "", \$2); print \$2; exit }' /opt/zeek/etc/node.cfg)
fi
echo "iface=\${iface}"
if [ -n "\$iface" ] && ip link show dev "\$iface" >/dev/null 2>&1; then
  echo "iface_exists=yes"
else
  echo "iface_exists=no"
fi
if [ -f /opt/zeek/share/zeek/site/local.zeek ] && grep -q 'LogAscii::use_json' /opt/zeek/share/zeek/site/local.zeek; then
  echo "json=yes"
else
  echo "json=no"
fi
if grep -l -m 1 '^{' /opt/zeek/logs/current/*.log >/dev/null 2>&1; then
  echo "json_line=yes"
else
  echo "json_line=no"
fi
if [ -f /etc/cron.d/obm-zeek ] && grep -q '/opt/zeek/bin/zeekctl cron' /etc/cron.d/obm-zeek; then
  echo "cron=yes"
else
  echo "cron=no"
fi
if [ -f /etc/logrotate.d/zeek ]; then
  echo "logrotate=yes"
  if grep -q '/opt/zeek/logs/current' /etc/logrotate.d/zeek && grep -q copytruncate /etc/logrotate.d/zeek; then
    echo "copytruncate_current=yes"
  else
    echo "copytruncate_current=no"
  fi
else
  echo "logrotate=no"
  echo "copytruncate_current=no"
fi
if [ -f /usr/share/keyrings/security_zeek.gpg ]; then
  fp=\$(gpg --batch --show-keys --with-colons /usr/share/keyrings/security_zeek.gpg 2>/dev/null | awk -F: '/^fpr:/ { print \$10; exit }')
  echo "fingerprint=\${fp}"
else
  echo "fingerprint="
fi
`;
function parseProbe(text) {
    const values = new Map();
    for (const line of text.split(/\r?\n/)) {
        const split = line.indexOf("=");
        if (split === -1)
            continue;
        values.set(line.slice(0, split), line.slice(split + 1).trim());
    }
    if (!values.has("os") && !values.has("zeekctl")) {
        return emptyStatus("這台機器讀不到 Zeek 狀態。正式操作請在 Ubuntu 24.04 上以 root 執行。");
    }
    return {
        available: true,
        root: values.get("root") ?? "?",
        os: values.get("os") ?? "?",
        zeekctl: values.get("zeekctl") ?? "?",
        iface: values.get("iface") ?? "",
        ifaceExists: values.get("iface_exists") ?? "no",
        json: values.get("json") ?? "no",
        jsonLine: values.get("json_line") ?? "no",
        cron: values.get("cron") ?? "no",
        logrotate: values.get("logrotate") ?? "no",
        copytruncateCurrent: values.get("copytruncate_current") ?? "no",
        fingerprint: values.get("fingerprint") ?? "",
        detail: "",
    };
}
export function probeStatus() {
    return new Promise((resolve) => {
        let child;
        try {
            child = spawn("bash", ["-c", PROBE], { windowsHide: true });
        }
        catch {
            resolve(emptyStatus("找不到 bash，無法探測 Zeek。"));
            return;
        }
        let out = "";
        const timer = setTimeout(() => {
            child.kill();
        }, 8000);
        child.stdout?.on("data", (chunk) => {
            out += chunk.toString("utf8");
        });
        child.stderr?.on("data", (chunk) => {
            out += chunk.toString("utf8");
        });
        child.on("error", () => {
            clearTimeout(timer);
            resolve(emptyStatus("找不到 bash，無法探測 Zeek。"));
        });
        child.on("close", () => {
            clearTimeout(timer);
            resolve(parseProbe(out));
        });
    });
}
