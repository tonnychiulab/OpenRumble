import { join } from "node:path";

export type ActionId =
  | "deploy"
  | "dry-run"
  | "verify"
  | "logs"
  | "rollback"
  | "purge-packages"
  | "purge-tree"
  | "quit";

export interface ActionSpec {
  id: ActionId;
  section: string;
  label: string;
  description: string;
  destructive: boolean;
  phrase: string | null;
  script: string | null;
  args: readonly string[];
}

export const ACTIONS: readonly ActionSpec[] = [
  {
    id: "deploy",
    section: "部署",
    label: "正式部署",
    description: "deploy_phase2_zeek.sh --yes",
    destructive: true,
    phrase: null,
    script: "scripts/phase2/deploy_phase2_zeek.sh",
    args: ["--yes"],
  },
  {
    id: "dry-run",
    section: "部署",
    label: "Dry-run 預檢",
    description: "deploy_phase2_zeek.sh --dry-run",
    destructive: false,
    phrase: null,
    script: "scripts/phase2/deploy_phase2_zeek.sh",
    args: ["--dry-run"],
  },
  {
    id: "verify",
    section: "複查",
    label: "唯讀複查",
    description: "verify_phase2_zeek.sh",
    destructive: false,
    phrase: null,
    script: "scripts/phase2/verify_phase2_zeek.sh",
    args: [],
  },
  {
    id: "logs",
    section: "日誌",
    label: "看 current 日誌尾端",
    description: "唯讀 tail，不呼叫 zeekctl",
    destructive: false,
    phrase: null,
    script: null,
    args: [],
  },
  {
    id: "rollback",
    section: "回滾",
    label: "還原設定",
    description: "rollback_phase2_zeek.sh --yes",
    destructive: true,
    phrase: null,
    script: "scripts/phase2/rollback_phase2_zeek.sh",
    args: ["--yes"],
  },
  {
    id: "purge-packages",
    section: "清除",
    label: "卸載 zeek 套件",
    description: "--yes --purge-packages，保留 jq",
    destructive: true,
    phrase: null,
    script: "scripts/phase2/rollback_phase2_zeek.sh",
    args: ["--yes", "--purge-packages"],
  },
  {
    id: "purge-tree",
    section: "清除",
    label: "刪除 /opt/zeek",
    description: "--yes --purge，需輸入 DELETE",
    destructive: true,
    phrase: "DELETE",
    script: "scripts/phase2/rollback_phase2_zeek.sh",
    args: ["--yes", "--purge"],
  },
  {
    id: "quit",
    section: "離開",
    label: "離開主控台",
    description: "不修改系統",
    destructive: false,
    phrase: null,
    script: null,
    args: [],
  },
];

export function actionById(id: string): ActionSpec | undefined {
  return ACTIONS.find((action) => action.id === id);
}

export function scriptPath(repoRoot: string, script: string): string {
  return join(repoRoot, script);
}

export function commandText(repoRoot: string, action: ActionSpec): string {
  if (action.id === "logs") return "tail -n 80 /opt/zeek/logs/current/*.log";
  if (!action.script) return action.label;
  const args = action.args.length > 0 ? ` ${action.args.join(" ")}` : "";
  return `bash ${scriptPath(repoRoot, action.script)}${args}`;
}

export function confirmLines(repoRoot: string, action: ActionSpec): string[] {
  const command = commandText(repoRoot, action);
  switch (action.id) {
    case "deploy":
      return [
        "即將修改系統。確認後才執行下面這支腳本，TUI 不自己跑 apt 或 zeekctl：",
        command,
        "會安裝 zeek；缺少 jq、logrotate 或 cron 時也會安裝。不會改登入殼層 PATH。",
        "腳本失敗會停，zeekctl status 沒有 running 不會印成功。",
        "Enter 執行    Esc 取消",
      ];
    case "dry-run":
      return [
        "預檢不會修改系統。確認後執行：",
        command,
        "Enter 執行    Esc 取消",
      ];
    case "verify":
      return [
        "唯讀複查：不改系統、不抓封包、不呼叫 zeekctl deploy。",
        command,
        "Enter 執行    Esc 取消",
      ];
    case "rollback":
      return [
        "即將停止 Zeek，並還原 node.cfg、local.zeek 與輪替設定。",
        "不會卸載套件，不會刪除 /opt/zeek，不會改登入殼層 PATH。",
        command,
        "Enter 執行    Esc 取消",
      ];
    case "purge-packages":
      return [
        "即將卸載 zeek 套件、OBS 來源與金鑰，並還原第二階段設定。",
        "不會卸載 jq，也不會因為這個動作刪除 /opt/zeek。",
        command,
        "Enter 執行    Esc 取消",
      ];
    case "purge-tree":
      return [
        "即將刪除 /opt/zeek。裡面的日誌會一起消失。",
        "這個動作不卸載 apt 套件。若要卸載，請另選「卸載 zeek 套件」。",
        command,
        "請輸入 DELETE 後按 Enter。Esc 取消。",
      ];
    default:
      return [command, "Enter 執行    Esc 取消"];
  }
}
